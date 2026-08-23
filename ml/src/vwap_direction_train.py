"""Walk-forward baseline for the VWAP-family direction model.

Same discipline as train.py, front-loaded this time per the trade-filter
post-mortem: logistic regression AND LightGBM from the start, in-sample vs
out-of-sample AUC gap checked immediately, chronological expanding-window CV
only. Runs all three label horizons so they can be compared directly.

Usage:
    python vwap_direction_train.py [--features PATH] [--folds 5]
"""
import argparse
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score

DEFAULT_FEATURES = Path(__file__).resolve().parent.parent / "data" / "vwap_direction_features.csv"

NUMERIC_FEATURES = [
    "price_dayvwap_atr", "price_weekvwap_atr", "price_slvwap_atr", "price_shvwap_atr",
    "dayvwap_slvwap_spread_atr", "shvwap_dayvwap_spread_atr", "shvwap_slvwap_spread_atr",
    "day_slope_atr", "slvwap_slope_atr", "shvwap_slope_atr",
    "slvwap_freshness_bars", "shvwap_freshness_bars",
    "stack_bull", "stack_bear",
]
CATEGORICAL_FEATURES = ["session"]
FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES

HORIZONS = ["ret_h_close", "ret_h_30bar", "ret_h_60bar"]

LGB_PARAMS = dict(
    objective="binary", metric="auc", num_leaves=15, max_depth=4,
    min_child_samples=60, learning_rate=0.05, n_estimators=300,
    reg_alpha=0.1, reg_lambda=0.1, subsample=0.8, subsample_freq=1,
    colsample_bytree=0.8, verbose=-1,
)


def walk_forward(df: pd.DataFrame, n_folds: int, initial_frac: float = 0.5):
    n = len(df)
    start = int(n * initial_frac)
    fold_size = (n - start) // n_folds
    for i in range(n_folds):
        train_end = start + i * fold_size
        test_end = n if i == n_folds - 1 else train_end + fold_size
        yield df.iloc[:train_end], df.iloc[train_end:test_end]


def fit_lgb(train_df: pd.DataFrame) -> lgb.LGBMClassifier:
    m = lgb.LGBMClassifier(**LGB_PARAMS)
    m.fit(train_df[FEATURES], train_df["y"], categorical_feature=CATEGORICAL_FEATURES)
    return m


def fit_logreg(train_df: pd.DataFrame):
    num = (train_df[NUMERIC_FEATURES] - train_df[NUMERIC_FEATURES].mean()) / train_df[NUMERIC_FEATURES].std()
    cat = pd.get_dummies(train_df[CATEGORICAL_FEATURES], drop_first=True)
    X = pd.concat([num, cat], axis=1)
    mean, std, cols = train_df[NUMERIC_FEATURES].mean(), train_df[NUMERIC_FEATURES].std(), X.columns
    lr = LogisticRegression(max_iter=1000, C=0.1)
    lr.fit(X, train_df["y"])
    return lr, mean, std, cols


def predict_logreg(model_tuple, df: pd.DataFrame) -> np.ndarray:
    lr, mean, std, cols = model_tuple
    num = (df[NUMERIC_FEATURES] - mean) / std
    cat = pd.get_dummies(df[CATEGORICAL_FEATURES], drop_first=True)
    X = pd.concat([num, cat], axis=1).reindex(columns=cols, fill_value=0)
    return lr.predict_proba(X)[:, 1]


def decile_report(oof: pd.DataFrame, ret_col: str) -> None:
    oof = oof.sort_values("pred").reset_index(drop=True)
    n = len(oof)
    print(f"{'decile':>6s} {'n':>5s} {'pred_range':>18s} {'up%':>6s} {'mean_ret_atr':>13s}")
    for i in range(10):
        lo, hi = i * n // 10, (i + 1) * n // 10
        sub = oof.iloc[lo:hi]
        print(
            f"{i + 1:6d} {len(sub):5d} [{sub['pred'].iloc[0]:.3f}-{sub['pred'].iloc[-1]:.3f}] "
            f"{sub['y'].mean() * 100:5.1f}% {sub[ret_col].mean():+12.4f}"
        )


def run_horizon(df: pd.DataFrame, horizon: str, n_folds: int) -> None:
    ret_col = horizon
    label_col = f"label_{horizon}"
    sub = df.dropna(subset=[label_col, ret_col]).copy()
    sub["y"] = sub[label_col].astype(int)
    sub[CATEGORICAL_FEATURES] = sub[CATEGORICAL_FEATURES].astype("category")

    print(f"\n{'=' * 88}\nHORIZON: {horizon}  (n={len(sub)}, up-rate={sub['y'].mean() * 100:.1f}%)\n{'=' * 88}")

    oof_lgb, oof_lr = [], []
    for i, (tr, te) in enumerate(walk_forward(sub, n_folds), start=1):
        m = fit_lgb(tr)
        p = m.predict_proba(te[FEATURES])[:, 1]
        auc = roc_auc_score(te["y"], p)
        o = te[["y", ret_col]].copy(); o["pred"] = p
        oof_lgb.append(o)

        lr_tuple = fit_logreg(tr)
        p_lr = predict_logreg(lr_tuple, te)
        auc_lr = roc_auc_score(te["y"], p_lr)
        o2 = te[["y", ret_col]].copy(); o2["pred"] = p_lr
        oof_lr.append(o2)

        print(f"fold {i}: train_n={len(tr):5d} test_n={len(te):4d}  LGBM_AUC={auc:.3f}  LogReg_AUC={auc_lr:.3f}")

    oof_lgb = pd.concat(oof_lgb, ignore_index=True)
    oof_lr = pd.concat(oof_lr, ignore_index=True)
    print(f"\nLGBM  overall OOF AUC = {roc_auc_score(oof_lgb['y'], oof_lgb['pred']):.3f}")
    print(f"LogReg overall OOF AUC = {roc_auc_score(oof_lr['y'], oof_lr['pred']):.3f}")

    m_full = fit_lgb(sub)
    train_pred = m_full.predict_proba(sub[FEATURES])[:, 1]
    print(f"LGBM in-sample AUC (full data) = {roc_auc_score(sub['y'], train_pred):.3f}  <- overfitting check")

    print("\n-- LGBM out-of-fold decile report --")
    decile_report(oof_lgb, ret_col)

    print("\n-- feature importance (gain), full-data LGBM fit --")
    imp = pd.Series(m_full.booster_.feature_importance(importance_type="gain"), index=FEATURES).sort_values(ascending=False)
    for feat, v in imp.items():
        print(f"  {feat:28s} {v:10.1f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", default=str(DEFAULT_FEATURES))
    ap.add_argument("--folds", type=int, default=5)
    args = ap.parse_args()

    df = pd.read_csv(args.features, parse_dates=["time"]).sort_values("time").reset_index(drop=True)
    for h in HORIZONS:
        run_horizon(df, h, args.folds)


if __name__ == "__main__":
    main()

"""Walk-forward baseline for the trade-quality filter.

Binary label: win (net_r > 0.02) vs not-win (loss or scratch) — matches the
"should this trade be taken" framing a pre-entry filter needs.

Chronological expanding-window CV (never a random split — trade_no is the
EA's global sequence counter, so sorting by it is sorting by time). No fold
ever trains on its own future.

Usage:
    python train.py [--features PATH] [--model-out PATH]
"""
import argparse
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.metrics import roc_auc_score

DEFAULT_FEATURES = Path(__file__).resolve().parent.parent / "data" / "features.csv"
DEFAULT_MODEL_OUT = Path(__file__).resolve().parent.parent / "data" / "model_full.txt"

NUMERIC_FEATURES = [
    "sl_atr_ratio",
    "mins_from_session_open",
    "vwap_distance_atr",
    "spread_at_entry",
    "bos_count",
    "range_exited",
    "sweep_depth_atr",
]
CATEGORICAL_FEATURES = ["session", "model", "order_kind", "bias", "weekday"]
FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES

LGB_PARAMS = dict(
    objective="binary",
    metric="auc",
    num_leaves=15,
    max_depth=4,
    min_child_samples=40,
    learning_rate=0.05,
    n_estimators=300,
    reg_alpha=0.1,
    reg_lambda=0.1,
    subsample=0.8,
    subsample_freq=1,
    colsample_bytree=0.8,
    verbose=-1,
)


def load(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    df = df.sort_values("trade_no").reset_index(drop=True)
    df["y"] = (df["label"] == "win").astype(int)
    for c in CATEGORICAL_FEATURES:
        df[c] = df[c].astype("category")
    return df


def walk_forward(df: pd.DataFrame, n_folds: int = 5, initial_frac: float = 0.5):
    """Expanding-window chronological CV. Yields (train_df, test_df) per fold."""
    n = len(df)
    start = int(n * initial_frac)
    fold_size = (n - start) // n_folds
    for i in range(n_folds):
        train_end = start + i * fold_size
        test_end = n if i == n_folds - 1 else train_end + fold_size
        yield df.iloc[:train_end], df.iloc[train_end:test_end]


def fit(train_df: pd.DataFrame) -> lgb.LGBMClassifier:
    model = lgb.LGBMClassifier(**LGB_PARAMS)
    model.fit(
        train_df[FEATURES],
        train_df["y"],
        categorical_feature=CATEGORICAL_FEATURES,
    )
    return model


def decile_report(oof: pd.DataFrame) -> None:
    oof = oof.sort_values("pred").reset_index(drop=True)
    n = len(oof)
    qs = 10
    print(f"\n{'decile':>6s} {'n':>5s} {'pred_range':>18s} {'win%':>7s} {'mean_net_r':>11s}")
    for i in range(qs):
        lo, hi = i * n // qs, (i + 1) * n // qs
        sub = oof.iloc[lo:hi]
        win_pct = (sub["y"] == 1).mean() * 100
        print(
            f"{i + 1:6d} {len(sub):5d} "
            f"[{sub['pred'].iloc[0]:.3f}-{sub['pred'].iloc[-1]:.3f}] "
            f"{win_pct:6.1f}% {sub['net_r'].mean():+10.3f}"
        )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", default=str(DEFAULT_FEATURES))
    ap.add_argument("--model-out", default=str(DEFAULT_MODEL_OUT))
    ap.add_argument("--folds", type=int, default=5)
    args = ap.parse_args()

    df = load(Path(args.features))
    print(f"loaded {len(df)} rows, win rate = {df['y'].mean() * 100:.1f}%")

    oof_rows = []
    fold_aucs = []
    for i, (train_df, test_df) in enumerate(walk_forward(df, n_folds=args.folds), start=1):
        model = fit(train_df)
        pred = model.predict_proba(test_df[FEATURES])[:, 1]
        auc = roc_auc_score(test_df["y"], pred)
        fold_aucs.append(auc)
        print(
            f"fold {i}: train_n={len(train_df):5d} test_n={len(test_df):4d} "
            f"test_win%={test_df['y'].mean() * 100:5.1f}  AUC={auc:.3f}"
        )
        fold_oof = test_df[["trade_no", "y", "net_r"]].copy()
        fold_oof["pred"] = pred
        oof_rows.append(fold_oof)

    oof = pd.concat(oof_rows, ignore_index=True)
    print(f"\nmean fold AUC = {np.mean(fold_aucs):.3f} (std {np.std(fold_aucs):.3f})")
    print(f"overall out-of-fold AUC = {roc_auc_score(oof['y'], oof['pred']):.3f}")
    print(f"baseline (take every trade) mean net_r = {oof['net_r'].mean():+.3f}  n={len(oof)}")

    decile_report(oof)

    top_half = oof[oof["pred"] >= oof["pred"].median()]
    bottom_half = oof[oof["pred"] < oof["pred"].median()]
    print(
        f"\ntop half by pred:    n={len(top_half):4d}  win%={(top_half['y'].mean() * 100):5.1f}  "
        f"mean_net_r={top_half['net_r'].mean():+.3f}"
    )
    print(
        f"bottom half by pred: n={len(bottom_half):4d}  win%={(bottom_half['y'].mean() * 100):5.1f}  "
        f"mean_net_r={bottom_half['net_r'].mean():+.3f}"
    )

    print("\n-- final model (trained on ALL data) feature importance (gain) --")
    final_model = fit(df)
    importances = pd.Series(
        final_model.booster_.feature_importance(importance_type="gain"), index=FEATURES
    ).sort_values(ascending=False)
    for feat, imp in importances.items():
        print(f"  {feat:24s} {imp:10.1f}")

    model_out = Path(args.model_out)
    model_out.parent.mkdir(parents=True, exist_ok=True)
    final_model.booster_.save_model(str(model_out))
    print(f"\nsaved final full-data model -> {model_out}")


if __name__ == "__main__":
    main()

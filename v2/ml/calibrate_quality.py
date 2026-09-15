"""Offline calibration helper for Include/SessionQuality.mqh (v2, T2c).

This is deliberately NOT a live model. It reads the CSV that T2c already
writes plus a small hand-labelled file (you eyeballing sessions on the
chart and marking green/red), and turns those labels into a handful of
threshold numbers you paste back into the EA's inputs. Nothing here runs
inside MQL5 or gates a live decision - see v2/doc/IMPLEMENTATION_PLAN.md
("Discussion: why it's leaking chop, and whether ML/RL is the right next
move") for why a live model was rejected for this component.

Two ways to get labelled data
------------------------------
A) The labeller EA (recommended - v2/tools/SessionLabeler.mq5): run it in the
   Strategy Tester. It pauses at every session close, shows GREEN/RED/SKIP
   buttons plus every metric for that session, and appends one row straight
   to Common\\Files\\SessionsStrategyV2_Labels_<symbol>.csv - already in this
   script's format, 'label' column included. Then just run:
       python calibrate_quality.py --labelled-csv <that file>

B) The old manual route: run T2c over a few months (it writes
   Common\\Files\\SessionsStrategyV2_Quality_<symbol>.csv), generate a
   template, fill it in by eyeballing screenshots, then join it:
       python calibrate_quality.py --csv <quality csv> --make-template
       #  -> fill quality_labels_template.csv's 'label' column, save it
       python calibrate_quality.py --csv <quality csv> --labels quality_labels.csv

Either path prints the same report:
  - per-metric correlation with your label (which features actually
    separate your greens from your reds)
  - a small grid search over the same gate shape SessionQuality.mqh uses
    (range_ratio, range_atr / leg_atr, impulse_bars), ranked by F1,
    precision and recall
  - if scikit-learn is installed: a depth-3 decision tree fit to your
    labels, printed as plain-English rules, plus feature importances

Copy the winning thresholds into the EA's InpMinRangeRatio / InpMinRangeAtr /
InpMinLegAtr / InpMinImpulseBars inputs and re-run to confirm the recoloured
boxes match your eye.

Dependencies: pandas, numpy. scikit-learn is optional (decision-tree
section is skipped with a note if it's not installed).
"""
from __future__ import annotations

import argparse
import itertools
from pathlib import Path

import numpy as np
import pandas as pd

# Core columns both T2c's quality CSV and the labeller's CSV always have
# (see V2_QualityCsvHeader in Include/SessionQuality.mqh). New metrics get
# added there over time - FEATURES below is what actually gets analysed, so
# adding a column upstream and here is enough to bring it into the report.
REQUIRED_COLUMNS = ["session", "open_riyadh", "close_riyadh"]

FEATURES = [
    "range_ratio", "range_atr", "leg_atr", "leg_ratio", "efficiency",
    "impulse_bars", "body_impulse_bars", "max_bar_range_share",
    "run_ratio", "volume_ratio",
]


def load_quality_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    missing = set(REQUIRED_COLUMNS) - set(df.columns)
    if missing:
        raise SystemExit(f"CSV is missing columns {missing} - is this a "
                          f"T2c/labeller quality CSV?")
    present_features = [f for f in FEATURES if f in df.columns]
    missing_features = set(FEATURES) - set(present_features)
    if missing_features:
        print(f"(note: columns not present in this CSV, skipping them: "
              f"{sorted(missing_features)})")
    return df


def make_template(df: pd.DataFrame, out_path: Path) -> None:
    tmpl = df[["session", "open_riyadh", "close_riyadh", "range_ratio",
               "range_atr", "leg_atr", "impulse_bars", "efficiency",
               "score", "state"]].copy()
    tmpl["label"] = ""  # you fill this: 1 = quality/green, 0 = flat/red
    tmpl.to_csv(out_path, index=False)
    print(f"Wrote {len(tmpl)} rows to {out_path}")
    print("Fill the 'label' column (1 = should be green, 0 = should be red, "
          "blank = skip), save, then re-run with --labels <file>.")


def join_labels(df: pd.DataFrame, labels_path: Path) -> pd.DataFrame:
    labels = pd.read_csv(labels_path)
    if "label" not in labels.columns:
        raise SystemExit("labels file has no 'label' column")
    labels = labels.dropna(subset=["label"])
    labels = labels[labels["label"].astype(str).str.strip() != ""]
    labels["label"] = labels["label"].astype(int)
    merged = df.merge(labels[["session", "open_riyadh", "label"]],
                       on=["session", "open_riyadh"], how="inner")
    if merged.empty:
        raise SystemExit("no rows matched between the quality CSV and the labels file - "
                          "check that 'session'/'open_riyadh' weren't edited")
    return merged


def report_correlations(df: pd.DataFrame, features: list[str]) -> None:
    print("\n=== Correlation of each metric with your label (1=green) ===")
    corr = df[features + ["label"]].corr()["label"].drop("label").sort_values(
        key=lambda s: s.abs(), ascending=False)
    for name, val in corr.items():
        print(f"  {name:<20s} {val:+.3f}")


def confusion(pred: np.ndarray, label: np.ndarray) -> tuple[float, float, float, float]:
    tp = int(((pred == 1) & (label == 1)).sum())
    fp = int(((pred == 1) & (label == 0)).sum())
    fn = int(((pred == 0) & (label == 1)).sum())
    tn = int(((pred == 0) & (label == 0)).sum())
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    denom = ((tp + fp) * (tp + fn) * (tn + fp) * (tn + fn)) ** 0.5
    mcc = (tp * tn - fp * fn) / denom if denom else 0.0
    return precision, recall, f1, mcc


def grid_search(df: pd.DataFrame) -> None:
    print("\n=== Grid search over the SAME gate shape SessionQuality.mqh uses (2026-09-14+) ===")
    print("pass = (range_atr >= ra OR leg_atr >= la) AND impulse_bars >= ib "
          "AND (no baseline yet OR range_ratio >= rb)\n")
    print("(rb is a CONFIRM-only check - vacuously true when baseline<=0 - it never withholds "
          "a verdict during baseline warm-up. A hard-blocking version of rb was tested and "
          "measured WORSE on real data: see v2/doc/IMPLEMENTATION_PLAN.md, 2026-09-14 entry.)\n")

    label = df["label"].to_numpy()
    majority = 1 if label.mean() >= 0.5 else 0
    maj_pred = np.full_like(label, majority)
    _, _, maj_f1, maj_mcc = confusion(maj_pred, label)
    print(f"baseline (always predict {'GREEN' if majority else 'RED'}, i.e. no gate at all): "
          f"F1={maj_f1:.2f}  MCC={maj_mcc:.2f}")
    print(f"({label.mean()*100:.0f}% of your labels are green - with an imbalance like this, F1 "
          f"alone can be gamed by a threshold that lets almost everything through, so ranking "
          f"below is by MCC (rewards both classes, 0=no better than guessing, 1=perfect) with "
          f"F1/precision/recall shown for context.)\n")

    # wide enough that a real optimum should land INSIDE the range, not on its
    # edge - if the winning row still sits on a boundary here, widen again
    rb_grid = [0.0, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.20]
    ra_grid = [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0]
    la_grid = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0]
    ib_grid = [0, 1, 2, 3]

    has_baseline = df["baseline"] > 0.0 if "baseline" in df.columns else pd.Series(True, index=df.index)

    results = []
    for rb, ra, la, ib in itertools.product(rb_grid, ra_grid, la_grid, ib_grid):
        confirm = (~has_baseline) | (df["range_ratio"] >= rb)
        pred = (
            ((df["range_atr"] >= ra) | (df["leg_atr"] >= la))
            & (df["impulse_bars"] >= ib)
            & confirm
        ).astype(int).to_numpy()
        precision, recall, f1, mcc = confusion(pred, label)
        results.append((mcc, f1, precision, recall, rb, ra, la, ib))

    results.sort(reverse=True)
    print(f"{'MCC':>5} {'F1':>5} {'Prec':>5} {'Rec':>5}   rng/base  rng/atr  leg/atr  impulse")
    for mcc, f1, precision, recall, rb, ra, la, ib in results[:12]:
        print(f"{mcc:5.2f} {f1:5.2f} {precision:5.2f} {recall:5.2f}   "
              f"{rb:8.2f} {ra:8.1f} {la:8.1f} {ib:8d}")
    top_rb = {r[4] for r in results[:12]}
    top_ra = {r[5] for r in results[:12]}
    top_la = {r[6] for r in results[:12]}
    edge_notes = []
    if max(top_rb) >= rb_grid[-1]: edge_notes.append("rng/base")
    if max(top_ra) >= ra_grid[-1]: edge_notes.append("rng/atr")
    if max(top_la) >= la_grid[-1]: edge_notes.append("leg/atr")
    if edge_notes:
        print(f"\n(note: top rows still touch the edge of the searched range for: "
              f"{', '.join(sorted(set(edge_notes)))} - widen that grid in this script and "
              f"re-run before trusting the number)")
    print("\nPick the row with a precision/recall balance you're happy with (MCC ranks them, "
          "but the choice of false-positive vs false-negative cost is yours) - and check it "
          "clearly beats the baseline above, not just matches it.")


def decision_tree(df: pd.DataFrame, features: list[str]) -> None:
    try:
        from sklearn.tree import DecisionTreeClassifier, export_text
    except ImportError:
        print("\n(scikit-learn not installed - skipping the decision-tree section; "
              "`pip install scikit-learn` to enable it)")
        return
    print("\n=== Depth-3 decision tree fit to your labels (for comparison only) ===")
    X = df[features]
    y = df["label"]
    clf = DecisionTreeClassifier(max_depth=3, min_samples_leaf=max(3, len(df) // 20),
                                  random_state=0)
    clf.fit(X, y)
    print(export_text(clf, feature_names=features))
    importances = sorted(zip(features, clf.feature_importances_), key=lambda t: -t[1])
    print("Feature importances:")
    for name, imp in importances:
        print(f"  {name:<20s} {imp:.3f}")
    print("\nThis tree is a sanity check on the grid search above, not something to "
          "deploy live - translate whichever splits agree with both into the EA's "
          "plain thresholds.")


def run_report(merged: pd.DataFrame) -> None:
    print(f"{len(merged)} labelled sessions "
          f"({int(merged['label'].sum())} green / {int((merged['label']==0).sum())} red)")
    features = [f for f in FEATURES if f in merged.columns]
    report_correlations(merged, features)
    grid_search(merged)
    decision_tree(merged, features)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", type=Path,
                     help="Path to SessionsStrategyV2_Quality_<symbol>.csv (T2c route)")
    ap.add_argument("--make-template", action="store_true",
                     help="With --csv: write quality_labels_template.csv next to it and exit")
    ap.add_argument("--labels", type=Path, default=None,
                     help="With --csv: your filled-in labels file (session, open_riyadh, label)")
    ap.add_argument("--labelled-csv", type=Path, default=None,
                     help="SessionsStrategyV2_Labels_<symbol>.csv from SessionLabeler.mq5 - "
                          "already has metrics AND 'label', no --csv/--labels/join needed")
    args = ap.parse_args()

    if args.labelled_csv is not None:
        merged = load_quality_csv(args.labelled_csv)
        if "label" not in merged.columns:
            raise SystemExit("--labelled-csv file has no 'label' column - "
                              "is this really the labeller's output?")
        run_report(merged)
        return

    if args.csv is None:
        raise SystemExit("pass --labelled-csv <file>, or --csv <file> (+ --make-template / --labels)")

    df = load_quality_csv(args.csv)

    if args.make_template:
        make_template(df, args.csv.parent / "quality_labels_template.csv")
        return

    if args.labels is None:
        raise SystemExit("pass --labels <file> (or --make-template to create one first)")

    merged = join_labels(df, args.labels)
    run_report(merged)


if __name__ == "__main__":
    main()

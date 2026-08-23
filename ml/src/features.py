"""Feature engineering for the trade-quality filter.

Reads the TradeAnalytics CSV export and builds a feature table restricted to
columns computable AT THE SIGNAL MOMENT (before PlaceOrder fires) — never
from realized fill/outcome data. See ml/README.md for the leakage rules this
encodes.

Usage:
    python features.py [--input PATH] [--output PATH]
"""
import argparse
import csv
from pathlib import Path

DEFAULT_INPUT = (
    r"C:\Users\yoonus\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
    r"\SessionsStrategy_Trades_XAUUSD.csv"
)
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "data" / "features.csv"

# Columns copied through unchanged (categorical, already known pre-entry).
# bias_source and risk_mode are excluded: constant across the current
# history (100% VWAP / 100% PERCENT), so they carry zero information.
CATEGORICAL_PASSTHROUGH = ["session", "model", "order_kind", "bias", "weekday"]

# Label: BE scratches (~0R) are neither a clean win nor a clean loss: 40% of
# trades close near break-even, so a strict >0 threshold would let random
# noise near the boundary flip the label. Fixed dead zone matches the
# stats() helper convention already used in strat_deep.py (0.02R).
LABEL_DEAD_ZONE_R = 0.02


def to_float(row: dict, key: str, default: float = 0.0) -> float:
    v = row.get(key, "")
    if v in (None, ""):
        return default
    try:
        return float(v)
    except ValueError:
        return default


def build_row(row: dict) -> dict:
    atr = to_float(row, "atr_at_entry")
    sl_dist = to_float(row, "sl_distance_price")
    vwap_dist = to_float(row, "vwap_distance")
    swept_level = to_float(row, "swept_level")
    sweep_extreme = to_float(row, "sweep_extreme")
    net_r = to_float(row, "net_r")

    out = {
        "trade_no": row.get("trade_no", ""),
        # --- core numeric features ---
        "sl_atr_ratio": (sl_dist / atr) if atr > 0 else 0.0,
        "mins_from_session_open": to_float(row, "mins_from_session_open"),
        "vwap_distance_atr": (abs(vwap_dist) / atr) if atr > 0 else 0.0,
        "spread_at_entry": to_float(row, "spread_at_entry"),
        # --- candidate numeric features ---
        "bos_count": to_float(row, "bos_count"),
        "range_exited": to_float(row, "range_exited"),
        "sweep_depth_atr": (abs(sweep_extreme - swept_level) / atr) if atr > 0 else 0.0,
        # --- label (post-entry, kept only as the training target) ---
        "net_r": net_r,
        "label": label_for(net_r),
    }
    for col in CATEGORICAL_PASSTHROUGH:
        out[col] = row.get(col, "")
    return out


def label_for(net_r: float) -> str:
    if net_r > LABEL_DEAD_ZONE_R:
        return "win"
    if net_r < -LABEL_DEAD_ZONE_R:
        return "loss"
    return "scratch"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=DEFAULT_INPUT)
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    args = ap.parse_args()

    with open(args.input, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))

    feature_rows = [build_row(r) for r in rows]

    fieldnames = list(feature_rows[0].keys()) if feature_rows else []
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(feature_rows)

    label_counts = {}
    for r in feature_rows:
        label_counts[r["label"]] = label_counts.get(r["label"], 0) + 1

    print(f"wrote {len(feature_rows)} rows -> {out_path}")
    print(f"label distribution: {label_counts}")


if __name__ == "__main__":
    main()

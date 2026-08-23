"""Bar-level dataset for the VWAP-direction model.

Decoupled from the EA's own trade log on purpose (see ml/README.md /
conversation history: the trade-filter experiment showed that conditioning on
"a trade actually fired" throws away most of the population and reintroduces
a small/biased sample). Every session-open point in the history is a row
here, whether or not the EA would have taken a trade that session.

Replicates, in Python, exactly what the EA's own settings do with the
Aug-23 .set file's confirmed values:
  - InpBrokerToRiyadhHr = 0.0  -> server time IS Riyadh time, no conversion
  - InpDayCloseHour     = 0    -> day-VWAP resets at plain midnight
  - Asia 03:00-06:00, NY 15:00-18:00 (London off, matches production)

Anchors:
  - day VWAP, week VWAP (Monday reset)      -- existing production anchors
  - major-swing-low / major-swing-high VWAP -- NEW: anchored at the most
    recent CONFIRMED macro swing (strength N, default 15), reusing the same
    IsSwingHigh/IsSwingLow definition as Liquidity.mqh, just at a coarser N
    than the sweep detector's swingStrength=2.

No look-ahead: a swing at bar i is only usable as an anchor for bars
>= i+N (it takes N bars on the right to even confirm it's a swing).

Usage:
    python vwap_direction_data.py [--symbol XAUUSD] [--start 2016-01-01]
                                   [--swing-n 15] [--output PATH]
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "data" / "vwap_direction_features.csv"

ASIA_START, ASIA_END = 3 * 60, 6 * 60      # minutes of day
NY_START, NY_END = 15 * 60, 18 * 60
SLOPE_LOOKBACK_BARS = 10                    # ~20min on M2, for VWAP slope features
FORWARD_HORIZONS = {"h_close": None, "h_30bar": 30, "h_60bar": 60}


def pull_bars(symbol: str, start: pd.Timestamp) -> pd.DataFrame:
    if not mt5.initialize():
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"symbol_select({symbol}) failed: {mt5.last_error()}")
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M2, start, pd.Timestamp.utcnow())
    mt5.shutdown()
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates returned")
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df = df.sort_values("time").reset_index(drop=True)
    return df


def add_price_volume(df: pd.DataFrame) -> pd.DataFrame:
    df["hlc3"] = (df["high"] + df["low"] + df["close"]) / 3.0
    use_real = df["real_volume"].sum() > 0
    df["vol"] = df["real_volume"] if use_real else df["tick_volume"]
    df.loc[df["vol"] <= 0, "vol"] = 1
    return df


def wilder_atr(df: pd.DataFrame, period: int = 14) -> np.ndarray:
    high, low, close = df["high"].values, df["low"].values, df["close"].values
    prev_close = np.roll(close, 1)
    prev_close[0] = close[0]
    tr = np.maximum(high - low, np.maximum(np.abs(high - prev_close), np.abs(low - prev_close)))
    atr = np.full(len(df), np.nan)
    if len(df) < period:
        return atr
    atr[period - 1] = tr[:period].mean()
    for i in range(period, len(df)):
        atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return atr


def cumulative_pv(df: pd.DataFrame):
    cum_pv = np.concatenate([[0.0], np.cumsum(df["hlc3"].values * df["vol"].values)])
    cum_v = np.concatenate([[0.0], np.cumsum(df["vol"].values)])
    return cum_pv, cum_v  # cum_pv[k] = sum over bars [0..k-1]


def vwap_between(cum_pv, cum_v, anchor_idx: int, end_idx: int) -> float:
    """VWAP over bars [anchor_idx .. end_idx] inclusive. NaN if invalid/empty."""
    if anchor_idx < 0 or end_idx < anchor_idx:
        return np.nan
    pv = cum_pv[end_idx + 1] - cum_pv[anchor_idx]
    v = cum_v[end_idx + 1] - cum_v[anchor_idx]
    return pv / v if v > 0 else np.nan


def day_anchor_idx(df: pd.DataFrame) -> np.ndarray:
    dates = df["time"].dt.date.values
    first_idx_of_date = {}
    out = np.empty(len(df), dtype=np.int64)
    for i, d in enumerate(dates):
        if d not in first_idx_of_date:
            first_idx_of_date[d] = i
        out[i] = first_idx_of_date[d]
    return out


def week_anchor_idx(df: pd.DataFrame) -> np.ndarray:
    week_start = (df["time"] - pd.to_timedelta(df["time"].dt.dayofweek, unit="D")).dt.date.values
    first_idx_of_week = {}
    out = np.empty(len(df), dtype=np.int64)
    for i, w in enumerate(week_start):
        if w not in first_idx_of_week:
            first_idx_of_week[w] = i
        out[i] = first_idx_of_week[w]
    return out


def confirmed_swing_indices(df: pd.DataFrame, n: int, want_high: bool) -> tuple[np.ndarray, np.ndarray]:
    """Returns (confirm_at_idx[], swing_bar_idx[]) sorted by confirm_at_idx.
    confirm_at_idx = swing_bar_idx + n (first bar the anchor is usable, no look-ahead)."""
    col = "high" if want_high else "low"
    vals = df[col].values
    n_bars = len(vals)
    window = 2 * n + 1
    roll = pd.Series(vals).rolling(window=window, center=True, min_periods=window)
    roll_extreme = (roll.max() if want_high else roll.min()).values
    is_swing = np.zeros(n_bars, dtype=bool)
    valid = ~np.isnan(roll_extreme)
    is_swing[valid] = vals[valid] == roll_extreme[valid]
    swing_bar_idx = np.nonzero(is_swing)[0]
    confirm_at_idx = swing_bar_idx + n
    return confirm_at_idx, swing_bar_idx


def latest_anchor_before(confirm_at_idx: np.ndarray, swing_bar_idx: np.ndarray, query_idx: int) -> int:
    """Most recent swing whose confirm_at_idx <= query_idx. -1 if none yet."""
    pos = np.searchsorted(confirm_at_idx, query_idx, side="right") - 1
    return int(swing_bar_idx[pos]) if pos >= 0 else -1


def session_open_events(df: pd.DataFrame, start_min: int, end_min: int, session_name: str) -> pd.DataFrame:
    minute_of_day = df["time"].dt.hour * 60 + df["time"].dt.minute
    date = df["time"].dt.date
    rows = []
    for d, grp in df.groupby(date):
        mod = minute_of_day.loc[grp.index]
        open_candidates = grp.index[(mod >= start_min) & (mod < start_min + 10)]
        close_candidates = grp.index[mod < end_min]
        if len(open_candidates) == 0 or len(close_candidates) == 0:
            continue
        open_idx = open_candidates[0]
        close_idx = close_candidates[-1]
        if close_idx <= open_idx:
            continue
        rows.append({"session": session_name, "open_idx": open_idx, "close_idx": close_idx})
    return pd.DataFrame(rows)


def build_dataset(symbol: str, start: str, swing_n: int) -> pd.DataFrame:
    print(f"pulling {symbol} M2 bars from {start} ...")
    df = pull_bars(symbol, pd.Timestamp(start))
    print(f"  {len(df)} bars, {df['time'].iloc[0]} .. {df['time'].iloc[-1]}")
    df = add_price_volume(df)
    df["atr14"] = wilder_atr(df)
    cum_pv, cum_v = cumulative_pv(df)

    day_anchor = day_anchor_idx(df)
    week_anchor = week_anchor_idx(df)
    print(f"detecting confirmed macro swings (N={swing_n}) ...")
    sh_confirm, sh_idx = confirmed_swing_indices(df, swing_n, want_high=True)
    sl_confirm, sl_idx = confirmed_swing_indices(df, swing_n, want_high=False)

    events = pd.concat(
        [
            session_open_events(df, ASIA_START, ASIA_END, "ASIA"),
            session_open_events(df, NY_START, NY_END, "NY"),
        ],
        ignore_index=True,
    ).sort_values("open_idx").reset_index(drop=True)
    print(f"{len(events)} session-open events found")

    close = df["close"].values
    openp = df["open"].values
    atr = df["atr14"].values
    n_bars = len(df)

    rows = []
    for ev in events.itertuples():
        i = ev.open_idx
        a = atr[i]
        if np.isnan(a) or a <= 0:
            continue
        prev = i - 1
        if prev < 0:
            continue

        sw_low_anchor = latest_anchor_before(sl_confirm, sl_idx, i)
        sw_high_anchor = latest_anchor_before(sh_confirm, sh_idx, i)
        if sw_low_anchor < 0 or sw_high_anchor < 0:
            continue  # not enough history yet for a macro swing on either side

        day_vwap = vwap_between(cum_pv, cum_v, day_anchor[i], prev)
        week_vwap = vwap_between(cum_pv, cum_v, week_anchor[i], prev)
        sl_vwap = vwap_between(cum_pv, cum_v, sw_low_anchor, prev)
        sh_vwap = vwap_between(cum_pv, cum_v, sw_high_anchor, prev)
        if any(np.isnan(v) for v in (day_vwap, week_vwap, sl_vwap, sh_vwap)):
            continue

        # slope: VWAP value now vs SLOPE_LOOKBACK_BARS bars ago (same anchor, shorter window)
        k = SLOPE_LOOKBACK_BARS
        day_vwap_prior = vwap_between(cum_pv, cum_v, day_anchor[max(i - k, day_anchor[i])], max(prev - k, day_anchor[i]))
        sl_vwap_prior = vwap_between(cum_pv, cum_v, sw_low_anchor, max(prev - k, sw_low_anchor))
        sh_vwap_prior = vwap_between(cum_pv, cum_v, sw_high_anchor, max(prev - k, sw_high_anchor))

        price = openp[i]

        row = {
            "session": ev.session,
            "time": df["time"].iloc[i],
            "price_dayvwap_atr": (price - day_vwap) / a,
            "price_weekvwap_atr": (price - week_vwap) / a,
            "price_slvwap_atr": (price - sl_vwap) / a,
            "price_shvwap_atr": (price - sh_vwap) / a,
            "dayvwap_slvwap_spread_atr": (day_vwap - sl_vwap) / a,
            "shvwap_dayvwap_spread_atr": (sh_vwap - day_vwap) / a,
            "shvwap_slvwap_spread_atr": (sh_vwap - sl_vwap) / a,
            "day_slope_atr": (day_vwap - day_vwap_prior) / a if not np.isnan(day_vwap_prior) else 0.0,
            "slvwap_slope_atr": (sl_vwap - sl_vwap_prior) / a if not np.isnan(sl_vwap_prior) else 0.0,
            "shvwap_slope_atr": (sh_vwap - sh_vwap_prior) / a if not np.isnan(sh_vwap_prior) else 0.0,
            "slvwap_freshness_bars": i - sw_low_anchor,
            "shvwap_freshness_bars": i - sw_high_anchor,
            "stack_bull": int(price > day_vwap > sl_vwap),
            "stack_bear": int(price < day_vwap < sh_vwap),
        }

        # labels: forward return sign from this bar's OPEN
        close_idx = ev.close_idx
        row["ret_h_close"] = (close[close_idx] - price) / a
        for name, bars in FORWARD_HORIZONS.items():
            if bars is None:
                continue
            j = i + bars
            row[f"ret_{name}"] = (close[j] - price) / a if j < n_bars else np.nan

        rows.append(row)

    out = pd.DataFrame(rows)
    for horizon in ["ret_h_close", "ret_h_30bar", "ret_h_60bar"]:
        out[f"label_{horizon}"] = np.where(
            out[horizon].abs() < 1e-9, np.nan, (out[horizon] > 0).astype(float)
        )
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--start", default="2016-01-01")
    ap.add_argument("--swing-n", type=int, default=15)
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    args = ap.parse_args()

    out = build_dataset(args.symbol, args.start, args.swing_n)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(out_path, index=False)
    print(f"\nwrote {len(out)} rows -> {out_path}")
    print(out["session"].value_counts())
    for h in ["label_ret_h_close", "label_ret_h_30bar", "label_ret_h_60bar"]:
        vc = out[h].value_counts(dropna=True)
        print(f"{h}: {dict(vc)}  (NaN/dead-zone dropped: {out[h].isna().sum()})")


if __name__ == "__main__":
    main()

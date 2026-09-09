# Anchored VWAP Sessions Strategy — MQL5 EA Specification

**Instrument:** XAUUSD  **Platform:** MetaTrader 5 (MQL5 Expert Advisor)  **Base timeframe:** M5
**Spec version:** v0.4 (draft for review)

> **Changelog v0.3 → v0.4**
> - **Extended zone (beyond ±2σ):** direction is **committed immediately** — reversion toward the mean, **no confirmation step**. Enter on the first BOS or reversal trigger toward the mean, take it to the RR target.
> - **Confirmation zone (±1↔±2) is now flip-enabled (critical).** The rejection/breakthrough gives only a *provisional lean*. The actual trade follows the **first structural trigger (BOS or reversal) in either direction**. If price leans long (e.g. rejects and holds above +1) but then the bulls lose power and a **bearish BOS** forms, the EA **flips and shorts that break** — and vice-versa. Direction is *not* committed in this zone until a trigger fires.
> - Direction lock is unchanged and applies only **after the first trade** of the session; the pre-entry flip lives entirely inside the confirmation zone.

---

## 1. Strategy summary

Trade XAUUSD in two intraday windows (Asia, NY — Riyadh time), judged against an **Anchored VWAP** with **±1σ and ±2σ bands** anchored to a significant swing from the most recent *volatile* prior session. Price's **zone** sets the directional stance; the trade is **timed** by a **BOS** or a **Reversal + Momentum** trigger. Stop at the trigger's swing extreme + buffer, target at configurable RR (default 1:1.5). One trade per session (a second attempt only after a stop-out, same direction), force-close at session end.

### The three zones (upper half; mirror below)

| Price zone | Meaning | Direction stance |
|---|---|---|
| VWAP → **+1σ** | Direct trend | **Long committed** — enter on a long trigger |
| **+1σ → +2σ** | Confirmation (contested) | **Not committed** — provisional lean from rejection/breakthrough, but the trade follows the **first BOS/reversal in either direction (flip-enabled)** |
| beyond **+2σ** | Extended | **Short committed** immediately (reversion) — enter on a short trigger toward the mean |

Lower half mirrors: VWAP→−1 short committed; −1→−2 confirmation (flip-enabled); beyond −2 long committed (reversion).

**A trade always needs a trigger** (BOS or Reversal+Momentum), never just the zone.

---

## 2. Definitions & terminology

| Term | Meaning |
|---|---|
| **AVWAP** | Anchored VWAP, cumulated from the anchor bar to now. |
| **σ bands** | AVWAP ± n·σ (volume-weighted stdev), n = 1, 2. |
| **Anchor** | Bar AVWAP starts from — a significant ZigZag swing in a chosen prior session. |
| **Anchor / BOS detectors** | ZigZag (anchor swing) and fractal pivots (structure/BOS) — independent. |
| **BOS** | Break of the most recent confirmed swing high (bull) / low (bear). |
| **Reversal+Momentum** | Sharp counter-move then a strong reversal candle (§9.3). |
| **Rejection / Breakthrough** | A band level holds / is closed through with momentum (§9.1). |
| **Provisional lean** | The direction the confirmation zone *expects*; informational — the trigger decides. |
| **Flip** | In the confirmation zone, taking the opposite side to the lean when the opposite structure breaks first. |
| **R** | Risk = \|entry − stop\|; Target = entry ± RR·R. |
| **Direction lock** | After the first trade of a session, direction is fixed for that session. |

Prices in symbol units unless "points" (1 point = `_Point`, XAUUSD ≈ 0.01).

---

## 3. Timeframe & data
- **M5**, closed bars only (`[1]`).
- History ≥ `MaxAnchorLookbackHours` (48h ≈ 576 M5 bars) + warm-up.
- Read all symbol specs dynamically.
- **Volume = tick volume** on gold → AVWAP/σ are a broker proxy, won't match TradingView exactly; `VolumeSource` parameterized. Backtest **"Every tick based on real ticks."**

---

## 4. Time & session engine (DST-safe)
UTC internally; broker→UTC offset recomputed per bar (`BrokerToUTC_WinterOffsetHours`, `BrokerObservesDST=true`, `BrokerDSTCalendar=US`).

| Session | Riyadh (UTC+3) | Role |
|---|---|---|
| Asia | 03:00–06:00 | Trade + anchor |
| London | 09:00–12:00 | Anchor only |
| New York | 15:00–18:00 | Trade + anchor |

`SessionTimeMode=FIXED_RIYADH` (alt `TRACK_MARKET`). `SessionForceCloseOffsetSec=0`, `NoNewEntryOffsetSec=0`. Per-session enable/role configurable.

---

## 5. AVWAP + σ bands
- `PriceInput=HLC3`, `VolumeSource=TICK_VOLUME`, `Band1Multiplier=1.0`, `Band2Multiplier=2.0` (both active/drawn).
```
VWAP = Σvᵢpᵢ/Σvᵢ ;  σ = sqrt(max(0, Σvᵢpᵢ²/Σvᵢ − VWAP²))
U1=VWAP+σ  U2=VWAP+2σ  L1=VWAP−σ  L2=VWAP−2σ
```
- Running sums; anchor **locked at session open** (no repaint); band logic suppressed until `MinBarsSinceAnchor=5`.

---

## 6. Swing detectors
- **Anchor ZigZag (classic MT5):** `ZZ_Depth=24`, `ZZ_Deviation=5`, `ZZ_Backstep=2`; confirmed pivots only.
- **BOS fractals:** `BOS_SwingDepth=3`; confirmed after right-side bars close. Alt `BOS_UseZigZagForStructure=false`.

---

## 7. Anchor selection & session-quality (relative)
At session open: first qualifying prior session (backwards, ≤ `MaxAnchorLookbackHours`) supplies its most recent significant ZigZag pivot (± `AnchorFlexMinutes=60`) as anchor; else `NoAnchorAction=SKIP_SESSION`.

**Volatility detection — all ATR-normalized / ratio-based (no point thresholds):** ATR (`AtrPeriod=14`) + rolling median range of last `QualityBaselineN=20` same-type sessions. Metrics: range/baseline (`≥0.80`), range/ATR (`≥3.0`), largest ZigZag leg/ATR (`≥1.5`) or /baseline (`≥0.5`), Kaufman efficiency (`≥0.30`), optional displacement/pivot-count. `SessionQualityMode=SCORE` (weights: leg .35, eff .30, range/base .20, range/ATR .15; pass ≥ `QualityScoreThreshold=0.6`).

---

## 8. Regime & direction (three zones)

Evaluated on **every closed M5 bar for the whole active session**, until the first trade opens (then direction locks, §11). `d = price − vwap`.

### Z1 — DIRECT (|d| < 1σ) — direction committed (trend)
- `d>0` → **long committed**; `d<0` → **short committed**.
- Enter on the first trigger **in the committed direction** (§9). No flip by default (`AllowFlipInDirectZone=false`).

### Z2 — CONFIRMATION (1σ ≤ |d| < 2σ) — direction NOT committed (flip-enabled)
This zone is contested. Behaviour while price is in it (state = `CONFIRMING`, persists up to `ConfirmStateMaxBars=12` bars or until price exits the zone / session ends):

1. **Provisional lean** (informational, from §9.1):
   - Upper: rejection holding +1 as support → lean **long**; breakdown through +1 (toward VWAP) → lean **short**; breakout through +2 → transition to **Extended** (Z3).
   - Lower: rejection holding −1 as resistance → lean **short**; breakup through −1 (toward VWAP) → lean **long**; breakdown through −2 → transition to **Extended**.
2. **Entry follows structure (the critical rule):** hunt for a **BOS or Reversal+Momentum trigger in *either* direction**. **The first valid trigger's direction is the trade direction**, regardless of the lean.
   - Trigger agrees with lean → normal entry.
   - Trigger opposes the lean (e.g. leaned long after a +1 rejection, then a **bearish BOS** shows bulls lost power) → **flip and take the short on that break.** Symmetric for the long-flip.
3. `ConfirmZoneFollowStructure=true` governs this; if set false, Z2 would only accept lean-direction triggers (not recommended — loses the flip).

### Z3 — EXTENDED (|d| ≥ 2σ) — direction committed immediately (reversion)
- Above +2 → **short committed** (revert to mean); below −2 → **long committed**.
- **No confirmation step.** Enter on the first trigger (BOS or reversal) **toward the mean**, take it to the RR target. No flip by default (`AllowFlipInExtendedZone=false`).

**Zone transitions:** zone is recomputed each bar from price vs bands. A `CONFIRMING` state that produces a valid trigger fires immediately (the flip is captured at the break bar), so a bearish break down through +1 is taken as a short even as price crosses into the Z1 band — the confirmation trigger takes precedence over re-zoning until it resolves or the state times out.

*(Consistency: Ex6 = +1 rejection → long; Ex5 = momentum break of lower bands → long; new attached chart = Reversal+Momentum long in Z1; the described flip = +1 rejection lean long, bearish BOS → short.)*

---

## 9. Entries

`EntryMode=BOTH` (`BOS_ONLY`/`REVERSAL_ONLY`/`BOTH`); first valid trigger takes the trade. Which directions are hunted:
- **Z1:** committed direction only (unless `AllowFlipInDirectZone`).
- **Z2:** **both directions** (flip-enabled).
- **Z3:** committed reversion direction only (unless `AllowFlipInExtendedZone`).

### 9.1 Rejection & breakthrough primitives (programmable, closed bars)
```
rejectionAsSupport(bar,B):    low[bar] <= B+TouchTolSigma·σ  AND close[bar] >= B+RejectCloseSigma·σ
                              AND (!RejectRequireWick OR lowerWick(bar) >= RejectWickMinFrac·range(bar))
rejectionAsResistance(bar,B): high[bar]>= B−TouchTolSigma·σ  AND close[bar] <= B−RejectCloseSigma·σ
                              AND (!RejectRequireWick OR upperWick(bar) >= RejectWickMinFrac·range(bar))
breakUp(bar,B):   close[bar] >= B+BreakBufferSigma·σ  AND (!BreakRequireMomentum OR bullBody(bar) >= BreakBodyATR·ATR)
breakDown(bar,B): close[bar] <= B−BreakBufferSigma·σ  AND (!BreakRequireMomentum OR bearBody(bar) >= BreakBodyATR·ATR)
```
Defaults: `TouchTolSigma=0.10`, `RejectCloseSigma=0.05`, `RejectRequireWick=true`, `RejectWickMinFrac=0.5`, `BreakBufferSigma=0.15`, `BreakRequireMomentum=true`, `BreakBodyATR=0.8`. These feed the **provisional lean** (§8 Z2) and the ±2 → Extended transition. In Z2 the **entry direction is the trigger direction**, not the lean.

### 9.2 Entry Type A — BOS
Break the latest **confirmed** structure swing (long → last swing high; short → last swing low). `BOS_ConfirmMode=CLOSE` (close beyond by ≥ `BOS_BufferPoints=0`; alt `WICK`). BOS leg → `legHigh/legLow/legRange`. Entry `EntryFillMode=BOS_CLOSE` (alt `NEXT_OPEN`), market.

### 9.3 Entry Type B — Reversal + Momentum
(No structure to wait on; matches the attached chart.) For the traded direction (LONG shown; mirror short), on closed bars:
1. Sharp counter-move within `RevCounterLookback=8` bars, size ≥ `RevMinCounterMoveATR·ATR` (0.8), ending at local extreme `revLow`.
2. Momentum reversal candle: bull body ≥ `RevBodyATR·ATR` (1.0), close in top `RevCloseLocPct` of range (0.33); optional `RevRequireEngulf=false` or close breaks last `RevBreakBars=2` highs.
3. `RevConfirmCloses=1` confirming; `revLow` must hold.
`revLow`/`revHigh` = protected extreme for the stop. In Z2, a reversal in either direction is a valid (flip-capable) trigger; in Z1/Z3 only the committed direction.

---

## 10. Stop, target, sizing (all configurable)
- Stop = trigger's protected extreme ± buffer (BOS leg or reversal extreme). `SL_BufferMode=PCT_OF_LEG` (0.10×legRange; alt `ATR`/`POINTS`), ≥ broker STOPS_LEVEL.
- `R=|entry−SL|`; `TP=entry±RR·R`; **`RR=1.5`** (configurable).
- `RiskMode=PERCENT` (`RiskPercent=0.5`) → lot from R & tick value; alt `FIXED_LOT`. `MinStopATRmult=0`; `ClampStopsToBroker=true`.
- Optional caps (off): daily/weekly loss, daily profit stop.

---

## 11. Trade & session management
- One trade/session, `MaxTriesPerSession=2`.
- **Pre-entry:** in Z2 the direction can flip freely with the structure (that is the point of the zone). **Post-entry:** the first trade **locks `sessionDirection`; it never changes** that session.
- Re-entry only if `SecondTryOnlyAfterSL=true`, first stopped out, fresh trigger in the **same** locked direction. A win closes the session (`AllowReentryAfterWin=false`).
- Force-flat at session end (`CloseOnSessionEnd=true`). One position/`MagicNumber`. `MaxSpreadPoints=50`, `MaxSlippagePoints=20`. Optional news filter (stub).

---

## 12. Repaint & look-ahead safety
Closed-bar signals; anchor locked from confirmed prior-session pivots; BOS from confirmed fractals, reversal from closed candles; Tester "Every tick based on real ticks"; no forming-bar highest/lowest in signals.

---

## 13. Parameter reference

**General:** `MagicNumber`, `BaseTF=M5`, `VolumeSource=TICK_VOLUME`, `MaxSpreadPoints=50`, `MaxSlippagePoints=20`

**Time/sessions:** `SessionTimeMode=FIXED_RIYADH`, `BrokerToUTC_WinterOffsetHours=auto`, `BrokerObservesDST=true`, `BrokerDSTCalendar=US`, Asia(T,Trade=T,03–06), London(T,Trade=F,09–12), NY(T,Trade=T,15–18), `AnchorFlexMinutes=60`, `MaxAnchorLookbackHours=48`, `NoNewEntryOffsetSec=0`, `SessionForceCloseOffsetSec=0`, `CloseOnSessionEnd=true`

**AVWAP/bands:** `PriceInput=HLC3`, `Band1Multiplier=1.0`, `Band2Multiplier=2.0`, `MinBarsSinceAnchor=5`

**Anchor ZigZag:** `ZZ_Depth=24`, `ZZ_Deviation=5`, `ZZ_Backstep=2`

**Session-quality:** `SessionQualityMode=SCORE`, `QualityScoreThreshold=0.6`, `QualityBaselineN=20`, `AtrPeriod=14`, `MinRangeRatio=0.80`, `MinRangeATR=3.0`, `MinLegATR=1.5`, `MinLegRatio=0.5`, `MinEfficiency=0.30`, `UseDisplacement=F`, `MinDisplacementRatio=0.35`, `UsePivotCount=F`, `MaxPivotCount=8`, `NoAnchorAction=SKIP_SESSION`

**Zones/confirmation/flip:** `ConfirmZoneFollowStructure=true`, `ConfirmStateMaxBars=12`, `AllowFlipInDirectZone=false`, `AllowFlipInExtendedZone=false`, `TouchTolSigma=0.10`, `RejectCloseSigma=0.05`, `RejectRequireWick=true`, `RejectWickMinFrac=0.5`, `BreakBufferSigma=0.15`, `BreakRequireMomentum=true`, `BreakBodyATR=0.8`

**Entries:** `EntryMode=BOTH`
- BOS: `BOS_UseZigZagForStructure=false`, `BOS_SwingDepth=3`, `BOS_ConfirmMode=CLOSE`, `BOS_BufferPoints=0`, `EntryFillMode=BOS_CLOSE`
- Reversal: `RevCounterLookback=8`, `RevMinCounterMoveATR=0.8`, `RevBodyATR=1.0`, `RevCloseLocPct=0.33`, `RevRequireEngulf=false`, `RevBreakBars=2`, `RevConfirmCloses=1`

**Risk/exits:** `RR=1.5`, `SL_BufferMode=PCT_OF_LEG`, `SL_BufferPct=0.10`, `SL_BufferATRmult=0`, `SL_BufferPoints=0`, `MinStopATRmult=0`, `ClampStopsToBroker=true`, `RiskMode=PERCENT`, `RiskPercent=0.5`, `FixedLot=0.01`, loss caps off by default

**Management:** `MaxTriesPerSession=2`, `SecondTryOnlyAfterSL=true`, `AllowReentryAfterWin=false`, `UseNewsFilter=false`

**Diagnostics:** `DrawObjects=true`, `VerboseLog=true`, `ExportTradeCSV=true`

---

## 14. Per-bar processing flow

```
OnNewM5BarClose():
    now=brokerToUTC(time[1]); updateATR(); updateSessionHistory(); updateZigZag(); updateFractals()
    session = activeTradeWindow(now)
    if session==NONE: handleForceClose(); return
    if isSessionOpenBar(session):
        lockAnchor(selectAnchor(session)); resetState(tries=0, sessionDirection=NONE, confirmState=idle)
    if anchor==NONE: return
    updateAVWAP()

    if withinEntryWindow(now) and tries<MaxTriesPerSession and noOpenPosition():
        if sessionDirection != NONE:
            takeIfTrigger(sessionDirection)                 // locked: same direction only
        else:
            zone = classifyZone(price, vwap, σ)             // Z1/Z2/Z3
            if zone==Z1:  takeIfTrigger(directBias)          // committed; flip only if AllowFlipInDirectZone
            elif zone==Z3: takeIfTrigger(reversionBias)      // committed toward mean
            elif zone==Z2:                                   // contested / flip-enabled
                updateProvisionalLean()                      // §9.1 (informational)
                trig = firstTriggerEitherDirection()         // BOS or reversal, long OR short
                if trig != NONE: openTrade(trig.direction)   // flip = trig opposes lean
        onOpen: tries++; if sessionDirection==NONE: sessionDirection = tradedDirection

    if isForceCloseTime(session): closeAllForThisEA()
```

`takeIfTrigger(dir)` = open a trade if a BOS or reversal in `dir` is confirmed this bar.

---

## 15. Edge cases
Wall-clock gaps; 0-volume/short sessions fail quality; σ≈0 suppresses band logic until warm-up; too-tight R skipped; Z2 `CONFIRMING` trigger takes precedence over re-zoning until resolved/timed-out; broker offset recomputed per bar; per-bar re-evaluation until first entry, then locked.

---

## 16. Logging & visualization
On-chart: AVWAP + both bands, anchor, session box, zone label, provisional lean, trigger (BOS level / reversal candle), entry/SL/TP, and a flag when a **flip** occurred. `ExportTradeCSV` with zone, lean, trigger-type, flip-flag, direction, result → expectancy analysis by zone/trigger/flip.

---

## 17. Backtesting & validation
1. **Acceptance tests:** Ex1 short/trend, Ex2 long/trend, Ex3 short beyond +2, Ex4 long beyond −2, Ex5 lower-band momentum break → long, Ex6 +1 rejection → long, attached chart → Reversal+Momentum long, **plus a Z2 flip case** (lean long, bearish BOS → short).
2. 2–3y XAUUSD M5, real-tick, realistic costs.
3. Split Asia vs NY; likely per-session parameter sets.
4. Metrics by zone / trigger-type / flip vs non-flip / session: expectancy (R), win rate, frequency, DD, profit factor.
5. Walk-forward/OOS; sensitivity; broker-to-broker check.

---

## 18. Assumptions locked
- Extended = immediate committed reversion direction, no confirmation, trigger toward mean, RR target.
- Confirmation zone = provisional lean but **entry follows the first BOS/reversal in either direction (flip-enabled)**; the flip is a first-class behaviour, default on.
- Direct & Extended zones are committed (no flip) by default; toggles exist.
- Direction lock applies only after the first trade of the session.
- All detection relative/ATR-based; all risk configurable.
- To tune during build: momentum thresholds (`BreakBodyATR`, `RevBodyATR`, `RevMinCounterMoveATR`), `ConfirmStateMaxBars`, and the flip's sensitivity — calibrated against your labeled examples.

---

## 19. Build phases
P0 Time/session · P1 AVWAP+bands · P2 ZigZag anchor + session-quality · P3 Zone classifier + rejection/breakthrough + BOS + Reversal + **Z2 flip** + execution · P4 Risk/management/direction-lock/caps · P5 Backtest harness + CSV + acceptance tests + tuning.

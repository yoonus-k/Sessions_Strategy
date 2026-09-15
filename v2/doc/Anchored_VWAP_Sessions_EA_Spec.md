# Anchored VWAP Sessions Strategy — MQL5 EA Specification

**Instrument:** XAUUSD  **Platform:** MetaTrader 5 (MQL5 Expert Advisor)  **Base timeframe:** M5
**Spec version:** v0.9 (draft for review)

> **Changelog v0.8 → v0.9 (2026-09-15, behavior change — user request)**
> - **`RiskMode=PERCENT` now sizes off the INITIAL balance, not the live/current one.** Previously
>   `RiskMoney()` read `AccountInfoDouble(ACCOUNT_BALANCE)` fresh on every call, so the $ risked per
>   trade compounded up as the account grew and shrank as it drew down. User's request:
>   **"make it from the initial balance... on the 100k account, we should risk $1000 on every
>   trade whether the current balance is 150k or 80k."** `CRiskV2` now captures
>   `AccountInfoDouble(ACCOUNT_BALANCE)` exactly once, in `Init()` (EA start / tester start), and
>   `RiskMoney()` multiplies `riskPercent` against that frozen value forever after. See §10.
>
> **Changelog v0.7 → v0.8 (2026-09-15, new feature — user request)**
> - **Entry window added.** New `EntryWindowMinutes` (default `30`): a NEW trade (including a
>   2nd-try re-entry) may only open within this many minutes of the session's own scheduled open —
>   `0` disables the cutoff. `CTimeSessions::WithinEntryWindow()` — until now checked only the
>   late-session `NoNewEntryOffsetSec` cutoff and, despite being named in this spec's own §14
>   pseudocode since it was written, was **never actually called** by either real-order-placing EA
>   (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`) — now gates the decision-taking block in
>   both. See §11, §13.
>
> **Changelog v0.6 → v0.7 (2026-09-15, new feature — user request)**
> - **Breakeven added.** New `BeEnabled`/`BeTriggerR` risk parameters (default on, `0.5`): once a
>   trade's floating profit reaches `BeTriggerR × R` (its own original entry→SL distance), the SL
>   moves to entry and stays there — a one-way move, checked every tick, independent of the
>   1.5R `RR` target. `CTradeManagerV2::ManageBreakEven()`; see §10.
>
> **Changelog v0.5 → v0.6 (2026-09-15, second user correction, same day)**
> - **CONFIRMATION regime (session opened Z2) now requires an "armed" gate before any trigger is
>   hunted.** v0.5 let a CONFIRMATION-regime session take a trigger from wherever price happened to
>   be inside Z2, including deep near the Z3 boundary, having never approached VWAP. User's
>   screenshot showed exactly that: a short BOS taken at `dSigma=-1.89`. Fix: the session must first
>   see price **touch Z1** (close or wick reaching the ±1σ band) at least once — a one-way latch,
>   never un-arms once set — before ANY trigger is evaluated. Once armed, the existing BOS/Reversal
>   hunt-both logic is unchanged and **is** the "how does price react" check the user described (a
>   BOS = broke through with momentum, a Reversal+Momentum trigger = snapped back). If price never
>   touches Z1 all session, no trade fires that session. See §8.
>
> **Changelog v0.4 → v0.5 (2026-09-15, user correction)**
> - **Regime lock moved to session open.** v0.4 said the zone was re-evaluated on every closed bar
>   until the first trade opened, with direction only locking post-entry. That was a
>   misunderstanding of the intended design. The regime (CONTINUATION/REVERSAL/CONFIRMATION) is now
>   captured **once, at session open**, from whichever zone price is in at that moment, and held
>   **fixed for the rest of the session** — never re-derived from a later bar, even if price drifts
>   into a different band. See §8.
> - Session opens in Z1 → **CONTINUATION**, direction locked immediately (long/short per that bar's
>   `d`). Session opens in Z3 → **REVERSAL**, locked to the reversion direction immediately. Session
>   opens in Z2 → **CONFIRMATION**, the one case with **no** direction lock: both sides stay hunted,
>   flip-enabled, for the **entire** session (not just while price remains inside the Z2 band).
> - The post-entry `sessionDirection` lock (first trade fixes direction for re-entries) is
>   unchanged and still applies on top of the regime lock once a trade exists.
>
> **Changelog v0.3 → v0.4**
> - **Extended zone (beyond ±2σ):** direction is **committed immediately** — reversion toward the mean, **no confirmation step**. Enter on the first BOS or reversal trigger toward the mean, take it to the RR target.
> - **Confirmation zone (±1↔±2) is now flip-enabled (critical).** The rejection/breakthrough gives only a *provisional lean*. The actual trade follows the **first structural trigger (BOS or reversal) in either direction**. If price leans long (e.g. rejects and holds above +1) but then the bulls lose power and a **bearish BOS** forms, the EA **flips and shorts that break** — and vice-versa. Direction is *not* committed in this zone until a trigger fires.
> - Direction lock is unchanged and applies only **after the first trade** of the session; the pre-entry flip lives entirely inside the confirmation zone.

---

## 1. Strategy summary

Trade XAUUSD in two intraday windows (Asia, NY — Riyadh time), judged against an **Anchored VWAP** with **±1σ and ±2σ bands** anchored to a significant swing from the most recent *volatile* prior session. The zone price is in **at session open** sets the session's **regime** — locked for the whole session (§8); the trade is **timed** by a **BOS** or a **Reversal + Momentum** trigger. Stop at the trigger's swing extreme + buffer, target at configurable RR (default 1:1.5). One trade per session (a second attempt only after a stop-out, same direction), force-close at session end.

### The three zones, and the regime each locks at session open (upper half; mirror below)

| Session-open zone | Meaning | Regime locked for the whole session |
|---|---|---|
| VWAP → **+1σ** | Direct trend | **CONTINUATION, long locked** — hunt only long triggers, all session |
| **+1σ → +2σ** | Confirmation (contested) | **CONFIRMATION, no lock** — provisional lean from rejection/breakthrough, but the trade follows the **first BOS/reversal in either direction (flip-enabled)**, for the whole session |
| beyond **+2σ** | Extended | **REVERSAL, short locked** (reversion) — hunt only short triggers, all session |

Lower half mirrors: VWAP→−1σ = CONTINUATION, short locked; −1σ→−2σ = CONFIRMATION, no lock; beyond −2σ = REVERSAL, long locked (reversion).

**This is decided once, at session open, and does not change for the rest of the session even if price later moves into a different band** (§8, 2026-09-15 correction).

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
| **Regime lock** | (2026-09-15) The zone at session open decides CONTINUATION/REVERSAL (direction locked immediately, held all session) or CONFIRMATION (session opened in Z2, no lock, both sides hunted all session). Captured once, never re-derived from a later bar. |
| **Direction lock** (`sessionDirection`) | A *separate*, post-entry lock: after the first trade of a session, direction is fixed for that session (governs 2nd-try re-entries). Applies on top of the regime lock, regardless of which regime produced the first trade. |

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

> **Correction, 2026-09-15 (supersedes the "evaluated every closed bar" text below the user
> originally reviewed):** the regime is captured **once, at session open** — practically the
> session's own opening bar, since AVWAP is already warmed up by the anchor pre-roll (§7) — and
> held **fixed for the rest of the session**. It is never re-derived from a later bar's zone, even
> if price subsequently drifts into a different band. This is a deliberate, user-specified design,
> not a bug: "lock the dir when session opens for the continuation and reversal dir... the dir for
> this session is long for this entire session, and we look only for buys, and vice versa." Z2 is
> the one exception — see below.

At the first AVWAP-ready closed bar of the trade session, classify `d = price − vwap` into a zone,
exactly as before, and that classification becomes the session's **regime** for its entire
duration:

### Session opens in Z1 (|d| < 1σ) → **CONTINUATION regime, direction locked**
- `d>0` at that opening bar → **long locked**; `d<0` → **short locked**.
- For the rest of the session, hunt **only** that direction's trigger (§9), regardless of how the
  zone/price moves afterward. No flip by default (`AllowFlipInDirectZone=false`).

### Session opens in Z3 (|d| ≥ 2σ) → **REVERSAL regime, direction locked**
- Above +2σ at that opening bar → **short locked** (reversion); below −2σ → **long locked**.
- Same as above: hunt only that direction for the rest of the session, ignoring later zone
  changes. No flip by default (`AllowFlipInExtendedZone=false`).

### Session opens in Z2 (1σ ≤ |d| < 2σ) → **CONFIRMATION regime, NO direction lock**
Z2 at open is explicitly the *no-lock* case — the user's own words: *"there is no locking rigid
dir, it's like confirmation, whoever wins we open a trade with it."* For the **entire session**
(not merely while price is still literally inside the Z2 band):

1. **Provisional lean** (informational only, from §9.1) — tracked continuously, purely a display
   label, never restricts which trigger can fire:
   - Upper: rejection holding +1 as support → lean **long**; breakdown through +1 (toward VWAP) →
     lean **short**; breakout through +2 → Extended-transition flag (display only).
   - Lower: mirrors at −1/−2.
2. **Armed gate (2026-09-15, second correction):** triggers are **not** hunted from wherever price
   happens to be inside Z2. The EA must first observe price actually **touch Z1** — a closed bar's
   **close or wick** reaching the ±1σ band — at least once this session. Until that happens, no
   trigger is evaluated at all, regardless of what fires. This is a one-way latch: once armed by a
   single touch, it stays armed for the rest of the session even if price then retreats back into
   Z2/Z3. If price never touches Z1 for the whole session, no trade is taken that session.
3. **Entry follows structure, once armed:** hunt for a **BOS or Reversal+Momentum trigger in
   *either* direction**, every closed bar, for the rest of the session. **The first valid
   trigger's direction is the trade direction**, regardless of the lean or of where price has
   since wandered (even into what would otherwise read as Z1 or Z3 territory). This *is* the "how
   does price react" check — a BOS means it broke through Z1 with momentum, a Reversal+Momentum
   trigger means it snapped back.
   - Trigger agrees with lean → normal entry.
   - Trigger opposes the lean → **flip**, informational tag only (`isFlip`), does not change
     whether the trade is taken.

If the session-open bar's own `d` is exactly `0.0` (price exactly at VWAP, zone Z1/Z3 but no
directional sign yet), regime capture is deferred one bar rather than locking a meaningless
direction.

**Post-entry, the ordinary §11 direction lock still applies on top of this**, and takes
precedence: once the first trade of the session has opened, only that direction's trigger is ever
checked again (governs 2nd-try re-entries), regardless of which regime produced it.

*(Consistency: Ex6 = +1 rejection → long; Ex5 = momentum break of lower bands → long; new attached
chart = Reversal+Momentum long in Z1; the described flip = +1 rejection lean long, bearish BOS →
short — all still hold, they just now describe the regime captured at session open rather than a
per-bar re-evaluation.)*

---

## 9. Entries

`EntryMode=BOTH` (`BOS_ONLY`/`REVERSAL_ONLY`/`BOTH`); first valid trigger takes the trade. Which directions are hunted (per the session's locked regime, §8 — not the live per-bar zone):
- **CONTINUATION regime (session opened Z1):** locked direction only (unless `AllowFlipInDirectZone`).
- **CONFIRMATION regime (session opened Z2):** **both directions**, for the whole session (flip-enabled, no lock) — but only once **armed** (price has touched Z1 by close or wick at least once; §8).
- **REVERSAL regime (session opened Z3):** locked reversion direction only (unless `AllowFlipInExtendedZone`).

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
`revLow`/`revHigh` = protected extreme for the stop. In the CONFIRMATION regime (session opened in Z2), a reversal in either direction is a valid (flip-capable) trigger; in CONTINUATION/REVERSAL regimes only the locked direction.

---

## 10. Stop, target, sizing (all configurable)
- Stop = trigger's protected extreme ± buffer (BOS leg or reversal extreme). `SL_BufferMode=PCT_OF_LEG` (0.10×legRange; alt `ATR`/`POINTS`), ≥ broker STOPS_LEVEL.
- `R=|entry−SL|`; `TP=entry±RR·R`; **`RR=1.5`** (configurable).
- `RiskMode=PERCENT` (`RiskPercent=0.5`) → lot from R & tick value; alt `FIXED_LOT`. `MinStopATRmult=0`; `ClampStopsToBroker=true`.
- **`RiskMode=PERCENT` sizes off the INITIAL balance (2026-09-15, user request), not the live one:**
  `RiskPercent × ACCOUNT_BALANCE at CRiskV2::Init()` (captured once, at EA start), never re-read
  from the live account afterward. The money risked per trade is therefore constant for the whole
  run — a 1% setting on a 100k account risks $1,000/trade whether the live balance has since
  grown to 150k or drawn down to 80k. (Deliberately different from `LotForRisk`'s SL/TP price
  math, which still reads live broker state via `OrderCalcProfit` — only the BUDGET is frozen, not
  the price conversion.)
- **Breakeven (2026-09-15):** once price moves `BeTriggerR × R` in the trade's favor — `R` fixed at
  the trade's own original entry→SL distance, never re-measured after the stop moves — the broker SL
  is moved to entry exactly once (`BeEnabled=true`, `BeTriggerR=0.5` default, i.e. arms at 0.5R with
  a 1.5R target). One-way: never re-arms, never moves the SL backward. A rejected `PositionModify`
  (e.g. broker stops-level) is retried silently on later ticks rather than being marked done — same
  discipline as v1's `AllOpenAtBreakEven`, which never lets the flag claim protection that isn't live.
- Optional caps (off): daily/weekly loss, daily profit stop.

---

## 11. Trade & session management
- One trade/session, `MaxTriesPerSession=2`.
- **Entry window (2026-09-15, user request):** a NEW trade (including a 2nd-try re-entry) may only
  open within `EntryWindowMinutes` (default **30**) of the session's own scheduled open — measured
  from `SessionOpenBroker`, not from whenever AVWAP first went ready. Once elapsed, no trade opens
  for the rest of that session, regardless of tries remaining or a fresh trigger firing; the next
  opportunity is the next session's own window. `EntryWindowMinutes=0` disables the cutoff
  (unlimited, matching how `NoNewEntryOffsetSec=0` already disables its own cutoff near the close).
  `CTimeSessions::WithinEntryWindow()` — already checked the late-session `NoNewEntryOffsetSec`
  cutoff; now ALSO checks this early-session one. Regime capture and the CONFIRMATION arm-latch
  (§8) keep running every bar regardless — only the act of OPENING a trade is gated, so the
  dashboard's regime/armed state stays accurate even after the window closes.
- **Two locks apply, in order:**
  1. **Regime lock (§8, pre-entry):** captured once at session open. CONTINUATION/REVERSAL regimes
     lock a single hunted direction for the whole session immediately, before any trade exists.
     CONFIRMATION regime (session opened in Z2) locks no direction — both sides stay hunted, flip
     freely with the structure, for the entire session.
  2. **`sessionDirection` lock (post-entry):** the first trade **locks `sessionDirection`; it never
     changes** that session — this is what governs re-entries, and applies the same way regardless
     of which regime produced the first trade (even a CONFIRMATION-regime trade locks
     `sessionDirection` to whichever side actually filled).
- Re-entry only if `SecondTryOnlyAfterSL=true`, first stopped out, fresh trigger in the **same** locked direction. A win closes the session (`AllowReentryAfterWin=false`).
- Force-flat at session end (`CloseOnSessionEnd=true`). One position/`MagicNumber`. `MaxSpreadPoints=50`, `MaxSlippagePoints=20`. Optional news filter (stub).

---

## 12. Repaint & look-ahead safety
Closed-bar signals; anchor locked from confirmed prior-session pivots; BOS from confirmed fractals, reversal from closed candles; Tester "Every tick based on real ticks"; no forming-bar highest/lowest in signals.

---

## 13. Parameter reference

**General:** `MagicNumber`, `BaseTF=M5`, `VolumeSource=TICK_VOLUME`, `MaxSpreadPoints=50`, `MaxSlippagePoints=20`

**Time/sessions:** `SessionTimeMode=FIXED_RIYADH`, `BrokerToUTC_WinterOffsetHours=auto`, `BrokerObservesDST=true`, `BrokerDSTCalendar=US`, Asia(T,Trade=T,03–06), London(T,Trade=F,09–12), NY(T,Trade=T,15–18), `AnchorFlexMinutes=60`, `MaxAnchorLookbackHours=48`, `EntryWindowMinutes=30`, `NoNewEntryOffsetSec=0`, `SessionForceCloseOffsetSec=0`, `CloseOnSessionEnd=true`

**AVWAP/bands:** `PriceInput=HLC3`, `Band1Multiplier=1.0`, `Band2Multiplier=2.0`, `MinBarsSinceAnchor=5`

**Anchor ZigZag:** `ZZ_Depth=24`, `ZZ_Deviation=5`, `ZZ_Backstep=2`

**Session-quality:** `SessionQualityMode=SCORE`, `QualityScoreThreshold=0.6`, `QualityBaselineN=20`, `AtrPeriod=14`, `MinRangeRatio=0.80`, `MinRangeATR=3.0`, `MinLegATR=1.5`, `MinLegRatio=0.5`, `MinEfficiency=0.30`, `UseDisplacement=F`, `MinDisplacementRatio=0.35`, `UsePivotCount=F`, `MaxPivotCount=8`, `NoAnchorAction=SKIP_SESSION`

**Zones/confirmation/flip:** `ConfirmZoneFollowStructure=true`, `ConfirmStateMaxBars=12`, `AllowFlipInDirectZone=false`, `AllowFlipInExtendedZone=false`, `TouchTolSigma=0.10`, `RejectCloseSigma=0.05`, `RejectRequireWick=true`, `RejectWickMinFrac=0.5`, `BreakBufferSigma=0.15`, `BreakRequireMomentum=true`, `BreakBodyATR=0.8`

**Entries:** `EntryMode=BOTH`
- BOS: `BOS_UseZigZagForStructure=false`, `BOS_SwingDepth=3`, `BOS_ConfirmMode=CLOSE`, `BOS_BufferPoints=0`, `EntryFillMode=BOS_CLOSE`
- Reversal: `RevCounterLookback=8`, `RevMinCounterMoveATR=0.8`, `RevBodyATR=1.0`, `RevCloseLocPct=0.33`, `RevRequireEngulf=false`, `RevBreakBars=2`, `RevConfirmCloses=1`

**Risk/exits:** `RR=1.5`, `SL_BufferMode=PCT_OF_LEG`, `SL_BufferPct=0.10`, `SL_BufferATRmult=0`, `SL_BufferPoints=0`, `MinStopATRmult=0`, `ClampStopsToBroker=true`, `RiskMode=PERCENT`, `RiskPercent=0.5`, `FixedLot=0.01`, `BeEnabled=true`, `BeTriggerR=0.5`, loss caps off by default

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
        lockAnchor(selectAnchor(session))
        resetState(tries=0, sessionDirection=NONE, regime=NOT_CAPTURED, confirmArmed=false, confirmState=idle)
    if anchor==NONE: return
    updateAVWAP()

    // Regime lock (2026-09-15 correction): captured ONCE, on the first
    // AVWAP-ready bar since resetState() above - i.e. at session open -
    // then held fixed for the rest of the session, never re-derived.
    if regime==NOT_CAPTURED and avwapReady():
        zone = classifyZone(price, vwap, σ)                  // Z1/Z2/Z3, this bar only
        if zone==Z1 and directBias!=NONE:  regime = (CONTINUATION, directBias)
        elif zone==Z3 and reversionBias!=NONE: regime = (REVERSAL, reversionBias)
        elif zone==Z2: regime = (CONFIRMATION, NONE)         // no lock - see below
        // else (d==0.0 exactly): stay NOT_CAPTURED, retry next bar

    if withinEntryWindow(now) and tries<MaxTriesPerSession and noOpenPosition():
        if sessionDirection != NONE:
            takeIfTrigger(sessionDirection)                 // post-entry lock: same direction only
        elif regime.mode==CONTINUATION or regime.mode==REVERSAL:
            takeIfTrigger(regime.dir)                        // locked at session open; flip only if AllowFlipIn*Zone
        elif regime.mode==CONFIRMATION:                      // session opened in Z2 - no lock, ever, this session
            updateProvisionalLean()                          // §9.1 (informational, live every bar)
            if not confirmArmed:
                if touchedZ1(bar, vwap, σ): confirmArmed = true   // close OR wick into ±1σ - one-way latch
                else: return                                      // no trigger hunted at all until armed
            trig = firstTriggerEitherDirection()             // BOS or reversal, long OR short - the
                                                              // "how does price react" check itself
            if trig != NONE: openTrade(trig.direction)       // flip = trig opposes lean
        onOpen: tries++; if sessionDirection==NONE: sessionDirection = tradedDirection

    if isForceCloseTime(session): closeAllForThisEA()
```

`takeIfTrigger(dir)` = open a trade if a BOS or reversal in `dir` is confirmed this bar.

---

## 15. Edge cases
Wall-clock gaps; 0-volume/short sessions fail quality; σ≈0 suppresses band logic until warm-up; too-tight R skipped; broker offset recomputed per bar; **regime captured once at session open (§8, 2026-09-15), held fixed all session regardless of later zone drift — CONFIRMATION regime (session opened Z2) is the one case with no direction lock, hunting both sides for the whole session, but only once armed (price has touched Z1 by close or wick at least once — a one-way latch; if it never touches Z1, no trade fires that session)**; `d==0.0` exactly at the capture bar defers regime capture one bar rather than locking a meaningless direction; post-entry `sessionDirection` lock (§11) takes precedence over the regime once a trade exists.

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
- **Regime lock (2026-09-15, user correction): captured once at session open, held fixed all session — not re-evaluated per bar.** Session opens in Z1 → CONTINUATION, locked long/short per that bar's `d`. Session opens in Z3 → REVERSAL, locked to the reversion direction per that bar's `d`. Session opens in Z2 → CONFIRMATION, no direction lock at all, both sides hunted for the entire session (not just while price is still literally in the Z2 band).
- Extended (REVERSAL regime) = immediate committed reversion direction, no confirmation, trigger toward mean, RR target.
- Confirmation zone (CONFIRMATION regime) = provisional lean but **entry follows the first BOS/reversal in either direction (flip-enabled)**; the flip is a first-class behaviour, default on; this is the one regime with no direction lock.
- **Armed gate (2026-09-15, second correction, same day): CONFIRMATION regime hunts NO trigger at all until price has touched Z1 (close or wick) at least once this session** — a one-way latch, never re-arms/un-arms. Prevents taking a trigger from deep inside Z2 (e.g. `dSigma≈-1.9`) that never approached VWAP. If Z1 is never touched, no trade fires that session.
- CONTINUATION & REVERSAL regimes are committed (no flip) by default; toggles exist (`AllowFlipInDirectZone`/`AllowFlipInExtendedZone`).
- The `sessionDirection` post-entry lock (§11) is separate from the regime lock and applies only after the first trade of the session, on top of whichever regime produced it.
- All detection relative/ATR-based; all risk configurable.
- To tune during build: momentum thresholds (`BreakBodyATR`, `RevBodyATR`, `RevMinCounterMoveATR`), `ConfirmStateMaxBars`, and the flip's sensitivity — calibrated against your labeled examples.

---

## 19. Build phases
P0 Time/session · P1 AVWAP+bands · P2 ZigZag anchor + session-quality · P3 Zone classifier + rejection/breakthrough + BOS + Reversal + **Z2 flip** + execution · P4 Risk/management/direction-lock/caps · P5 Backtest harness + CSV + acceptance tests + tuning.

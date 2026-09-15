# v2 Implementation Plan — Anchored‑VWAP Sessions EA

**Status:** planning only. No v2 code written yet.
**Source of truth for the strategy:** [`Anchored_VWAP_Sessions_EA_Spec.md`](Anchored_VWAP_Sessions_EA_Spec.md) (spec v0.4).
**Reference implementation to mine for infrastructure:** `../v1/` (the shipped M2 sweep/CHoCH EA).
**Reference indicator for the VWAP maths:** `../ref/aVWAP.mq5` (draggable‑anchor VWAP).

This document is the build plan. It does three things:

1. Records what v2 actually is and how it differs from v1 (so the design "sticks").
2. Breaks v2 into **independently testable components**, each with its own throw‑away
   test EA that you run in the Strategy Tester in **visual mode** and verify **by eye**.
3. Defines the order to build them, the acceptance checklist for each, and the
   integration phase once every part passes.

---

## Part A — Understanding v2

### A.1 One‑paragraph summary

Trade XAUUSD on **M5** in two Riyadh‑time windows (Asia 03:00–06:00, NY 15:00–18:00).
At each trade‑session open, drop an **Anchored VWAP** with **±1σ and ±2σ bands**, anchored to
a **significant ZigZag swing taken from the most recent *volatile* prior session**
(Asia / London / NY, London is anchor‑only). Price's position relative to the VWAP and its
bands defines a **zone** (Z1 direct / Z2 confirmation / Z3 extended) which sets the directional
**stance**. A trade is only taken on a **structural trigger** — a **BOS** (break of the last
confirmed fractal swing) or a **Reversal + Momentum** candle pattern. Stop at the trigger's
protected extreme ± buffer, target at **RR = 1.5**. **One trade per session** (a 2nd attempt
only after a stop‑out, in the same locked direction); force‑flat at session end.

### A.2 The three zones (upper half; mirror below). `d = price − vwap`

| Zone | Condition | Stance | Flip? |
|---|---|---|---|
| **Z1 DIRECT** | \|d\| < 1σ | Committed with the trend: d>0 → long, d<0 → short. Enter on first trigger in that direction. | No (toggle `AllowFlipInDirectZone`) |
| **Z2 CONFIRMATION** | 1σ ≤ \|d\| < 2σ | **Not committed.** Rejection/breakthrough of the band gives only a *provisional lean* (informational). The trade follows the **first BOS/Reversal trigger in *either* direction**. Trigger opposing the lean ⇒ **flip**. State `CONFIRMING` persists ≤ `ConfirmStateMaxBars` (12) bars or until price leaves the zone / session ends. | **Yes — default on.** This is the defining behaviour of the zone. |
| **Z3 EXTENDED** | \|d\| ≥ 2σ | Committed **reversion** to the mean immediately, no confirmation step: above +2σ → short, below −2σ → long. Enter on first trigger toward the mean. | No (toggle `AllowFlipInExtendedZone`) |

A trade **always** needs a trigger — the zone alone never opens a position.
Direction **locks after the first trade** of the session and never changes that session;
the pre‑entry flip lives entirely inside Z2 before that first fill.

### A.3 v1 → v2 delta (what carries, what is new, what is dropped)

| Area | v1 (M2 sweep/CHoCH) | v2 (Anchored‑VWAP zones) |
|---|---|---|
| Timeframe | M2 | **M5** |
| Direction source | VWAP anchored to Riyadh **day‑close**, simple open‑above/below at session open | **Anchored VWAP to a ZigZag swing pivot from a volatile prior session**, with **±1σ/±2σ bands** → **3‑zone model** |
| σ bands | none | **±1σ, ±2σ (volume‑weighted stdev)** — central |
| "Which prior session / which bar to anchor to" | n/a (time anchor) | **Session‑quality classifier** (relative, ATR/ratio‑based) + **anchor selection** |
| Entry gate | sweep opposing liquidity (rules 4/5) then CHoCH/IFVG | **zone stance** + **BOS or Reversal+Momentum** trigger; Z2 flip‑enabled |
| Liquidity sweep | required | **removed as a concept** |
| Entry order | pending LIMIT @ 25 % retrace, BOS‑trailing | **market on trigger close** (`EntryFillMode` BOS_CLOSE / NEXT_OPEN) |
| Stop | pattern leg extreme / sweep wick | **trigger's protected extreme ± buffer** (`SL_BufferMode` = PCT_OF_LEG 0.10×legRange / ATR / POINTS) |
| Target | dynamic runner 2.5 %→5 %, ratchet, partial, structure trail | **fixed `RR = 1.5`** |
| Trades / session | up to 3, stop after 1 win | **1**, `MaxTriesPerSession = 2`, 2nd try **only after SL**, same locked direction, win closes session |
| Time zone | fixed broker→Riyadh offset | **DST‑safe**: broker→UTC recomputed per bar, `BrokerObservesDST`, `BrokerDSTCalendar=US`, `SessionTimeMode` FIXED_RIYADH / TRACK_MARKET |
| Charter | 18 Arabic rules | not referenced — the spec is the contract |

**Infrastructure that carries over from v1 with light edits** (do not rewrite from scratch):

- Riyadh↔server time helpers, `ParseHM`, `SessionKey()` idea (`SessionManager.mqh`).
- Broker‑correct sizing via `OrderCalcProfit` — **keep this exactly**, it fixed a ~100× lot bug
  (`RiskManager.mqh` → `LossPerLot` / `ValuePerLotPerPrice` / `LotForRisk`).
- The **poll‑the‑button** pattern for any on‑chart control in the tester (`BiasPanel.mqh`).
- `CVisuals` object helpers (`EnsureRect/Line/Segment/Arrow/Text`, prefix + wipe‑per‑session).
- `CDashboard` label grid.
- The analytics CSV design: buffer in memory, write once in `OnDeinit`, global `trade_no`
  counter, `Begin/Sample/Submit/Flush` shape (`TradeAnalytics.mqh`).
- `IsNewBar()`, "signals confirm on bar close, management every tick", `[SS]` journal +
  `Alert()` on every order path.

### A.4 Non‑obvious points from the spec to keep in mind

- **All detection is relative / ATR‑normalised.** No point/pip thresholds anywhere in
  quality, rejection, breakthrough, or reversal logic.
- **Anchor is locked at session open** and never repaints. Band logic is suppressed until
  `MinBarsSinceAnchor = 5`.
- **σ can be ≈ 0** early after the anchor — suppress zone/band logic until warm‑up.
- **Volume = tick volume** on gold → VWAP/σ are a broker proxy and will **not** match
  TradingView exactly. Backtest only on *Every tick based on real ticks*.
- **Two independent swing detectors:** classic **ZigZag** (anchor pivots only) and
  **fractals** (structure / BOS only). Different parameters, different jobs, never share code.
- Z2 `CONFIRMING` trigger **takes precedence over re‑zoning** until it resolves or times out
  (a bearish break down through +1σ is taken as a short even as price re‑enters the Z1 band).
- Per‑bar re‑evaluation of the whole zone/lean/trigger stack **until the first entry**, then
  the session direction is locked.

### A.5 Open questions to resolve during the build (from spec §18)

- **Broker DST calendar.** The spec assumes `BrokerDSTCalendar=US`. Confirm against the actual
  broker's server clock in Market Watch across a known DST weekend before trusting T0.
- **Momentum thresholds** (`BreakBodyATR`, `RevBodyATR`, `RevMinCounterMoveATR`),
  `ConfirmStateMaxBars`, and **flip sensitivity** are explicitly "tune during build" against
  labelled examples Ex1–Ex6 + the flip case.
- **Per‑session parameter sets.** The spec expects Asia and NY may need different params —
  keep every tunable session‑scoped‑capable from the start (or at least don't hard‑code).
- **Manual override panel?** v2 is fully mechanical. Decide whether to keep a small
  `BiasPanel`‑style debug override (force zone / force trigger) for testing only. Recommended:
  yes, gated behind an `InpDiag`/tester‑only flag, never a live control path.

---

## Part B — Architecture & the test‑harness method

### B.1 Folder layout

```
v2/
├── doc/
│   ├── Anchored_VWAP_Sessions_EA_Spec.md     # the contract (exists)
│   └── IMPLEMENTATION_PLAN.md                # this file
├── ref/
│   └── aVWAP.mq5                             # VWAP maths reference (exists)
├── Include/
│   ├── V2Common.mqh          # P0  enums, SSettingsV2, Diag structs, time helpers
│   ├── TimeSessions.mqh      # P0  UTC/DST/Riyadh, session windows + roles, gates
│   ├── AVWAP.mqh             # P1  anchored VWAP + σ bands (pure calc)
│   ├── ZigZag.mqh            # P2  classic ZigZag pivots  → anchor detector
│   ├── Fractals.mqh          # P2  fractal pivots + BOS   → structure detector
│   ├── SessionQuality.mqh    # P2  volatility / quality classifier (relative)
│   ├── AnchorSelect.mqh      # P2  quality + zigzag → chosen anchor bar
│   ├── Zones.mqh             # P3  Z1/Z2/Z3 classifier + Z2 CONFIRMING state
│   ├── RejectBreak.mqh       # P3  rejection / breakthrough primitives + provisional lean
│   ├── Triggers.mqh          # P3  BOS trigger + Reversal+Momentum trigger
│   ├── ZoneEngine.mqh        # P3  zone + lean + trigger + flip → {take?, dir, isFlip}
│   ├── RiskV2.mqh            # P4  SL / TP / R / sizing (RR=1.5)
│   ├── TradeManagerV2.mqh    # P4  one‑trade/session, 2‑try, direction lock, force‑close, spread
│   ├── VisualsV2.mqh         # shared drawing helpers (tests + EA)
│   ├── DashboardV2.mqh       # shared on‑chart status panel
│   └── AnalyticsV2.mqh       # P5  per‑trade CSV (zone, lean, trigger, flip, dir, tries, exit, R)
├── tests/
│   ├── T0_TimeSessions.mq5
│   ├── T1_AVWAP.mq5
│   ├── T2a_ZigZag.mq5
│   ├── T2b_Fractals_BOS.mq5
│   ├── T2c_SessionQuality.mq5
│   ├── T2d_AnchorSelect.mq5
│   ├── T3a_Zones.mq5
│   ├── T3b_RejectBreak.mq5
│   ├── T3c_Triggers.mq5
│   ├── T3d_ZoneEngine_Flip.mq5
│   └── T4_RiskAndManagement.mq5
├── tools/                     # operator utilities (not per-milestone tests)
│   └── SessionLabeler.mq5     # interactive GREEN/RED/SKIP session-quality labeller
├── ml/                        # OFFLINE calibration only - never a live/runtime model
│   ├── calibrate_quality.py   # correlations + gate grid-search + decision-tree cross-check
│   └── README.md
├── SessionsStrategyV2.mq5     # P5 integration EA
├── SessionsStrategyV2.ex5     # committed compiled binary (expect it in every diff)
└── compile.log
```

### B.2 Rules every module obeys

1. **Modules never place orders.** Only `TradeManagerV2.mqh` and `SessionsStrategyV2.mq5`
   touch `CTrade`. Everything else is detection / calculation (same rule as v1).
2. **Closed‑bar signals only** (`[1]` and older). No forming‑bar `iHighest`/`iLowest` in any
   signal path. Management/dashboard may read live price.
3. Each module exposes:
   - a normal getter API, and
   - a **`Diag` struct** (`SDiag<Module>`) that returns "everything this module can see right
     now" as plain fields, for the test EA and later the dashboard to render.
4. Each module `#include`s `V2Common.mqh` and, at most, the sibling modules it genuinely
   depends on (see the dependency graph in B.5). No module includes the main EA.
5. A new tunable = **four edits**: field in `SSettingsV2` (`V2Common.mqh`), `input` in the
   consumer, a line in `BuildSettingsV2()`, and a row in the parameter table in this file
   (later, the v2 README).
6. English everywhere. `[V2]` journal prefix. `Alert()` on every order open and every failure.

### B.3 The test‑EA pattern (`tests/Tn_*.mq5`)

Every test EA is the same shape:

```
inputs:   all of the module's own tunables, exposed 1:1
          + InpFromDate / InpToDate (documented window for this test)
          + InpVerbose (journal trace on/off)
          + InpStepMode (optional: only act on user "step" clicks, poll a button)

OnInit:   BuildSettingsV2(); module.Init(settings, _Symbol);
          visuals.Init(...); dash.Init(...);

OnTick:   newBar = IsNewBar();  if(!newBar) { dash.Update(); return; }
          module.OnNewBar(TimeCurrent());          // run the real module
          SDiag<Module> d = module.Diag();
          draw d on the chart (bands / dots / boxes / arrows / labels)
          dash.Update(d)                            // one block per field
          if(InpVerbose) Print("[T] ", d as one line)

OnDeinit: visuals.Destroy(); dash.Destroy(); (+ optional spot‑check CSV flush)
```

- Run each test in the Strategy Tester: **XAUUSD, M5, "Every tick based on real ticks",
  Visual mode ON**, over the window this document names for that test.
- The verification surface is your eyes on the chart + the dashboard block + the `[T]` trace,
  cross‑checked against a reference (built‑in indicator, `ref/aVWAP.mq5`, or a manual read).
- Optional per‑test **spot‑check CSV** in `Common\Files\` (one row per bar or per session) so
  numbers can be audited in Excel — measurement only, never gates anything.

### B.4 Compile & verify (unchanged from v1)

```powershell
& "C:\Program Files\MetaTrader 5\MetaEditor64.exe" /compile:"<abs>\v2\tests\T0_TimeSessions.mq5" /log:"<abs>\v2\compile.log"
```

- Exit code is the **file count, not an error count** — always read the log and check the
  `Result: N errors` line.
- Compile after **every** edit; the shipped `.set` caveat from v1's CLAUDE.md applies here too
  (MT5 reloads saved input values from `MQL5\Profiles\Tester\*.set|.ini` — to retire a feature,
  delete the input and its code path; to re‑tune a default, tell the user to reset that field).
- Commit `SessionsStrategyV2.ex5` (and test `.ex5` files if you want them versioned).

### B.5 Dependency graph / build order

```
P0  V2Common ─┬─────────────────────────────────────────────────────────────┐
              │                                                             │
P0  TimeSessions ──┬──> T2c SessionQuality ──┐                              │
                   │                         ├──> T2d AnchorSelect ──┐      │
P2  ZigZag ────────┼─────────────────────────┘                       │      │
P2  Fractals/BOS ──┼───────────────> T3c Triggers ───────────┐       │      │
                   │                                         │       │      │
P1  AVWAP ─────────┴───(anchor from T2d)──> T3a Zones ──> T3b RejectBreak ──┤
                                                            │               │
                                              T3d ZoneEngine (zone+lean+trigger+flip)
                                                            │
                                              P4 RiskV2 + TradeManagerV2
                                                            │
                                              P5 SessionsStrategyV2 + AnalyticsV2
```

Strict sequence: **P0 → P1 → (ZigZag, Fractals, SessionQuality in any order) → AnchorSelect →
Zones → RejectBreak → Triggers → ZoneEngine → Risk+Manager → Integration.**
Do not start a component until every component it depends on has passed its checklist.

---

## Part C — Component specs & visual tests

Legend: **Module** = the `.mqh` to write · **Test** = the `tests/Tn_*.mq5` · **See** = what to
draw · **Pass** = acceptance checklist (all must be true) · **Window** = suggested tester range.

---

### C0 — Time & Session Engine  ·  `TimeSessions.mqh`  ·  `T0_TimeSessions.mq5`

**Does:** broker→UTC offset (`BrokerToUTC_WinterOffsetHours=auto` + manual override),
DST handling (`BrokerObservesDST`, `BrokerDSTCalendar=US`) recomputed per bar; UTC↔Riyadh
(UTC+3, no DST); `CurrentSession(t)` returning `{session, role}` where role ∈
{`TRADE`, `ANCHOR_ONLY`, `OFF`} (Asia=TRADE+anchor, London=ANCHOR_ONLY, NY=TRADE+anchor);
`SessionStartServer/EndServer`, `InEntryWindow`, `NoNewEntryOffsetSec`,
`SessionForceCloseOffsetSec`, `SessionKey()`. `SessionTimeMode` FIXED_RIYADH / TRACK_MARKET.

**Diag:** broker time, resolved UTC, Riyadh time, DST state (winter/summer), offset applied,
current session + role, minutes to next open, minutes to force‑close, session key.

**See:**
- Session boxes (outline only): Asia blue, London green + `ANCHOR ONLY` tag, NY red, each
  labelled with role and Riyadh open/close.
- Vertical lines at every session open and close.
- Dashboard block with the full clock triple (broker / UTC / Riyadh) and DST state.

**Pass:**
- [ ] Asia box left edge sits exactly at 03:00 Riyadh, London 09:00, NY 15:00 — on **every**
      day in the window, including the DST‑change weekend.
- [ ] `Riyadh == broker + offset` shown in the dashboard matches a manual clock check.
- [ ] Role labels correct: London never shows `TRADE`.
- [ ] `minutes to force‑close` counts down to 0 at NY/Asia end; box right edge stops there.
- [ ] Nothing shifts by an hour on either side of the DST switch.

**Window:** a range that spans **both** a March and an October/November DST weekend
(e.g. 2024‑03‑01 → 2024‑11‑15), plus one plain week for the everyday check.

---

### C1 — Anchored VWAP + σ bands  ·  `AVWAP.mqh`  ·  `T1_AVWAP.mq5`

**Does:** running `Σv`, `Σv·p`, `Σv·p²` from a locked anchor bar; `VWAP = Σvp/Σv`;
`σ = sqrt(max(0, Σvp²/Σv − VWAP²))`; `U1=VWAP+σ`, `U2=VWAP+2σ`, `L1`, `L2`.
`PriceInput=HLC3`, `VolumeSource=TICK_VOLUME` (fallback to tick vol if real vol is all‑zero,
per `ref/aVWAP.mq5`). Anchor set once via `SetAnchor(barTime)` and **locked**. Band output
suppressed until `MinBarsSinceAnchor` (5) bars. Closed bars only — no repaint.

**Diag:** anchor bar time, bars since anchor, VWAP, σ, U1/U2/L1/L2, `d = price−vwap` in price
**and** in σ units, `suppressed?` flag.

**See:** 5 lines — VWAP (blue), U1/L1 (amber), U2/L2 (red) — drawn incrementally bar by bar.
Two anchor modes via input: **(a) manual** = a draggable `OBJ_VLINE` (mirror `ref/aVWAP.mq5`'s
`OnChartEvent` drag → recompute); **(b) session‑open** = auto‑anchor at each TRADE session open
(uses `TimeSessions`).

**Pass:**
- [ ] With mode (a) anchored to the same bar as `ref/aVWAP.mq5` loaded on the same chart, the
      VWAP lines **overlap** (small deviations from HLC3 vs the ref's choice are OK if you set
      the ref to HLC3 too).
- [ ] Bands are exactly symmetric about VWAP.
- [ ] σ starts ≈ 0, grows, then stabilises; no lines drawn before bar 5.
- [ ] Scrubbing the visual tester backward/forward does **not** move any already‑drawn segment
      (no repaint).
- [ ] Mode (b): a fresh anchor + fresh curve appears at each NY/Asia open; the old curve is
      cleared.

**Window:** 2–3 quiet days for the overlay check; then a week with mode (b).

---

### C2a — ZigZag pivots (anchor detector)  ·  `ZigZag.mqh`  ·  `T2a_ZigZag.mq5`

**Does:** classic MT5 ZigZag (`ZZ_Depth=24`, `ZZ_Deviation=5`, `ZZ_Backstep=2`) — either a
clean re‑implementation or a thin wrapper over `iCustom("Examples\\ZigZag", ...)`. Returns
**confirmed** pivots (time, price, HIGH/LOW) oldest→newest, plus
`LastSignificantPivotIn(t0, t1)` and per‑leg size.

**Diag:** last 5 confirmed pivots (time / price / type / leg size / leg size ÷ ATR), and the
current unconfirmed tail pivot (flagged separately).

**See:** the ZigZag polyline (segments between confirmed pivots) + a dot at each confirmed
pivot; the unconfirmed tail leg in a **dim** colour so the difference is obvious; label the
newest confirmed pivot `ANCHOR CANDIDATE`.

**Pass:**
- [ ] Polyline matches the built‑in `Examples\ZigZag` indicator loaded on the same chart.
- [ ] Confirmed pivots never move once a newer pivot forms; only the dim tail leg changes.
- [ ] `Depth`/`Deviation`/`Backstep` inputs visibly change pivot density.
- [ ] `LastSignificantPivotIn(sessionStart, sessionEnd)` (printed) points at a real swing
      extreme inside that window.

**Window:** one trending week + one choppy week (so you see dense vs sparse pivots).

---

### C2b — Fractal pivots + BOS (structure detector)  ·  `Fractals.mqh`  ·  `T2b_Fractals_BOS.mq5`

**Does:** fractal highs/lows with `BOS_SwingDepth=3` (N bars each side), **confirmed only after
the right‑side bars close**. Tracks the last confirmed swing high and low. **BOS** = a bar that
closes beyond the last confirmed swing in either direction (`BOS_ConfirmMode` CLOSE / WICK,
`BOS_BufferPoints=0`). Emits BOS events: `{direction, brokenLevel, brokenTime, legHigh,
legLow, legRange}`. Optional `BOS_UseZigZagForStructure` to source structure from `ZigZag`
instead. This module is **reused by `Triggers.mqh`** (Entry Type A).

**Diag:** last confirmed swing hi / lo, "next BOS level up / down", BOS count this session,
last BOS `{dir, brokenLevel, legRange, legRange÷ATR}`.

**See:** ▲ at each confirmed fractal high, ▼ at each confirmed fractal low. On a BOS: a short
ray at the broken level, an arrow at the break bar, shade the BOS leg, label `BOS↑` / `BOS↓`.

**Pass:**
- [ ] Every BOS mark sits on a bar that actually closed past a **previously drawn** swing
      level (rewind and confirm the level pre‑existed the break).
- [ ] No fractal dot appears until its right‑side bars have closed; dots never move afterward.
- [ ] No BOS without a preceding confirmed fractal.
- [ ] `WICK` vs `CLOSE` mode changes which bars qualify, as expected.

**Window:** 3–5 days with obvious structure breaks.

---

### C2c — Session‑Quality / Volatility classifier  ·  `SessionQuality.mqh`  ·  `T2c_SessionQuality.mq5`

> This is the "unit test I can watch with my eyes" you described: classify each finished
> session as **volatile / trending (QUALITY)** vs **flat / choppy (FLAT)** and colour it.

**Does:** for a **completed** session (Asia / London / NY):
- `range` = session high − session low
- `atr` = ATR(`AtrPeriod=14`) sampled at/near session start
- `baseline` = rolling **median** `range` of the last `QualityBaselineN=20` **same‑type**
  sessions (Asia baseline from Asia sessions only, etc.)
- `largestLeg` = biggest ZigZag leg fully inside the session (from `ZigZag.mqh`)
- `efficiency` = Kaufman Efficiency Ratio over the session (`|close−open| / Σ|barᵢ−barᵢ₋₁|`)
- optional `displacement` ratio and `pivotCount`
- ratios: `range/baseline` (≥ `MinRangeRatio=0.80`), `range/atr` (≥ `MinRangeATR=3.0`),
  `largestLeg/atr` (≥ `MinLegATR=1.5`) or `largestLeg/baseline` (≥ `MinLegRatio=0.5`),
  `efficiency` (≥ `MinEfficiency=0.30`)
- `SessionQualityMode`:
  - **`GATES`** — pass iff every enabled threshold passes.
  - **`SCORE`** (default) — weighted sum: `leg .35 + eff .30 + range/base .20 + range/atr .15`
    (each term normalised to [0,1] against its threshold), pass ≥ `QualityScoreThreshold=0.6`.

**Diag:** for the most‑recent completed session and the last ~10: `{session, date, range, atr,
baseline, largestLeg, efficiency, each ratio, score, PASS/FAIL}`.

**See:**
- For **every completed session** in the range, redraw its box **green (QUALITY)** or
  **red (FLAT)**, with a multi‑line label:
  `NY 2024‑06‑03  SCORE 0.71 PASS | rng/base 0.92  rng/atr 3.4  leg/atr 1.8  eff 0.34`
- A side panel listing the last 10 sessions + verdicts + scores.
- **Spot‑check CSV** (`SessionsStrategyV2_Quality_<symbol>.csv`): one row per session with
  every raw metric and ratio — so you can sort in Excel and confirm the threshold split.

**Pass:**
- [ ] Sessions that look clearly **trending / wide‑range** by eye come out **green**.
- [ ] Sessions that look clearly **choppy / tight** come out **red**.
- [ ] Borderline sessions have `SCORE` near 0.6 (not wildly off).
- [ ] Baseline uses same‑type sessions only (Asia baseline ignores NY, etc.) — verify one by
      hand from the CSV.
- [ ] Toggling `GATES`↔`SCORE` and nudging a threshold/weight recolours the boxes the way you
      expect on the next run.
- [ ] Nothing is classified until the session is **complete** (no mid‑session recolour).

**Window:** ≥ 6 weeks (need ≥ 20 prior same‑type sessions for the baseline to warm up before
verdicts mean anything — the first ~4 weeks are warm‑up).

---

### C2d — Anchor selection  ·  `AnchorSelect.mqh`  ·  `T2d_AnchorSelect.mq5`

**Does:** at a TRADE session open — walk backward over prior sessions within
`MaxAnchorLookbackHours=48`; take the **first** whose `SessionQuality` passes; from it, take
its **most recent significant ZigZag pivot** within `±AnchorFlexMinutes=60` of the session
edge; return that bar time as the anchor. If none qualifies → `NoAnchorAction=SKIP_SESSION`.

**Diag:** list of candidate sessions scanned (type, date, pass/fail), the chosen session, the
chosen pivot `{time, price}`, hours back, and the `SKIP` flag.

**See:** at each TRADE session open — a marker on the chosen anchor bar, a ray from the anchor
to the session open, label `ANCHOR ← NY 06‑03 pivot 2358.4 (37h back)`. If skipped, label the
session `NO ANCHOR → SKIP`.

**Pass:**
- [ ] The anchor bar is always a real swing extreme (cross‑check against `T2a`'s pivots).
- [ ] The anchor's session was **green** in `T2c` — never anchors inside a red session.
- [ ] Never reaches back more than 48h; if the only green session is older, it `SKIP`s.
- [ ] The chosen pivot is the **most recent** significant one in that session, not an older one.

**Window:** same 6+ weeks as C2c (it consumes C2c's output).

---

### C3a — Zone classifier  ·  `Zones.mqh`  ·  `T3a_Zones.mq5`

**Does:** given VWAP + σ + bands (from `AVWAP.mqh`, anchored via `AnchorSelect`): `d = price −
vwap`; classify **Z1** `|d|<1σ`, **Z2** `1σ≤|d|<2σ`, **Z3** `|d|≥2σ`; sign of `d` gives the
committed (Z1) / reversion (Z3) direction. Z2 `CONFIRMING` state machine: enter on crossing
into Z2, hold ≤ `ConfirmStateMaxBars=12` bars, exit on leaving the zone / session end / a
trigger firing. Suppressed while `AVWAP` is still in warm‑up or σ≈0.

**Diag:** `d` in price and σ units, current zone, committed direction (Z1/Z3), Z2 state +
bars‑in‑state, suppressed flag.

**See:** a thin coloured strip along the bottom of the chart, one cell per bar: Z1 grey, Z2
amber, Z3 red — drawn **under** the C1 bands so price, bands and zone are visible together.
Dashboard: `d = +1.34σ   ZONE Z2 (CONFIRMING 4/12)   stance: contested`.

**Pass:**
- [ ] The zone label flips **exactly** when price closes across a drawn band, not before/after.
- [ ] Z1 shows a committed direction that matches the sign of `d`.
- [ ] Z3 shows the **reversion** direction (above +2σ → short).
- [ ] Z2 `CONFIRMING` counter increments once per bar and resets on zone exit or at 12.
- [ ] Strip is blank during `AVWAP` warm‑up.

**Window:** 1–2 weeks that include at least one clear excursion beyond ±2σ.

---

### C3b — Rejection / breakthrough primitives + provisional lean  ·  `RejectBreak.mqh`  ·  `T3b_RejectBreak.mq5`

**Does:** the four primitives from spec §9.1 on closed bars, all σ/ATR‑relative:
`rejectionAsSupport(bar,B)`, `rejectionAsResistance(bar,B)`, `breakUp(bar,B)`,
`breakDown(bar,B)` with `TouchTolSigma=0.10`, `RejectCloseSigma=0.05`, `RejectRequireWick=true`,
`RejectWickMinFrac=0.5`, `BreakBufferSigma=0.15`, `BreakRequireMomentum=true`,
`BreakBodyATR=0.8`. From these, produce the **provisional lean** for Z2 (per spec §8‑Z2:
holding +1σ → lean long; breakdown through +1σ → lean short; break through +2σ → transition to
Extended) and the ±2σ→Extended transition flag. **The lean is informational only.**

**Diag:** which primitive fired on the last bar and at which band, the current lean
(LONG / SHORT / none), bars the lean has been held, Extended‑transition flag.

**See:** mark each firing bar at the relevant band — ⬆ green `rejSup@+1`, ⬇ red `rejRes@−1`,
`brkUp@+1`, `brkDn@+1`. Dashboard shows the current lean and its source primitive.

**Pass:**
- [ ] A `rejSup@+1` mark only on a candle that visibly wicks the +1σ band and closes back
      above it with a lower wick ≥ 50 % of range.
- [ ] A `brkUp@+1` mark only on a momentum close beyond the band by ≥ `BreakBufferSigma·σ`
      with body ≥ `BreakBodyATR·ATR`.
- [ ] Lean text always matches the most recent qualifying primitive.
- [ ] A close through +2σ flips the Extended‑transition flag on.

**Window:** 1–2 weeks with several band tests (reuse the C3a window).

---

### C3c — Triggers: BOS + Reversal+Momentum  ·  `Triggers.mqh`  ·  `T3c_Triggers.mq5`

**Does:**
- **Entry Type A — BOS:** delegate to `Fractals.mqh` — break of the latest confirmed swing in
  a queried direction; `EntryFillMode` BOS_CLOSE / NEXT_OPEN; report `{entryPrice,
  protectedExtreme=legLow(long)/legHigh(short), legRange}`.
- **Entry Type B — Reversal + Momentum** (spec §9.3), per queried direction, closed bars:
  1. sharp counter‑move within `RevCounterLookback=8` bars, size ≥ `RevMinCounterMoveATR·ATR`
     (0.8), ending at a local extreme `revLow`/`revHigh`;
  2. momentum reversal candle: body ≥ `RevBodyATR·ATR` (1.0), close in the top
     `RevCloseLocPct` (0.33) of its range; optional `RevRequireEngulf` or "close breaks last
     `RevBreakBars=2` highs/lows";
  3. `RevConfirmCloses=1` confirming close; `revLow`/`revHigh` must hold.
     Report `{entryPrice, protectedExtreme=revLow/revHigh, legRange}`.
- `EntryMode` BOS_ONLY / REVERSAL_ONLY / BOTH. Query is **direction‑scoped** (the caller asks
  "is there a long trigger this bar?" / "a short trigger?").

**Diag:** last trigger `{type, direction, entryPrice, protectedExtreme, legRange, legRange÷ATR}`,
count this session, "no trigger yet".

**See:** on every detected trigger (either type, both directions): an entry arrow, the
protected extreme as a dashed line, a `BOS↑` / `REV↑` label, shade the leg.

**Pass:**
- [ ] BOS triggers coincide 1:1 with `T2b`'s BOS marks.
- [ ] Reversal marks sit on visually sharp *counter‑then‑reverse* candles, not on trend
      continuation.
- [ ] The protected extreme is the true local extreme of the triggering move.
- [ ] `EntryMode` filters the trigger stream as expected.
- [ ] No trigger from a forming bar (step forward — marks never appear then move).

**Window:** 3–5 days with a mix of clean breaks and sharp reversals.

---

### C3d — Zone engine + Z2 flip (decision resolver)  ·  `ZoneEngine.mqh`  ·  `T3d_ZoneEngine_Flip.mq5`

**Does:** the per‑bar decision from spec §14, given the current zone (`Zones`), lean
(`RejectBreak`), and the first trigger this bar (`Triggers`):
- **Z1:** hunt the committed direction only (unless `AllowFlipInDirectZone`); take if a trigger
  in that direction fired.
- **Z3:** hunt the reversion direction only (unless `AllowFlipInExtendedZone`).
- **Z2:** hunt **both** directions; the **first** valid trigger's direction is the trade
  direction; `isFlip = (triggerDir != lean)`. `CONFIRMING` trigger takes precedence over
  re‑zoning until it resolves or times out.
- Output: `{take?, direction, isFlip, zone, lean, triggerType, reason}` — **no orders**, just
  the decision + a rich human‑readable reason string.

**Diag:** last decision struct, flip count, decisions broken down by zone.

**See:** on a `take` decision — a large arrow at the bar, label
`TAKE LONG · Z2 · trigger BOS↑ · lean SHORT · FLIP`, plus **preview‑only** entry / SL / TP
lines (call `RiskV2` in a dry mode — no order).

**Pass — acceptance scenarios (spec §17.1), reproduce each on a chosen historical date:**
- [ ] **Ex1** short / trend (Z1, d<0).
- [ ] **Ex2** long / trend (Z1, d>0).
- [ ] **Ex3** short beyond +2σ (Z3 reversion).
- [ ] **Ex4** long beyond −2σ (Z3 reversion).
- [ ] **Ex5** lower‑band momentum break → long.
- [ ] **Ex6** +1σ rejection → long.
- [ ] Reversal+Momentum long in Z1 (the "attached chart" case).
- [ ] **Z2 flip:** lean long after a +1σ rejection, then a bearish BOS → engine takes the
      **short** and sets `isFlip=true`.
- [ ] Every `take` is fully explainable from the drawn bands + zone + trigger.
- [ ] No `take` in Z1/Z3 against the committed direction (with flips off).

**Window:** hand‑pick the dates for Ex1–Ex6 + flip from the spec's chart references; run each
as a narrow 1–2 day visual pass.

---

### C4 — Risk / SL / TP / sizing + Trade & session management  ·  `RiskV2.mqh` + `TradeManagerV2.mqh`  ·  `T4_RiskAndManagement.mq5`

**`RiskV2.mqh` does:** `SL = protectedExtreme ± buffer`, `SL_BufferMode` PCT_OF_LEG
(0.10×`legRange`) / ATR (`SL_BufferATRmult`) / POINTS; clamp to broker `STOPS_LEVEL`
(`ClampStopsToBroker=true`); `MinStopATRmult` floor; `R = |entry−SL|`; `TP = entry ± RR·R`
(`RR=1.5`); lots from `RiskMode` PERCENT (`RiskPercent=0.5`, via **v1's `OrderCalcProfit`
sizing — copy `LossPerLot`/`LotForRisk` verbatim**) or FIXED_LOT. Rejects (lots→0) rather than
over‑risking. `PriceForR()` preview helper for T3d.

**`TradeManagerV2.mqh` does:** one position per `MagicNumber`; one trade per session;
`MaxTriesPerSession=2`; `SecondTryOnlyAfterSL=true` (2nd attempt only if the 1st stopped out);
**direction lock** — the first fill sets `sessionDirection`, immutable that session;
`AllowReentryAfterWin=false` (a win closes the session); force‑flat at
`SessionForceCloseOffsetSec` before session end (`CloseOnSessionEnd=true`); `MaxSpreadPoints=50`
guard at entry; `MaxSlippagePoints=20`. Optional loss caps (off by default). Emits `[V2]`
journal lines + `Alert()` on every open / fail / close (mirror v1's set:
`PLACED` / `OPENED` / `FAILED: retcode` / `CLOSED` / `SKIPPED`), and the terminal‑is‑the‑witness
recovery from v1 (`FindOwnRecentPosition` — a false `OrderSend` return with a live position must
still be adopted).

**Test harness:** this layer **does** place orders, so isolate it from P3 with a **stubbed
trigger source**: `InpForceTrigger = LONG / SHORT / OFF` + `InpTriggerEveryNBars` synthesises
triggers on a fixed cadence with a synthetic protected extreme (e.g. last N‑bar low), OR feed
T3d's decisions directly via an input switch.

**See:** entry / SL / TP rays, a `DIR LOCK: LONG` badge, `try 1/2`, a force‑close marker at
session end, spread‑reject marks.

**Pass:**
- [ ] Never more than one position open at a time.
- [ ] 2nd try appears **only** after the 1st trade closed at SL; never after a win, never a 3rd.
- [ ] After the first fill, a synthesised opposite trigger is **ignored** (direction locked).
- [ ] Every position is flat by the session force‑close time.
- [ ] Hand‑check: `R × lots ≈ RiskPercent × balance` at entry (print both).
- [ ] `TP` distance = `1.5 × SL` distance from entry.
- [ ] Entry rejected + logged when spread > `MaxSpreadPoints`.
- [ ] SL clamped up to `STOPS_LEVEL` when the raw extreme is too close.

**Window:** 1–2 weeks, both sessions enabled, visual mode.

---

## Part D — Integration (P5)

### D1 — `SessionsStrategyV2.mq5`

Wire P0→P4 into one `OnTick`, following spec §14:

```
OnTick:
  newBar = IsNewBar()
  time.Recompute(now)                      # broker→UTC, DST per bar
  {ses, role} = time.CurrentSession(now)
  if role != TRADE:
      manager.HandleForceCloseIfNeeded(); dash.Update(); return
  if time.IsSessionOpenBar(ses):
      anchor = anchorSelect.Pick(now)      # quality + zigzag, ≤48h
      if anchor == NONE: mark SKIP; return
      avwap.SetAnchor(anchor); manager.ResetSession()   # tries=0, dir=NONE, confirm=idle
  avwap.OnNewBar(now)
  if avwap.Suppressed(): dash.Update(); return

  if newBar and time.WithinEntryWindow(now) and manager.CanAttempt():
      decision = zoneEngine.Evaluate(now)  # zone + lean + trigger + flip
      if decision.take:
          if manager.DirectionLocked() and decision.direction != manager.LockedDir():
              skip (locked)
          else:
              risk = riskV2.Build(decision)      # SL/TP/lots
              manager.Open(decision.direction, risk, decision)   # the only order path
  manager.ManageOpen(now)                  # force-close window, spread, exits are broker SL/TP
  analytics.Sample(now)
  if newBar: draw all InpDiag* overlays; dash.Update()
```

All the C0–C4 test overlays become optional `InpDiag<Component>` toggles that reuse
`VisualsV2` / `DashboardV2`. Default them **off** for clean runs, on for debugging.

### D2 — `AnalyticsV2.mqh` (P5)

One CSV row per closed trade — reuse v1's buffer‑and‑flush‑in‑`OnDeinit` design and the global
`trade_no` counter. v2‑specific columns: `anchor_session`, `anchor_pivot_px`, `anchor_hours_back`,
`session_quality_score`, `zone_at_entry`, `lean_at_entry`, `trigger_type`, `is_flip`,
`confirm_bars`, `direction`, `try_number`, `entry`, `sl`, `tp`, `R_money`, `rr_planned`,
`exit_reason` (TP / SL / FORCE_CLOSE / END_OF_TEST), `net_r`, `net_pct_balance`,
`mae_r` / `mfe_r` (folded from completed‑bar highs/lows — model‑independent, as in v1).
Measurement only — never gates a decision. Skip during optimization passes.

**Advanced columns (2026‑09‑15, user request — deep‑dive analysis needed more context per
trade):** `dsigma_entry` (signed `|price‑vwap|/sigma` at the trigger bar — finer‑grained than
`zone_at_entry`'s 3‑bucket split, for threshold tuning), `atr_entry` / `sl_atr_ratio` (stop width
relative to volatility — is a wide stop actually worse?), `spread_entry_pts` (execution‑cost
context), `entry_mins_since_open` (for `EntryWindowMinutes` tuning), `regime_at_entry`
(`CONTINUATION`/`REVERSAL`/`CONFIRMATION`/`NOT_CAPTURED` — the session‑OPEN regime lock; can
differ from `zone_at_entry`, which is the LIVE zone at the trigger bar, since price can drift
zones after the regime locks), `confirm_armed_at_entry` (CONFIRMATION regime only), `be_applied`
(did `ManageBreakEven()` fire on this trade), `bars_held` (base‑TF bar count open→close),
`mfe_bar` / `mae_bar` (bars‑from‑open at which the best/worst excursion was LAST set — lets a
post‑hoc analysis re‑simulate an alternate RR/TP target from one dataset: `mfe_bar < mae_bar`
means the favorable excursion happened first).

### D3 — Integration test stages

| Stage | Config | What you verify |
|---|---|---|
| **I1 — dry run** | `InpExecute=false`, all `InpDiag*` on, visual, 1 week | anchor + zone + lean + trigger still all look right **in combination**; no exceptions; dashboard coherent bar‑to‑bar |
| **I2 — one session, execute** | NY only, `InpExecute=true`, visual, 1–2 weeks | walk **every** trade: the chart story (bands → zone → trigger → flip?) matches `decision.reason` and the CSV row; SL/TP/lots correct; direction lock + 2‑try + force‑close all hold |
| **I3 — full range** | Asia + NY, visual **off**, *Every tick real ticks*, 2–3 years | collect the CSV; pivot by **zone / trigger‑type / flip vs non‑flip / session**; expectancy (R), win rate, frequency, PF, max DD; check signs/magnitudes against spec §17.4 expectations |
| **I4 — robustness** | per spec §17.5 | Asia vs NY split (likely separate param sets); walk‑forward / OOS; parameter sensitivity on the tuned momentum thresholds; broker‑to‑broker check (DST calendar!) |

### D4 — Integration acceptance

- [ ] Every acceptance scenario Ex1–Ex6 + the Z2 flip (from C3d) still fires correctly inside
      the full EA, not just the isolated test.
- [ ] No look‑ahead: re‑run I2 with *Open prices only* vs *Every tick* — **entries** are
      essentially identical (they confirm on bar close). Document any exit drift.
- [ ] CSV totals reconcile with the tester's own report (trade count, net profit sign).
- [ ] A full run produces zero `UNKNOWN` exit reasons and zero unmanaged positions.

---

## Part E — Milestone checklist

| # | Deliverable | Depends on | Done |
|---|---|---|---|
| 0 | `V2Common.mqh` — enums, `SSettingsV2`, `BuildSettingsV2`, time helpers, `Diag` structs | — | ☐ |
| 0 | `VisualsV2.mqh` + `DashboardV2.mqh` (ported/trimmed from v1) | 0 | ☐ |
| 1 | `TimeSessions.mqh` + `T0` passes checklist | 0 | ☐ |
| 2 | `AVWAP.mqh` + `T1` passes (overlay vs `ref/aVWAP.mq5`) | 0 | ☐ |
| 3 | `ZigZag.mqh` + `T2a` passes | 0 | ☐ |
| 4 | `Fractals.mqh` + `T2b` passes | 0 | ☐ |
| 5 | `SessionQuality.mqh` + `T2c` passes (eyeball green/red split) | 1,3 | ☑ (calibrated vs 520 real labels) |
| 6 | `AnchorSelect.mqh` + `T2d` passes | 2,3,5 | code complete, compiles 0/0 — awaiting your visual verification |
| 7 | `Zones.mqh` + `T3a` passes | 2,6 | code complete, compiles 0/0 — awaiting your visual verification |
| 8 | `RejectBreak.mqh` + `T3b` passes | 2,7 | code complete, compiles 0/0 — awaiting your visual verification |
| 9 | `Triggers.mqh` + `T3c` passes | 4 | ☑ verified 2026-09-14 |
| 10 | `ZoneEngine.mqh` + `T3d` passes (Ex1–Ex6 + flip) | 7,8,9 | code complete, compiles 0/0 — awaiting your visual verification |
| 11 | `RiskV2.mqh` + `TradeManagerV2.mqh` + `T4` passes | 0,10 | code complete, compiles 0/0 — awaiting your visual verification |
| 12 | `SessionsStrategyV2.mq5` + `AnalyticsV2.mqh` — I1 dry run clean | all | code complete, compiles 0/0 — awaiting I1 dry-run verification |
| 13 | I2 one‑session execute — every trade explained | 12 | ☐ |
| 14 | I3 full range — expectancy table by zone/trigger/flip/session | 13 | ☐ |
| 15 | I4 robustness — WFO / OOS / sensitivity / broker check | 14 | ☐ |
| 16 | v2 README (design spec + input table + install/backtest guide) | 14 | ☐ |

**Rule:** a milestone is "done" only when its test EA compiles `0 errors` **and** you have
ticked every box in that component's Pass checklist in the visual tester.

---

## Part F — Parameter reference (from spec §13, tracked here until the v2 README exists)

Keep this table in sync — every new `input` adds a row (see B.2 rule 5). Grouped as the spec groups them.

| Group | Input | Default |
|---|---|---|
| General | `MagicNumber`, `BaseTF` | —, M5 |
| General | `VolumeSource`, `MaxSpreadPoints`, `MaxSlippagePoints` | TICK_VOLUME, 50, 20 |
| Time | `SessionTimeMode` | FIXED_RIYADH |
| Time | `BrokerToUTC_WinterOffsetHours`, `BrokerObservesDST`, `BrokerDSTCalendar` | auto, true, US |
| Time | Asia / London / NY enable+role+hours | T/T·03–06, T/F·09–12, T/T·15–18 |
| Time | `AnchorFlexMinutes`, `MaxAnchorLookbackHours`, `AnchorPreRollMinutes` | 120, 48, 30 |
| Time | `EntryWindowMinutes` (2026-09-15) | 30 |
| Time | `NoNewEntryOffsetSec`, `SessionForceCloseOffsetSec`, `CloseOnSessionEnd` | 0, 0, true |
| AVWAP | `PriceInput`, `Band1Multiplier`, `Band2Multiplier`, `MinBarsSinceAnchor` | HLC3, 1.0, 2.0, 5 |
| ZigZag | `ZZ_Depth`, `ZZ_Deviation`, `ZZ_Backstep` | 24, 5, 2 |
| Quality | `SessionQualityMode`, `QualityScoreThreshold`, `QualityBaselineN`, `AtrPeriod` | SCORE, 0.6, 20, 14 |
| Quality | `MinRangeRatio`, `MinRangeATR`, `MinLegATR`, `MinEfficiency` | 0.70, 10.0, 6.0, 0.15 |
| Quality | `MinRangeRatio` is CONFIRM-only (applies when a baseline exists, never blocks a verdict) - `MinLegRatio` removed 2026-09-14, an uncalibrated OR-clause that cost 0.106 MCC on real data | — |
| Quality | `UseDisplacement`, `MinDisplacementRatio`, `UsePivotCount`, `MaxPivotCount`, `NoAnchorAction` | F, 0.35, F, 8, SKIP_SESSION |
| Zones | `ConfirmStateMaxBars` (implemented, `Zones.mqh`) | 12 |
| Zones | `ConfirmZoneFollowStructure` — not yet consumed; the CONFIRMING exit conditions it would gate (zone-leave/session-end/trigger-firing) belong to ZoneEngine (C3d), not the pure `Zones.mqh` classifier | true |
| Zones | `AllowFlipInDirectZone`, `AllowFlipInExtendedZone` | false, false |
| Reject/Break | `TouchTolSigma`, `RejectCloseSigma`, `RejectRequireWick`, `RejectWickMinFrac` | 0.10, 0.05, true, 0.5 |
| Reject/Break | `BreakBufferSigma`, `BreakRequireMomentum`, `BreakBodyATR` | 0.15, true, 0.8 |
| Entries | `EntryMode` | BOTH |
| Entries·BOS | `BOS_UseZigZagForStructure`, `BOS_SwingDepth`, `BOS_ConfirmMode`, `BOS_BufferPoints`, `EntryFillMode` | false, 3, CLOSE, 0, BOS_CLOSE |
| Entries·Reversal | `RevCounterLookback`, `RevMinCounterMoveATR`, `RevBodyATR`, `RevCloseLocPct`, `RevRequireEngulf`, `RevBreakBars`, `RevConfirmCloses` | 8, 0.8, 1.0, 0.33, false, 2, 1 |
| Risk/Exit | `RR`, `SL_BufferMode`, `SL_BufferPct`, `SL_BufferATRmult`, `SL_BufferPoints` | 1.5, PCT_OF_LEG, 0.10, 0, 0 |
| Risk/Exit | `MinStopATRmult`, `ClampStopsToBroker`, `RiskMode`, `RiskPercent`, `FixedLot` | 0, true, PERCENT, 0.5, 0.01 |
| Mgmt | `MaxTriesPerSession`, `SecondTryOnlyAfterSL`, `AllowReentryAfterWin`, `UseNewsFilter` | 2, true, false, false |
| Diag | `DrawObjects`, `VerboseLog`, `ExportTradeCSV` + per‑component `InpDiag*` | true, true, true |

---

## Part G — What to reuse from v1 verbatim (copy, then adapt)

| v1 file | Reuse in v2 | Notes |
|---|---|---|
| `Common.mqh` | `ToRiyadh`/`FromRiyadh`/`RiyadhMinuteOfDay`/`ParseHM`/`DayOfWeekName`, enum style, `SSettings` pattern | v2 time layer adds UTC + DST on top |
| `RiskManager.mqh` | `ValuePerLotPerPrice`, `LossPerLot`, `LotForRisk`, `PriceForMoney` | **do not** re‑derive with tickValue/tickSize — the `OrderCalcProfit` path fixed a 100× bug (`87807eb`) |
| `SessionManager.mqh` | `SessionKey()`, `SessionStartServer`, `StartMinOf/EndMinOf` routing pattern | drop the 4H‑range code (v2 has no rule 2) |
| `BiasPanel.mqh` | the **poll‑don't‑event** pattern for any tester‑side control | v2 uses it only for optional diag overrides |
| `Visuals.mqh` | all `Ensure*` primitives, `VIS_PREFIX`, `ClearSessionDrawings` | add band/zone/quality‑box helpers |
| `Dashboard.mqh` | the `Label(row,...)` grid | widen; one block per Diag struct |
| `TradeAnalytics.mqh` | `Begin/Sample/Submit/Flush`, buffer‑write‑once, global `trade_no`, bar‑folded MAE/MFE | swap the column set for v2's |
| `SessionsStrategy.mq5` | `IsNewBar`, `OnPositionOpened` bookkeeping, `FindOwnRecentPosition` recovery, `[SS]`+`Alert` discipline, `OnDeinit` flush order | rename prefix `[V2]` |

---

## Part H — Build log

| Date | Milestone | State |
|---|---|---|
| 2026-09-09 | **0** — `V2Common.mqh`, `VisualsV2.mqh`, `DashboardV2.mqh` | code complete, compiles 0/0 |
| 2026-09-09 | **1** — `TimeSessions.mqh` + `tests/T0_TimeSessions.mq5` | code complete, compiles 0/0 — awaiting your visual verification (C0 checklist) |
| 2026-09-09 | **2** — `AVWAP.mqh` + `tests/T1_AVWAP.mq5` | code complete, compiles 0/0 — awaiting your visual verification (C1 checklist) |
| 2026-09-09 | fix (T0 v1 feedback) | session boxes now hug the session high/low (were full-chart-height with edge lines → looked like verticals); the clock input is now **`ServerToRiyadhOffsetHr`** (hours to add to the server clock to get Riyadh; **default 0** = server already shows Riyadh time) with a separate `ServerObservesDST` toggle. The engine still works in UTC internally: `brokerWinterOffsetHr = 3 − ServerToRiyadhOffsetHr`. |
| 2026-09-09 | **T0, T1 verified visually by the user.** Milestones 1 & 2 pass. (VWAP shows a small bounded offset vs TradingView COMEX GC — expected: different instrument + tick-volume proxy, per spec §3/§5; T1 matched `ref/aVWAP.mq5` on the same feed, which is the real check.) |
| 2026-09-09 | **3** — `ZigZag.mqh` + `tests/T2a_ZigZag.mq5` | verified visually by the user. Milestone 3 passes. (Needs the stock `Examples\ZigZag` indicator compiled in the terminal.) |
| 2026-09-10 | **4** — `Fractals.mqh` + `tests/T2b_Fractals_BOS.mq5` | code complete, compiles 0/0, `.ex5` 18:36 — awaiting your visual verification (C2b checklist). |
| 2026-09-10 | **5** — `SessionQuality.mqh` + `tests/T2c_SessionQuality.mq5` | code complete, compiles 0/0, `.ex5` 18:37 — awaiting your visual verification (C2c checklist). Writes `Common\Files\SessionsStrategyV2_Quality_<sym>.csv`. Run ≥ 6 weeks (first ~4 = baseline warm-up). |
| 2026-09-10 | toolchain note | Git-Bash CLI compile only works as: fire `cmd //c start "" MetaEditor64.exe /compile:... /log:compile.log` in one call, verify `.ex5` mtime + `Result` line in the next. One file per pair. See memory `trading-ea-build-conventions`. |
| 2026-09-10 | **T2b verified** by the user. Milestone 4 passes. |
| 2026-09-10 | **T2c recalibration #1** (user feedback: 5 "should be green" mislabelled). Root causes: (a) `leg/atr` was always 0.0 — the ZigZag `LargestLegIn` never finds a confirmed leg inside a ~36-bar session; (b) Kaufman efficiency was co-equal weight and kills V-reversal sessions the strategy actually wants. Fixes: `largestLeg` is now the largest sustained one-directional excursion computed in-session (no ZigZag dep — T2c no longer includes `ZigZag.mqh` or needs `Examples\ZigZag`); default mode = **GATES**: `pass = rng/base ≥ 1.05 AND (rng/atr ≥ 8 OR leg/atr ≥ 2.5 OR leg/base ≥ 0.9)`; efficiency exported only. SCORE mode re-weighted (rng/base .45, leg .25, rng/atr .20, eff .10; minEff .15). Against the 8 labelled screenshots this classifies 7 cleanly; img3 (ASIA 09-07, label cut off) is the edge case — if it's wrongly red, drop `MinRangeRatio` toward 1.00. `.ex5` 19:37 — re-run T2c and re-tune from the CSV. |
| 2026-09-13 | **ML/RL discussion + T2c recalibration #2** (user reported: recalibration #1 now lets choppy sessions PASS). Diagnosis: `MinRangeRatio 1.05` is barely above the median, and the movement OR-clause (`rng/atr≥8 OR leg/atr≥2.5`) is satisfiable by ONE outlier bar in an otherwise dead session. Discussed RL (wrong problem shape, no sequential decision here — rejected), live supervised ML (v1/ml/ already tried LightGBM on this codebase, came back negative per `b145f7e`, and a trained model would break the project's visual-transparency goal — rejected for the live path), landed on: (1) add a 3rd GATES clause `impulseBarCount ≥ minImpulseBars` (bars whose own range ≥ `impulseBarAtrMult`×ATR, default 0.8/2) so one spike bar can no longer carry a choppy session through the movement gate; (2) added `v2/ml/calibrate_quality.py` — an OFFLINE, non-live calibration tool: reads T2c's CSV + a hand-labelled file, reports metric correlations, a grid search over the same gate shape (ranked by precision/recall/F1), and an optional depth-3 decision tree as a cross-check, so threshold tuning is done against real labelled data instead of guesswork. `SessionQuality.mqh`/T2c `.ex5` 19:52 — re-run T2c, and once you have enough labelled sessions run the calibration script to nail the final thresholds. |
| 2026-09-13 | **SessionLabeler rewrite — Sleep()-blocking the tester does NOT work.** First cut tried to pause the Strategy Tester by blocking `OnTick` in a `Sleep()`+button-poll loop; user confirmed (twice, after a config-default fix that also wasn't the real cause) the tester's simulated clock keeps advancing regardless — that mechanism is dead, not tunable. **Rewritten to run on a normal chart instead of the tester**: `OnInit` scans the *whole loaded history in one pass* (walking `CopyRates` chronologically, calling `CSessionQuality::EvaluateCompleted` per session exactly as before so the baseline rings fill correctly) and builds a review queue; then it shows one session at a time (scrolls the chart to it via `CHART_FIRST_VISIBLE_BAR`, draws its box+metrics) and waits — via ordinary `OnChartEvent(CHARTEVENT_OBJECT_CLICK)`, which fires normally and immediately on a live/offline chart (unlike inside the tester). Click GREEN/RED/SKIP → CSV row written (or skipped) → chart scrolls to the next session. No blocking loop anywhere. Must be attached to a live/demo/offline chart with the desired history already loaded, NOT run inside the Strategy Tester. Compiles 0/0, `.ex5` 20:39 verified newer than sources. |
| 2026-09-13 | **Chart-nav fix.** User reported the chart stayed at "now" instead of scrolling to the session awaiting a label. Cause: `CHART_FIRST_VISIBLE_BAR` was set before `CHART_AUTOSCROLL` was turned off, so the terminal's own live-edge-follow snapped it back. Fixed order (autoscroll off first, in `OnInit` before anything else touches the chart), added a readback+log so a future regression is provable, and added a short `OnTimer` burst (6× over ~1.8s) that re-asserts the scroll position after showing each session, since the terminal can also reset the view once, asynchronously, right after attach. `.ex5` 20:48 verified newer than sources. |
| 2026-09-13 | **Centering fix.** User wanted the pending session CENTERED, not just scrolled into view near the right edge with a margin. `ApplyChartNav` now computes the session's middle bar (`(openShift+closeShift)/2`) and reads `CHART_VISIBLE_BARS` to place that midpoint at half the viewport width in from the right edge, instead of a fixed `InpChartMarginBars` (removed). `.ex5` 20:53 verified newer than sources. |
| 2026-09-13 | **Still not moving at all** (screenshot: chart stuck on today's date while the banner correctly named a 2023 session — the box/markers for that session were being drawn at the right time/price coordinates but off-screen, since the view itself never moved). Two straight silent failures of `ChartSetInteger(CHART_FIRST_VISIBLE_BAR,...)` means stop guessing at that single mechanism and (a) get hard proof, (b) unblock the user immediately regardless of root cause. Added: a `ChartNavigate(0,CHART_END,-target)` fallback tried whenever the `ChartSetInteger` readback doesn't match: full diagnostic `PrintFormat` (open/close time, computed shifts, `CHART_VISIBLE_BARS`, target, live `CHART_AUTOSCROLL` state, actual vs target) on any mismatch or on demand; extended the `OnTimer` re-assertion burst from 6×300ms to 12×500ms (~6s); and — the actual unblock — a 4th **"GO TO SESSION"** button that calls `ApplyChartNav(true)` on demand so the user can force-recenter regardless of whether the automatic path is working in their environment. `.ex5` 20:59 verified newer than sources. Root cause of the original failure still unconfirmed — next report from the user (does the button work? what does the diagnostic Print say?) will settle it. |
| 2026-09-13 | **First real calibration — 520 hand-labelled sessions.** User labelled a full batch via `SessionLabeler.mq5` (`Common\Files\SessionsStrategyV2_Labels_XAUUSD.csv`: 360 green / 160 red, 69%/31%). Ran `calibrate_quality.py --labelled-csv`. Findings: `range_atr`/`leg_atr` correlate with the label (±0.425 each) MORE than `range_ratio` (±0.354), contradicting the earlier hand-tuned assumption that rng/base should be the dominant gate; the grid search's original hard-coded ranges were too narrow (winning values kept landing on the grid's own edge) — widened `rb/ra/la/ib` grids in the script, and because 69% of labels are green, switched the ranking metric from F1 (gameable by a "let everything through" policy against class imbalance) to **MCC** (0 = no better than guessing), now printed alongside a majority-baseline row for context. Winning gate: `range_ratio≥0.70 AND (range_atr≥10 OR leg_atr≥6.0) AND impulse_bars≥1` → **MCC 0.57, F1 0.85, precision 0.89, recall 0.82** (baseline "always green": MCC 0.00, F1 0.82 — confirms the gate is doing real work, not just riding the class imbalance). Also checked whether adding `efficiency` as a 3rd OR branch helps (the decision tree uses it in two places): only marginal, MCC 0.585 vs 0.570 — not worth the added complexity, left out of the live gate. Applied the new thresholds as defaults to both `T2c_SessionQuality.mq5` and `SessionLabeler.mq5` (`MinRangeRatio` 1.05→0.70, `MinRangeAtr` 8.0→10.0, `MinLegAtr` 2.5→6.0, `MinImpulseBars` 2→1 — the impulse-bar gate turned out to have ~zero feature importance in the real data, kept at a minimal safety-net value rather than removed). Both compile 0/0, `.ex5` verified newer than sources (T2c 21:23, SessionLabeler 21:24). Re-run the calibration script as more sessions get labelled — MCC 0.57 is real progress over hand-tuning but leaves room to improve. |
| 2026-09-13 | **Session labelling tool + more volatility features.** User proposed a dedicated labelling EA instead of eyeballing CSV rows after the fact. Built `v2/tools/SessionLabeler.mq5`: steps through history, and the instant a session closes it BLOCKS that `OnTick` call in a `Sleep()`+button-poll loop — the tester's simulated clock cannot advance until GREEN/RED/SKIP is clicked (button STATE toggles natively even while EA code isn't running, same fact v1's `BiasPanel.PollClicks` already relies on) — then appends one row straight to `Common\Files\SessionsStrategyV2_Labels_<symbol>.csv`, flushed immediately so nothing is lost. Caveat flagged to the user: confirm clicks actually register while the loop is blocked; if not, fall back to a backlog-queue design instead of a hard pause. Also added 4 new exported-only (non-gating) metrics to `SessionQuality.mqh`, per the user's "add more volatility features" ask: `bodyImpulseCount` (conviction-candle count using candle BODY not full range — the correct fix for a wick/spike inflating range-based impulse count, kept as a separate candidate rather than silently replacing the live gate), `maxBarRangeShare` (one bar's share of total session range — continuous single-spike signal), `longestRun`/`runRatio` (persistence, distinct from Kaufman efficiency), `volumeRatio` (session tick-volume vs the same median-of-same-type-sessions baseline machinery already built for range). CSV header/row generation was factored out of T2c into shared free functions `V2_QualityCsvHeader`/`V2_QualityCsvRow` in `SessionQuality.mqh` so T2c and the labeller can never drift apart in column order. `calibrate_quality.py` extended: new features added to its analysis list, plus a `--labelled-csv` mode that consumes the labeller's self-contained output directly (skips the old template/join workflow entirely). All three (`SessionQuality.mqh` change, `T2c` CSV refactor, `SessionLabeler.mq5`) compiled 0/0, `.ex5` verified newer than sources (T2c 20:04, SessionLabeler 20:08); `calibrate_quality.py` re-verified end to end on synthetic data. |
| 2026-09-13 | **6 — `AnchorSelect.mqh` + `tests/T2d_AnchorSelect.mq5` (uses the calibrated gate above).** Added `maxAnchorLookbackHr`/`anchorFlexMin`/`noAnchorAction` to `SSettingsV2`. `CAnchorSelect` owns no detection of its own — the caller (T2d, later the integration EA) calls `RecordSession()` once per completed session with the SAME `SessionQuality::EvaluateCompleted()` result it already computed for its own purposes (keeps the baseline-ring ingestion single-owner), then at each TRADE session open calls `Select()`, which walks that history newest-first, skips anything not PASS, and for the first PASS asks `CZigZag::LastSignificantIn()` (already existed, unused until now) for a confirmed pivot within `±anchorFlexMin` of that session's CLOSE. Deviation from the plan text: if a PASS session's window has no confirmed pivot at all, `Select()` keeps walking further back instead of failing outright on that one session — a qualifying session with no swing near its own close is unusable but doesn't disqualify an older qualifying one. Gives up (`skip=true`) once `maxAnchorLookbackHr` is exceeded. `T2d_AnchorSelect.mq5` is self-contained: runs ZigZag + the calibrated SessionQuality gate + AnchorSelect + an AVWAP overlay anchored wherever it resolves, all on one chart, so every C2d checklist cross-check (pivot = real swing, source session = green, never past the lookback) is visible without juggling three separate test EAs. Writes `Common\Files\SessionsStrategyV2_Anchor_<sym>.csv`. Compiles 0/0, `.ex5` 21:59 verified newer than every source. Awaiting the user's visual verification (C2d checklist, ≥6 weeks so the quality baseline is warm). |
| 2026-09-14 | **Recalibration #3 — is the baseline warm-up worth it? (user asked directly, twice, "do not be stupid").** Checked against the real 520-session labels rather than arguing from first principles. Found two things: (1) **a live bug** — the shipped gate's 3rd movement OR-clause, `leg_ratio≥minLegRatio` (0.9), was added to `SessionQuality.mqh` for the 2026-09-13 recalibration but the calibration script's `grid_search()` never actually tested a 3-way OR, so it was shipped uncalibrated; checked in isolation it costs **0.106 MCC** (0.570→0.464) — it was quietly making the classifier worse than what was actually validated. Removed it (dropped `minLegRatio` from `SSettingsV2` and every `.mq5` entirely, it's now unused code, not a dead flag). (2) **the warm-up question itself**: compared three variants on the real labels — hard-blocking baseline gate (what was shipped, bug-fixed): MCC 0.570; baseline dependency removed entirely: MCC 0.561; baseline check kept but made **confirm-only** (applies when `baseline>0`, vacuously true otherwise — never withholds a verdict): **MCC 0.580, the best of the three**. Conclusion: the hard-blocking form of warm-up is not just "not worth its cost," it is measurably worse than both of the alternatives on real data — because the ATR-based movement gates (`range_atr`/`leg_atr`) correlate with the real label MORE than the baseline-ratio ones (0.425 vs 0.354) and are available from bar 1, forcing WARMING for ~20 same-type sessions was withholding the *more* trustworthy signal, not the less trustworthy one. **Fix applied**: `SessionQuality.mqh` GATES logic is now `pass = (range_atr≥minRangeAtr OR leg_atr≥minLegAtr) AND impulseBars≥minImpulseBars AND (baseline≤0 OR range_ratio≥minRangeRatio)` — every session gets a real PASS/FAIL from session 1; `SQualityResult.state` is now always `"PASS"`/`"FAIL"` (the `"WARMING"` value is gone); added `SQualityResult.baselineWarm` (bool, informational only — never gates) so the UI can still flag "(warm)" next to a verdict from a thin baseline. `T2c`, `SessionLabeler.mq5`, `T2d_AnchorSelect.mq5` all updated to match (dropped the `InpMinLegRatio` input, updated dashboard/box colouring to `r.pass` instead of the removed `state=="WARMING"` branch, appended a `(warm)` tag from `baselineWarm`). `calibrate_quality.py`'s `grid_search()` rewritten to test this exact shape (confirm-only, not blocking) instead of the old hard-AND — re-run against the 520-session file and confirmed it reproduces **MCC 0.580, F1 0.859, precision 0.892, recall 0.828** at the same thresholds (`MinRangeRatio 0.70`, `MinRangeAtr 10.0`, `MinLegAtr 6.0`, `MinImpulseBars 1`) — `MinRangeAtr` is flagged by the script as touching the grid's edge, but a follow-up check found `range_atr` has ~zero marginal effect on this dataset once `leg_atr≥6.0` is satisfied (it's a fully redundant OR-branch here, MCC is identical from `ra=6` to `ra=999`) — kept at 10.0 as a safe, harmless default rather than "optimized" toward a meaningless edge value. All three `.mq5` files compile 0/0, `.ex5` verified newer than every source (T2c, SessionLabeler, T2d all recompiled). |
| 2026-09-14 | **T2d bug: "PASS but NO ANCHOR" + 2 usability asks from the user's screenshot.** (1) *Root cause of the anchor bug*: the pivot search window was a SYMMETRIC `±AnchorFlexMinutes` (60) around the source session's CLOSE only. Chart geometry showed a PASS'd Asia session's actual swing low forming well over 60 minutes after Asia's close (continuing into the quiet gap before London), so `LastSignificantIn` legitimately found nothing even though Asia had PASSED - a real bug, not a rendering glitch. **Fix**: `AnchorSelect::Select()` window is now `[source session OPEN, source session CLOSE + AnchorFlexMinutes]` (asymmetric, starts at the session's own open, only extends past the close) and `AnchorFlexMinutes` default bumped 60->120 with margin over the observed gap. (2) *"boxes should draw once the session starts, not after it ends"*: added `DrawLiveBox()` in `T2d_AnchorSelect.mq5` - the moment a session opens it gets an immediate yellow "IN PROGRESS" box (fixed to the session's scheduled open/close on the X-axis, Y-extent growing bar by bar), replaced by the real green/red PASS/FAIL box the instant the session actually closes. (3) *"anchor should re-anchor 30 min before the session starts"*: added `anchorPreRollMin` (`SSettingsV2`, default 30) and `InpAnchorPreRollMin` (T2d). Replaced the old "select exactly on the session's own open bar" trigger with `CheckAnchorPreRoll()`, which fires on the bar `AnchorPreRollMinutes` before each TRADE session's scheduled open (Asia/NY), re-selects the anchor and re-points `CAVWAP` early — the actual session-open time is still what's passed to `Select()`/used in labels/CSV (only the TIMING of the call moved earlier, not what it reasons about) — so by the time the session itself begins, AVWAP already has some bars of warm-up instead of starting stone cold at bar 0. `T2d_AnchorSelect.mq5` compiles 0/0, `.ex5` verified newer than every source (including `AnchorSelect.mqh` and `V2Common.mqh`). Awaiting the user's re-verification. |
| 2026-09-14 | **7 — `Zones.mqh` + `tests/T3a_Zones.mq5`.** Added `confirmStateMaxBars` (12) to `SSettingsV2`. `CZones::Update()` takes the AVWAP state for a just-closed bar (ready flag, price, vwap, sigma) and classifies `d=price-vwap`, `dSigma=d/sigma` into Z1 (`|dSigma|<band1Mult`) / Z2 (`<band2Mult`) / Z3 (`>=band2Mult`) — reusing `band1Mult`/`band2Mult` from `AVWAP.mqh` rather than hard-coding 1σ/2σ, so the zone boundaries and the drawn bands can never drift apart. `committedDir`: Z1 = sign(d) (trend), Z3 = -sign(d) (reversion, "above +2σ → short" per spec), Z2 = `DIR_NONE` (contested/not committed, matches the strategy description already in memory). Z2 CONFIRMING: starts at 1 on entry, increments once per closed bar, wraps back to 1 after `confirmStateMaxBars` rather than exiting the state (the actual exits — leaving the zone, session end, a trigger firing — are a ZoneEngine/C3d concern, out of scope for this pure classifier). Suppressed (`ZONE_NONE`, `ready=false`) whenever AVWAP isn't ready or σ≤0 — the counter freezes/resets during warm-up rather than guessing. `T3a_Zones.mq5` is built the same self-contained way as T2d (runs ZigZag+quality+AnchorSelect+AVWAP internally, adding Zones on top) so every earlier checklist stays visible on one chart; draws a bottom strip (Z1 grey / Z2 amber / Z3 red, one filled cell per closed bar, Y-band auto-scaled to the price range the visible cells actually cover, blank during suppression) plus a `d = +1.34σ  ZONE Z2  stance: contested (CONFIRMING 4/12)`-style dashboard line, matching the spec's example format. Compiles 0/0, `.ex5` verified newer than every source. Awaiting the user's visual verification (C3a checklist, 1-2 weeks with a clear ±2σ excursion). |
| 2026-09-14 | **T3a verified by the user ("working as expected").** Milestone 7 passes. |
| 2026-09-14 | **8 — `RejectBreak.mqh` + `tests/T3b_RejectBreak.mq5`.** Added 7 settings (`touchTolSigma` 0.10, `rejectCloseSigma` 0.05, `rejectRequireWick` true, `rejectWickMinFrac` 0.5, `breakBufferSigma` 0.15, `breakRequireMomentum` true, `breakBodyAtr` 0.8) to `SSettingsV2`, straight from spec §9.1. `CRejectBreak` implements the 4 primitives exactly as written (`rejectionAsSupport`/`rejectionAsResistance`/`breakUp`/`breakDown`, all closed-bar, sigma/ATR-relative) as private helpers, then `Update()` per closed bar re-derives Z2 membership from `dSigma` directly (deliberately NOT calling into `Zones.mqh` — keeps this module pure/independently testable, per the one-module-per-subsystem convention) and runs the **provisional lean** state machine from spec §8-Z2: upper Z2 half checks `rejSup@U1`→lean LONG / `brkDn@U1`→lean SHORT; lower half mirrors at L1; the lean persists (and its bar-counter grows) while nothing new fires, and resets to `DIR_NONE` the instant `|dSigma|` leaves the Z2 range. The **Extended-transition flag** (`breakUp@U2` / `breakDown@L2`) is evaluated independently of the Z2 gate — worked out during design that it's structurally impossible for it to fire while `inZ2` is true (the two dSigma ranges are mutually exclusive), so it naturally only ever fires on bars that are already Z3, which is exactly the point (a momentum-confirmed cross, not just a bare drift past the line). `T3b_RejectBreak.mq5` extends T3a's full self-contained chain with append-only markers (green up-arrow `rejSup`/`brkUp`, red down-arrow `rejRes`/`brkDn`, labelled `"<primitive>@<band>"`, persisted forever once drawn rather than redrawn from a ring buffer like the strip/boxes) plus a dashboard lean readout. Compiles 0/0, `.ex5` verified newer than every source (including `RejectBreak.mqh` and `V2Common.mqh`). Awaiting the user's visual verification (C3b checklist, reuse the T3a window). |
| 2026-09-14 | **9 — `Triggers.mqh` + `tests/T3c_Triggers.mq5`.** Added 9 settings to `SSettingsV2` (`entryMode`, `entryFillMode`, `revCounterLookback` 8, `revMinCounterMoveAtr` 0.8, `revBodyAtr` 1.0, `revCloseLocPct` 0.33, `revRequireEngulf` false, `revBreakBars` 2, `revConfirmCloses` 1) — reused the already-existing `bosSwingDepth`/`bosBufferPoints`/`bosConfirmMode` for Entry Type A rather than duplicating them. **Dependency-table correction caught before building**: the plan lists `Triggers.mqh`'s only dependency as milestone 4 (Fractals/BOS), NOT the Zones/AnchorSelect/AVWAP chain — confirmed true by design (Triggers never reads vwap/sigma/zone at all), so `T3c` is a lean, T2b-style harness (Fractals + Triggers only), not another cumulative T3a/T3b-style chain. `CTriggers` owns a private `CFractals` internally for **Entry Type A — BOS** (spec's "delegate to Fractals.mqh" read as internal machinery, not a peer dependency the caller wires up, unlike AVWAP/ZigZag/SessionQuality) — thin wrapper around `CFractals::CheckBOS()`, converting to `STriggerEvent` and applying `entryFillMode`. **Entry Type B — Reversal+Momentum** implements spec §9.3's 3 steps directly (counter-move size check over `revCounterLookback` bars ending at a local extreme, a momentum candle with body/close-location thresholds and an engulf-OR-breaks-last-N-highs confirmation, then `revConfirmCloses` confirming closes with the extreme required to hold — collapses to firing immediately on the momentum candle when the default of 1 is used, but the general pending-state mechanism supports more without extra latency logic elsewhere). Both trigger types report through direction-scoped `Query(dir)` for the real consumer (ZoneEngine, C3d — BOS wins a same-bar/same-direction tie against REV, an arbitrary but documented and deterministic tie-break), plus raw `BosThisBar()`/`RevLongThisBar()`/`RevShortThisBar()` accessors so a test harness can see everything that fired even when `Query()` would collapse it. `entryFillMode` (BOS_CLOSE/NEXT_OPEN) applied uniformly to both trigger types — spec §9.2 only names it under BOS, a documented extrapolation for consistency, not a spec quote. `T3c_Triggers.mq5` reuses `Fractals.mqh` directly (via `CTriggers::FractalsPtr()`) to draw the exact T2b-style fractal/BOS overlay for a 1:1 cross-check, plus entry arrows, dashed protected-extreme lines, and shaded legs for every trigger (either type, both directions). Compiles 0/0, `.ex5` verified newer than every source (`Triggers.mqh`, `V2Common.mqh`, `Fractals.mqh`). Awaiting the user's visual verification (C3c checklist, 3-5 days with a mix of clean breaks and sharp reversals). |
| 2026-09-14 | **T3c fix — chart clutter.** User's screenshot showed 15 accumulated trigger markers (leg boxes + dashed protected-extreme rays + arrows) all left on the chart forever — `DrawTrigger` was append-only/permanent, unlike every other test harness's redraw-a-capped-ring pattern. Fixed: renamed to `DrawTriggerObj` (draws one), added `RedrawTriggers()` (clears the whole "TRG" group and redraws only the last `InpMaxDrawnTriggers`, default 2, from the ring) called once per bar after pushing any new events — the dashboard's text "recent triggers" list is unaffected (still shows up to `InpKeepTriggerMarks`=40, since text costs no chart clutter). `.ex5` verified newer than source. |
| 2026-09-14 | **T3c verified by the user.** Milestone 9 passes. |
| 2026-09-14 | **10 — `ZoneEngine.mqh` + `tests/T3d_ZoneEngine_Flip.mq5`.** Added `allowFlipInDirectZone`/`allowFlipInExtendedZone` (both false) to `SSettingsV2`. `CZoneEngine::Decide()` implements spec §14's per-bar pseudocode exactly as a pure function: `sessionDirection` is a **caller-supplied parameter, not state this class owns** — the real direction-lock (first fill sets it, immutable that session) is TradeManagerV2's job (C4, not built yet), so a test harness or the eventual integration EA tracks that one value itself and passes it in each call, keeping this module independently testable. When locked, only that direction's trigger is checked (zone is ignored entirely) — which is also *how* spec §15's "CONFIRMING trigger takes precedence over re-zoning until it resolves or times out" falls out for free, with no extra state needed. Unlocked: Z1/Z3 hunt only the committed direction (`Zones.mqh`'s own `committedDir`, already correctly signed for each zone) unless the matching `AllowFlip*` toggle is on; Z2 hunts **both** directions, first valid trigger wins (LONG tie-break on a same-bar dual-fire, documented as an arbitrary but deterministic edge case), with `isFlip = (triggerDir != lean)`. Caught **one real bug before compiling clean**: `ZoneEngine.mqh` referenced `rb.confirming`, a field that only exists on `SDiagZones` (Zones' own Z2 counter) — `SDiagRejectBreak` has no such field (its lean-bars counter is separate). Fixed to read `rb.lean`/`rb.leanBars` directly; first compile caught it (1 error), second was clean. `T3d_ZoneEngine_Flip.mq5` carries the full chain (T3b's Zones/RejectBreak/AnchorSelect/AVWAP plumbing + T3c's Triggers) and adds: a trade-session-scoped direction-lock simulation (resets whenever the Asia/NY occurrence changes, matching spec's `activeTradeWindow` gate — Zones/RejectBreak/Triggers still compute continuously outside it, informational only, same as T3b/T3c), and on every `take` a large arrow + `TAKE LONG · Z1 · trigger BOS · lean NONE` label plus **preview-only** dashed SL/TP lines using spec §10's plain default formula (`PCT_OF_LEG` buffer + `RR=1.5`) — explicitly NOT `RiskV2.mqh` (C4, doesn't exist yet), commented as such so it's never mistaken for the real sizing path. Applied **T3c's clutter lesson from the start this time**: decision markers redraw from a capped ring (`InpMaxDrawnDecisions`, default 2) instead of accumulating forever. Compiles 0/0, `.ex5` verified newer than every source (`ZoneEngine.mqh`, `V2Common.mqh`, `Zones.mqh`, `RejectBreak.mqh`, `Triggers.mqh`, `AnchorSelect.mqh`). Awaiting the user's visual verification (C3d checklist — Ex1-Ex6 + the Z2 flip case, spec §17.1, hand-picked historical dates). |
| 2026-09-14 | **11 — `RiskV2.mqh` + `TradeManagerV2.mqh` + `tests/T4_RiskAndManagement.mq5` — THE FIRST v2 MODULE THAT PLACES REAL ORDERS.** Added Risk/SL/TP settings (`rr` 1.5, `slBufferMode` PCT_OF_LEG, `slBufferPct` 0.10, `slBufferAtrMult` 0, `slBufferPoints` 0, `minStopAtrMult` 0, `clampStopsToBroker` true, `riskMode` PERCENT, `riskPercent` 0.5, `fixedLot` 0.01) and Trade/Session-management settings (`maxTriesPerSession` 2, `secondTryOnlyAfterSl` true, `allowReentryAfterWin` false, `maxSpreadPoints` 50, `maxSlippagePoints` 20) to `SSettingsV2` — all defaults straight from spec §10/§11's Part F table. `RiskV2.mqh` is pure calculation (`Compute()` → SL/TP/lots/valid, one call), reusing v1's `RiskManager.mqh` `OrderCalcProfit`-based `LossPerLot`/`LotForRisk` **verbatim** (never tickValue/tickSize — that inflated lots ~100x on some brokers, fixed in v1 commit `87807eb`; a mistake worth not repeating). `TradeManagerV2.mqh` is the **only v2 module that places orders**: single-slot (v2 is one-trade-per-session, so v1's multi-slot `SOpenPos` array was deliberately not reused), owns a `CTrade` instance, and reuses v1's proven order-placement discipline researched fresh from `v1/SessionsStrategy.mq5` for this milestone: the exact retcode-check-then-`FindOwnRecentPosition`-recovery pattern (MT5 has returned `false`+retcode 0 for an order the server actually placed; a failed `trade.Buy`/`Sell` return with a live position must still be adopted, never dropped) and the `[SS]`→`[V2]` journal+`Alert()` discipline (SKIPPED paths print only, FAILED/OPENED/CLOSED print AND `Alert()`). Close detection is **polled** (`PollClosed()`, called every tick, matching this codebase's established poll-don't-event convention rather than `OnTradeTransaction`) and reads the closing deal's own `DEAL_REASON`/`DEAL_PROFIT` to determine win/loss and specifically SL-vs-other (for `SecondTryOnlyAfterSl`), not a guess. `sessionDirection`/`tries` live inside `TradeManagerV2` now (T3d's local simulation is gone) with `CanOpenNew()` as the single gate combining direction-lock, try cap, `SecondTryOnlyAfterSl`, and `AllowReentryAfterWin`. `T4_RiskAndManagement.mq5` extends T3d's exact chain (Zones/RejectBreak/AnchorSelect/AVWAP/Triggers/ZoneEngine unchanged) and adds: real `RiskV2.Compute()` + `TradeManagerV2.TryOpen()` on every `take` `CanOpenNew()` allows, a DIR LOCK / try-counter badge on the live session box, a magenta force-close marker (using `CTimeSessions::IsForceCloseTime`, already existed, just never called before), and orange spread-reject marks — decisions that fire but get blocked (locked out, spread, lots=0) draw grey "NOT OPENED (reason)" instead of a real entry, so a blocked take is never visually confused with an executed one. Compiles 0/0 first attempt, `.ex5` verified newer than every source (`RiskV2.mqh`, `TradeManagerV2.mqh`, `V2Common.mqh`, `ZoneEngine.mqh`). **Runs only in the Strategy Tester — never point this at a live/demo chart.** Awaiting the user's visual verification (C4 checklist: one position max, 2nd try only after SL, direction lock holds, flat by force-close, R×lots≈riskPercent×balance, TP=RR×SL distance, spread reject works, SL clamps to STOPS_LEVEL). |
| 2026-09-14 | **12 — `SessionsStrategyV2.mq5` + `Include/AnalyticsV2.mqh` — THE INTEGRATION EA. All of P0-P5 is now code-complete.** `AnalyticsV2.mqh`: one CSV row per closed trade (spec D2's full column list), buffer-and-flush-in-`OnDeinit` + a global never-resetting `trade_no`, reusing v1's proven design. MAE/MFE folded from **completed-bar** highs/lows via `SampleBar()` (called once per closed bar while a trade is open) — model-independent, same approach as v1. Deliberately kept "measurement only": it records whatever it's told via `OnOpen()`/`OnClose()`/`SampleBar()`, no lookups of its own, so it can never accidentally gate a decision. `FinalizeOpenAsEndOfTest()` closes out any still-open record before `Flush()` so a run never ends with an implicit "still open" row (D4: "zero UNKNOWN exit reasons"). Small but necessary extension to `TradeManagerV2.mqh` made for this milestone: `PollClosed()` now also captures the exit deal's price and populates a one-shot `SCloseEventV2` (`ConsumeCloseEvent()`) carrying `{reason, closePrice, netProfit}` — the exit-reason text now correctly distinguishes `FORCE_CLOSE` from a generic `MANUAL` close via a `m_forceCloseInFlight` flag set around `ForceCloseIfDue()`'s own `PositionClose()` call, not inferred after the fact. `SessionsStrategyV2.mq5` wires every P0-P4 module (all individually verified via T0-T4) into one `OnTick` following spec §14's pseudocode exactly: role≠TRADE → force-close check only; session-open-bar → pick anchor; AVWAP suppressed → return; entry window + `CanOpenNew()` → `ZoneEngine.Decide()` → (if `take`) `RiskV2.Compute()` → `TradeManagerV2.TryOpen()`; every tick → `PollClosed()`/`ForceCloseIfDue()`/MAE-MFE sampling. Every C0-C4 test overlay becomes an `InpDiag<Component>` toggle (`VisualsV2`, same drawing code as T2c/T2d/T3a-d/T4) — **AVWAP bands and the real trade markers (entry/SL/TP/DIR-LOCK/force-close/spread-reject) default ON** since they're the EA's actual output, not debug info; ZigZag pivots/quality boxes/zone strip/RejectBreak markers default OFF as genuinely diagnostic. `InpExecute=false` runs the identical decision pipeline (including `RiskV2.Compute()`, so SL/TP/lots are visible in the `Print` log) but never calls `TryOpen()` — this IS the I1 dry-run stage (spec D3), a real input switch rather than a separate build. Compiles 0/0 on the first attempt, `.ex5` verified newer than every source. **Places real orders when `InpExecute=true` — Strategy Tester only.** Awaiting I1 (dry run, all InpDiag* on, 1 week — confirm the combined picture looks right and nothing throws) before I2 (one session, execute, walk every trade against its CSV row) → I3 (full 2-3y range, expectancy by zone/trigger/flip/session) → I4 (robustness). |
| 2026-09-14 | **Real bug: positions never force-closed at session end.** User reported trades stayed open past session end in the tester. Root cause in `TimeSessions.mqh::IsForceCloseTime` (part of milestone 1, marked verified): it derived the session to check via `Session(brokerNow)`, but `CurrentSession()` uses a **strict** `m<EndMin` test, so the instant `brokerNow` reaches the session's own close minute, `Session()` already reports `SESS_NONE` — and `IsForceCloseTime` returned `false` immediately on seeing that, before ever reaching its own `brokerNow>=close-offset` check. With the default `ForceCloseOffsetSec=0` the window `[close-0, close)` is empty **by construction** — the function could never return true, at any tick, ever. Not a missing feature (the switch already existed as `closeOnSessionEnd`/`InpForceCloseOffsetSec`), a genuinely broken check underneath it. **Fix**: `IsForceCloseTime` now takes the session to check as an explicit parameter instead of re-deriving it — callers keep their own "last TRADE session seen" (`g_forceCloseSession`, updated every bar while `Role()==ROLE_TRADE`, deliberately never cleared when `Session()` rolls to `NONE`) so the check keeps testing the right session on every tick after the boundary, not just the one tick it was crossed on (a single-tick window would have been fragile even fixed, if `ForceCloseIfDue`'s `PositionClose` were ever rejected). Updated the 3 call sites (`T0_TimeSessions.mq5`'s verbose print, `T4_RiskAndManagement.mq5`, `SessionsStrategyV2.mq5`) and `TimeSessions.mqh::Diag()`'s own internal call. **Also added the switch the user asked for explicitly**: `InpCloseOnSessionEnd` (default **true**) is now a real input in both `T4` and `SessionsStrategyV2.mq5` — `closeOnSessionEnd` was a real `SSettingsV2` field already but had been hard-coded `true` in `BuildSettingsV2()` with no way to turn it off. All 3 recompiled 0/0, `.ex5` verified newer than every source. |
| 2026-09-14 | **Anchor selection redesign #2 (user screenshot: a closer pre-session pivot was skipped for a farther post-close one).** Root cause: `Select()` searched ONE window per PASS source session, `[session.open, session.close+anchorFlexMin]`, and always took the NEWEST confirmed pivot in it (`ZigZag::LastSignificantIn`). Two problems: (a) nothing before the session's own open was ever considered, even though a pivot forming minutes before a session opens is often the swing that actually defines it; (b) blending "inside the session" and "after close" into one window meant a late, low-conviction post-close pivot always beat an earlier, more decisive one purely by being newer. **Redesign, discussed with the user before implementing (their explicit request)**: two-tier resolution per PASS session. Tier 1 — inside `[open, close)`, newest confirmed pivot wins (unchanged core rule, just scoped strictly to inside). Tier 2 (only if tier 1 finds nothing) — search both directions within `anchorFlexMin` of the boundary: newest pivot before open, oldest pivot after close (i.e. the one closest to close, not the newest overall — needed a new `ZigZag::FirstSignificantIn(t0,t1)` mirroring the existing `LastSignificantIn`, since "closest to close" is the opposite of "newest"), then take whichever candidate is closer in time to its boundary (ties favour BEFORE, arbitrary but deterministic, same convention as ZoneEngine's LONG tie-break). User was asked whether the search window should stay one shared `anchorFlexMin` for both directions or split into separate before/after inputs — chose **shared** (simpler, already tuned to 120min from the earlier post-close-lag fix). Added `SAnchorResult.anchorTier` ("INSIDE"/"BEFORE"/"AFTER") purely for transparency — chart labels, `[V2]`/`[T2d]` print lines, and T2d's anchor CSV all now show which tier resolved the pivot, so the new mechanism is visually checkable, not a black box. Touched `ZigZag.mqh` (new method, additive/no signature changes), `AnchorSelect.mqh` (`Select()` rewritten around a new private `ResolvePivot()` helper, header comment rewritten), `T2d_AnchorSelect.mq5` (label/CSV/dashboard tier tag) and `SessionsStrategyV2.mq5` (label + pre-roll print tier tag). Since `ZigZag.mqh`/`AnchorSelect.mqh` are dependencies of 7 `.mq5` files, all 7 were recompiled to confirm nothing else broke: `T2a_ZigZag`, `T2d_AnchorSelect`, `T3a_Zones`, `T3b_RejectBreak`, `T3d_ZoneEngine_Flip`, `T4_RiskAndManagement`, `SessionsStrategyV2` — all 0 errors/0 warnings, all `.ex5` verified newer than both changed headers and their own source. |
| 2026-09-14 | **`SessionsStrategyV2.mq5` chart-clutter fixes (user screenshot: 3 issues).** (1) *Session boxes disappearing*: `DrawLiveBox()` (yellow "in progress" box) correctly clears itself the moment a session ends, but the finalized PASS/FAIL replacement (`DrawQuality()`/"SQ" group) was gated behind `InpDiagQualityBoxes`, which defaulted **false** — so nothing ever replaced the vanished live box. Not a drawing bug, a wrong default: flipped `InpDiagQualityBoxes` to **true** (session classification is real EA output the user always wants, not an optional diagnostic, matching how `T4_RiskAndManagement.mq5` already draws it unconditionally with no toggle at all). (2) *SL/TP lines pile up forever*: `DrawTradeOpen()`'s SL/TP lines use `VisualsV2::RayH()`, which always sets `RAY_RIGHT=true` (an infinite ray regardless of the passed end-time) — and the "TRD" group was never cleared, so every trade ever opened left a permanent dashed line running across the rest of the chart. Applied the same ring-buffer-redraw pattern already established for `T3c`'s triggers and `T3d`/`T4`'s decision markers: new `PushTradeMarker()`/`RedrawTradeMarkers()` + `InpMaxDrawnTrades` (default 3) — `ClearGroup("TRD")` then redraw only the last N trades every time a new one opens. (3) *General session-end cleanup request*: added `ClearSessionClutter()`, called once per session transition right after the quality box is finalized — wipes the "RB" (reject/break markers), "SPR" (spread-reject text) and "ZS" (zone-strip) groups plus resets the zone-strip's backing array, since these are pure per-session scratch. Deliberately left untouched (the user's explicit "keep" list): session boxes/classification (SQ, now always on), zigzag (ZZ, already self-bounded), trade markers (TRD, now ring-capped), the AVWAP bands (already self-clear on anchor rollover — confirmed via code read that the diagonal red lines in the screenshot are the real ±2σ AVWAP band, not a bug), and the anchor context (ANC). Compiled 0/0, `.ex5` verified newer than every source (including `TimeSessions.mqh` from the previous fix). |

| 2026-09-14 | **Chart-clutter fix #2 — the ring-buffer cap wasn't the real fix (user screenshot: SL/TP dashed lines still stretching across a later, unrelated session).** The earlier same-day fix capped `TRD`'s entry+SL/TP markers to the last `InpMaxDrawnTrades`, but `VisualsV2::RayH()` always sets `RAY_RIGHT=true` regardless of the end-time passed to it — an infinite ray. Capping by COUNT doesn't help when even the oldest kept entry stretches, unbroken, across every bar after it, including sessions that hadn't happened yet when the trade closed. **Real fix**: SL/TP rays moved out of the `TRD` group into their own `TRR` group representing "the currently open position's live risk," not a historical record — drawn once on open, and now explicitly wiped (a) the instant `ConsumeCloseEvent()` reports the position closed (`SessionsStrategyV2.mq5`, which already had that plumbing from the analytics milestone) or, for `T4_RiskAndManagement.mq5` which predates `ConsumeCloseEvent`, via a `g_wasOpen` true→false edge-detect on `g_tm.HasOpenPosition()` each tick, and (b) defensively again in the session-end sweep (`ClearSessionClutter()` / the equivalent inline call in T4) as a backstop. The entry arrow+label (`TRD`/`DEC`) is untouched — that's still the intentional persistent "entry signal" history the user asked to keep, ring-capped as before; only the SL/TP risk lines, which stop being meaningful the moment the trade they describe is over, get torn down. Applied to both real-order-placing EAs (`SessionsStrategyV2.mq5` and `T4_RiskAndManagement.mq5`) since they share the same `RayH`-based pattern. Both compile 0/0, `.ex5` verified newer than source. **General lesson, now also in memory: `RayH()`'s infinite-ray behavior means any SL/TP-style marker drawn with it must be torn down on the event that ends its relevance (position close / session end) — a "keep only the last N" ring-buffer cap bounds COUNT, not REACH, and does not fix this class of bug on its own.** |

| 2026-09-15 | **Direction/regime mechanism redesign — user correction, not a bug fix.** User asked me to explain how direction is decided "in all scenarios," suspecting it was wrongly implemented. I audited the whole chain (Zones.mqh, RejectBreak.mqh, Triggers.mqh, ZoneEngine.mqh, TradeManagerV2.mqh, RiskV2.mqh) against spec §8/§9/§11/§14 line by line and found it **matched the spec exactly** — the spec called for re-evaluating the zone on every closed bar until the first trade opened, with `sessionDirection` locking only post-entry. The user then clarified this was itself wrong: **"we should lock the dir when session opens for the continuation and the reversal dir... the dir for this session is long for this entire session, and we look only for buys, and vice versa... this is a big misunderstanding."** One clarifying question was asked and answered (what happens if the session-open bar's zone is Z2/contested): **"there is no locking rigid dir, it's like confirmation, whoever wins we open a trade with it"** — i.e. Z2-at-open is the one case that keeps today's per-bar flip-enabled behavior, for the *entire* session (not just while price is literally inside Z2). Implemented as a **regime lock**: `ZoneEngine.mqh` now captures the zone ONCE, on the first AVWAP-ready closed bar of the session (practically the session-open bar, given the anchor pre-roll), and holds it fixed — Z1-at-open → CONTINUATION regime, direction locked to that bar's `committedDir`, hunt only that side all session; Z3-at-open → REVERSAL regime, same but the reversion direction; Z2-at-open → CONFIRMATION regime, no lock, hunt both directions every bar for the whole session (unchanged Z2 logic, just no longer scoped to "while price is in Z2"). Deferred one bar if `d==0.0` exactly (avoids locking a meaningless direction). `CZoneEngine` gained its own `ResetSession()` (mirroring `CTriggers`/`CTradeManagerV2`) and is no longer a fully pure function of its arguments — it now owns the regime-lock state internally, since nothing else could legitimately own it. `HuntCommitted()` refactored to take the direction as an explicit parameter instead of reading `zd.committedDir` (which is now only the LIVE zone, display-only, disconnected from hunting logic). `SEngineDecision` gained `regimeZone`/`regimeDir`/`regimeLocked` for transparency — surfaced on the dashboard of all 3 consumers (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`, `T3d_ZoneEngine_Flip.mq5`) as a new "Regime (locked @ session open)" line, same transparency principle as the anchor-tier tag from the previous fix. All 3 recompiled 0/0, `.ex5` verified newer than `ZoneEngine.mqh` and every source. **Spec doc rewritten** (`Anchored_VWAP_Sessions_EA_Spec.md` → v0.5): new changelog entry, §1 summary + zone table, §8 (full rewrite), §9's directions-hunted list, §11 (now documents TWO locks — regime pre-entry, `sessionDirection` post-entry), §14 pseudocode, §15 edge cases, §18 assumptions, §2 terms table (added "Regime lock", clarified "Direction lock" is the separate post-entry one). |

| 2026-09-15 | **CRITICAL BUG FOUND AND FIXED: `ResetSession()` was silently orphaning every force-closed trade — 671 of 2085 trades (32%) in the user's 2020-2026 backtest, EVERY force-close in the whole run.** User asked for a deep analysis of a fresh 2020-now backtest to find out why it's losing. First pass on the CSV (`SessionsStrategyV2_Trades_XAUUSD.csv`) found impossible numbers: `net_r` values in the thousands (avg win 304R, avg loss -110R, when `rr_planned` is 3.0 everywhere), and win rate/PF wildly different by direction (LONG total_R +173k, SHORT -164k) despite no structural reason either direction should dominate. Root-caused via `exit_reason` breakdown: exactly 1177 SL + 237 TP + 671 `END_OF_TEST` = 2085 — **zero** `FORCE_CLOSE` rows, meaning no force-close EVER went through the normal close-event path; all 671 landed in `AnalyticsV2::FinalizeOpenAsEndOfTest()`, which closes any record still marked "open" using the FINAL test price/date (2026-09-14) and `netProfitMoney=0` — for a trade that may have actually, correctly closed years earlier at a completely different price. The `close_time` for all 671 was byte-identical (`2026-09-14 22:59:59`, the true deinit moment), confirming they were bulk-finalized, not genuinely still open. Root cause in `TradeManagerV2.mqh::ResetSession()`: it unconditionally wiped `m_pos.open=false` (among other fields) on every session-key change. `OnTick()`'s per-tick order is `PollClosed()` (checks if the tracked position closed) → ... → `ForceCloseIfDue()` (SENDS the close order, but does not itself flip `m_pos.open`) → ... → (on a new bar) the session-key-change block calling `ResetSession()`. Since session boundaries and M5 bar boundaries always coincide, a force-close initiated ON THE BOUNDARY BAR gets its `m_pos.open` wiped by `ResetSession()` in the SAME tick, one call later — before `PollClosed()` ever gets a chance (on the NEXT tick) to detect the real close and fire `ConsumeCloseEvent()`/`g_an.OnClose()`. From that point `PollClosed()`'s own `if(!m_pos.open) return` guard means it never looks for that position's close deal again — the record leaks as "open" forever, silently. This is fully deterministic (fires on every force-close, not a rare race), matching the observed 32%. **Fix**: `ResetSession()` now only clears `m_pos`/`m_beApplied`/`m_beFailLogged`/`m_forceCloseInFlight`/`m_closeEvent` when `!m_pos.open` — i.e. never touches the position-tracking state while a position is still genuinely open, letting `PollClosed()` finish tracking it to its real close (whether that's the force-close resolving or its own SL/TP) on a later tick; `CanOpenNew()` already blocks a new open the whole time regardless (checks `m_pos.open` first), so this costs nothing and closes the gap entirely. Shared fix in `TradeManagerV2.mqh` — benefits `T4_RiskAndManagement.mq5` too (no analytics there, but the same tracking-loss bug could have let it open a new real position before a stale one's close was ever confirmed). Both recompiled 0/0, `.ex5` verified newer than `TradeManagerV2.mqh` and their own source. **This CSV's 671 END_OF_TEST rows (and every aggregate stat derived from the full dataset) are garbage and must be disregarded; a fresh backtest run is required for a trustworthy full-history analysis.** The 1414 SL/TP rows in the existing export were NOT affected by this bug (they went through the correct close-event path) and were used for a provisional read: win rate 16.8% (237/1414) against `RR=3.0` (needs ≥25% to break even) — a real, structural edge problem, not a bug artifact. |
| 2026-09-15 | **`AnalyticsV2.mqh` advanced-analytics columns added (user request, same investigation).** To diagnose the low win rate above with more context per trade without re-deriving it from scratch, added 9 columns (see plan Part D2 for the full list): `dsigma_entry`, `atr_entry`, `sl_atr_ratio`, `spread_entry_pts`, `entry_mins_since_open`, `regime_at_entry`, `confirm_armed_at_entry`, `be_applied`, `bars_held`. Notably `regime_at_entry` (via new shared helper `V2_RegimeName()` in `V2Common.mqh`) is DIFFERENT from the existing `zone_at_entry` column: `zone_at_entry` is the LIVE zone at the trigger bar, while `regime_at_entry` is the regime the session LOCKED at its own open (2026-09-15 regime-lock redesign) — these can now diverge (e.g. session opens Z1/CONTINUATION but price drifts to Z2 by the time the trigger actually fires several bars later), and only `regime_at_entry` reflects what the EA actually locked and hunted for. `CAnalyticsV2::Init()` gained a `tf` parameter (needed to compute `bars_held` from `PeriodSeconds`); `OnOpen()`/`OnClose()` signatures extended (appended params, `OnClose`'s new `beApplied` defaults to `false` so `FinalizeOpenAsEndOfTest()`'s internal call - which has no per-record BE data available - didn't need updating). `SessionsStrategyV2.mq5`'s `OnOpen()`/`OnClose()` call sites wired to the data already in scope at each point (`zd.dSigma`, `g_risk.CurrentATR()`, the `spreadPts` already computed for the spread-reject check, `g_time.MinsSinceSessionOpen(now)`, `dec.regimeZone`/`regimeLocked`/`confirmArmed`, `g_tm.Diag().beApplied`) - no new `CopyRates` or lookups needed. Compiled 0/0 together with the `ResetSession()` fix above. **The user needs to re-run the Strategy Tester to get a CSV that is both bug-free (no more orphaned END_OF_TEST rows) and carries the new columns - the existing export has neither.** |
| 2026-09-15 | **Risk sizing now fixed to the INITIAL balance, not the live one (user request, behavior change).** User: **"make it from the initial balance, so that it's not getting decreased or increased as the balance goes up and down... on the 100k account, we should risk $1000 on every trade whether the current balance is 150k or 80k."** `CRiskV2::RiskMoney()` previously read `AccountInfoDouble(ACCOUNT_BALANCE)` live on every call — the $ risked per trade compounded with the account. Added `m_initialBalance` (`CRiskV2`), captured once in `Init()` (called once from each EA's `OnInit()`, i.e. tester/EA start) and never re-read afterward; `RiskMoney()` now multiplies `riskPercent` against this frozen value. `LotForRisk`'s SL/TP price conversion is untouched — still reads live broker state via `OrderCalcProfit` (that's a price/tick-value fact, not a balance fact; freezing it would be wrong). Added `CRiskV2::InitialBalance()` accessor, surfaced on both real EAs' dashboards (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`) as "risk X (Y% of INITIAL balance Z; W% of current balance)" — the two percentages now visibly diverge as the account compounds, which is the whole point (fixed $ = drifting % of current balance). `T3d_ZoneEngine_Flip.mq5` untouched (doesn't use `RiskV2.mqh`, preview-only SL/TP formula). Both recompiled 0/0, `.ex5` verified newer than `RiskV2.mqh` and their own source. Spec doc → v0.9 (§10, changelog). |
| 2026-09-15 | **Search concluded — consolidated to ONE surviving Enhanced EA, others deleted (user: "ran both, check" -> decomposition results -> "let's just keep that version, alongside the main, and remove the others, and then we will commit these codes... as the first init").** Decomposition (`Enhanced5` vs `Enhanced6`, run live) settled the open question from the previous entry: `RevConfirmCloses=2` tested alone (`Enhanced6`) came back roughly FLAT (avg -0.007R, PF 0.98, 4 of 7 years negative) — WORSE than no filter at all, rejecting that hypothesis outright. `InpMaxSpreadPoints=12` + `InpMaxAnchorLookbackHr=24` tested alone (`Enhanced5`, no confirmCloses change) came back as the best result of the entire 6-variant search: n=281, win rate 37.7%, avg **+0.125R**, PF **1.33**, positive in 6 of 7 years — critically, 2025 (the one weak year in the original `Enhanced.mq5`) flips POSITIVE (+0.067R). Confirms `Enhanced2`'s 3-straight-losing-year red flag from the previous entry was caused entirely by `RevConfirmCloses=2` dragging down an otherwise-excellent result, not by the spread/anchor tightening. **Action taken**: deleted `SessionsStrategyV2_Enhanced.mq5` (v1), `_Enhanced2.mq5`, `_Enhanced3.mq5`, `_Enhanced4.mq5`, `_Enhanced6.mq5` (source + `.ex5`, both real-money-adjacent experiment EAs) — `_Enhanced5.mq5` renamed to `SessionsStrategyV2_Enhanced.mq5`, becoming the sole second EA alongside the still-untouched main `SessionsStrategyV2.mq5`. Its `InpMagic`/`InpCsvPrefix`/dashboard title reset to the clean "Enhanced" identity (20260915 / `SessionsStrategyV2_Enhanced_Trades` / "ENHANCED"). File header fully rewritten to be self-contained: documents all 7 KEPT changes (`EntryMode=REVERSAL_ONLY`, `EntryWindowMinutes=15`, `MinAnchorScore=0.90`, `BlockContinuationShort=true`, `MaxSpreadPoints=12`, `MaxAnchorLookbackHr=24`, `BeTriggerR=0.5` unchanged-but-now-empirically-validated against both 0.35 and 0.75 alternatives) plus the one REJECTED change (`RevConfirmCloses=2`, tested and found net-negative — recorded explicitly so a future pass doesn't re-try it blind) and the residual open question (2024 negative in every variant tested, cause not yet determined). Recompiled 0/0, `.ex5` verified newer than every `Include/*.mqh` and its own source. **This is now the baseline for the next round of extension/enhancement work, per the user's own framing** — not yet promoted into the main EA's own defaults; kept as a second, explicitly-separate file exactly as the user asked ("keep that version, alongside the main"). |
| 2026-09-15 | **Round-2 results (user: "i have run all the versions, please check") + round-3 decomposition variants.** 4-way comparison: `Enhanced` (BE=0.5) n=464 avg +0.065R PF 1.16; `Enhanced2` (spread<=12 + anchor<=24h + confirmCloses=2) n=223 avg +0.080R PF 1.20 (best aggregate, but see below); `Enhanced3` (BE=0.35) n=464 avg +0.044R PF 1.12; `Enhanced4` (BE=0.75) n=464 avg +0.033R PF 1.07. **`BeTriggerR=0.5` is now empirically validated, not just a guess** — both tested alternatives (arm earlier at 0.35, arm later at 0.75) made results WORSE, for different mechanistic reasons visible in the `be_applied` split: 0.35 arms more often (59.5% vs 51.1%) but dilutes the armed cohort's own average (+0.588R vs +0.743R) because some early-armed trades get scratched by ordinary noise before reaching TP; 0.75 arms less often (38.8%) leaving more trades (284 vs 227) fully exposed to a complete loss. Recommend NOT changing this default further without finer-grained sampling (e.g. 0.4/0.6) — 0.5 sits at or near a local optimum for this entry population. **Enhanced2 has the best aggregate numbers but a serious robustness red flag caught only by looking year-by-year**: THREE STRAIGHT losing years, 2024 (-0.24R avg) / 2025 (-0.23R) / 2026 (-0.26R), with the entire positive edge concentrated in 2021-2023 (+0.26R avg those years) — a materially worse recency pattern than the single-file `Enhanced.mq5` baseline (which is only weak in 2025, positive everywhere else including 2024 and 2026). Built two decomposition variants to find which of Enhanced2's 3 stacked changes is responsible before trusting or discarding the result: `SessionsStrategyV2_Enhanced5.mq5` (spread<=12 + anchor<=24h ONLY, `RevConfirmCloses` left at 1) and `SessionsStrategyV2_Enhanced6.mq5` (`RevConfirmCloses=2` ONLY, spread/anchor left at Enhanced's own 50/48) — whichever reproduces the 3-year losing streak is the actual culprit; the other should look more like the broad, steadier `Enhanced.mq5` record. Also re-confirmed on this 4-way comparison, with a caveat added: the `mfe_bar`/`mae_bar` sequencing split (adverse-excursion-first vs favorable-first) is dramatically consistent across ALL FOUR variants (PF 4.3-5.0 vs PF 0.01-0.05) — the single most robust pattern found across 5 separate runs now — but flagged an important nuance on reflection: for a straight SL-loss trade, `mae_r` is pinned at 1.0 (the stop itself) so `mae_bar` is mechanically close to the closing bar, meaning "favorable-first" is partly ENTANGLED with "this trade eventually stopped out" rather than being a fully independent leading indicator observable mid-trade — real and consistent as a descriptive fact, but not yet a proven actionable real-time rule; a genuine leading indicator (not just a backward-looking outcome label) would be needed to turn it into a live management rule. Both new variants compiled 0/0, `.ex5` verified newer than every source. **Awaiting the user's Enhanced5/Enhanced6 runs to settle the decomposition question before any promotion decision.** |
| 2026-09-15 | **Enhanced EA live-run results + 3 round-2 variants (user: "check the results again, can we enhance more, think outside the box, test as long as we want, create multiple versions").** User ran `SessionsStrategyV2_Enhanced.mq5` over 2020-2026: **it works** — n=464, win rate 34.5%, avg +0.065R/trade, total +30.3R, PF 1.16 (vs the unfiltered baseline's avg -0.011R/PF 0.97). Positive in 5 of 7 years (2020/21/22/23/26); 2024 flat (-0.024R), 2025 clearly weak (-0.163R, n=78) - flagged as a real open question (alpha decay vs. a modest-edge system's normal variance at ~80 trades/year) rather than something explained away. Re-confirmed `be_applied` still carries essentially the entire edge (0: avg -0.642R; 1: avg +0.743R, PF infinite, zero losers) and the `mfe_bar`/`mae_bar` sequencing pattern is even sharper live (adverse-first n=305 avg +0.564R PF 5.02; favorable-first n=159 avg -0.892R PF 0.02). New patterns surfaced from the live CSV that hadn't been visible before (small sample-size caveats noted per bucket): tightest spread quintile (<=5pts) avg +0.230R/PF 1.74 vs 7-16pt quintiles at PF~0.83; anchor 24-48h back was the clear worst bucket (PF 0.51) vs 0-24h all >=1.06; bars-held quintiles show a strong (if noisy) nonlinear shape, worst at 1-4 bars (-0.105R) and best at 19-37 bars (+0.302R, PF 2.48). **Built 3 more isolated variants, each changing exactly ONE thing versus the (already-verified) Enhanced baseline, so each can be judged independently**: `SessionsStrategyV2_Enhanced2.mq5` (`InpMaxSpreadPoints` 50->12, `InpMaxAnchorLookbackHr` 48->24, `InpRevConfirmCloses` 1->2 — an execution/anchor-quality tightening pass, the last change a direct attempt to filter the "favorable-move-first-then-reverses" fakeout shape at the entry-logic level rather than just observing it after the fact), `SessionsStrategyV2_Enhanced3.mq5` (`InpBeTriggerR` 0.5->0.35, arm breakeven earlier), `SessionsStrategyV2_Enhanced4.mq5` (`InpBeTriggerR` 0.5->0.75, arm later) — 3 and 4 together sample both directions around the never-tuned default 0.5 so the SHAPE of that curve is visible from one round of testing, not just one guessed new value. Every variant: different `InpMagic` (20260916/17/18) and `InpCsvPrefix` so all four Enhanced* EAs (plus the untouched main EA) can run side by side without colliding; dashboard title names the variant. Zero `Include/*.mqh` changes in any of them — confirmed via `diff` against `SessionsStrategyV2_Enhanced.mq5` that each variant's delta is exactly the one intended change plus magic/prefix/title. All 3 compiled 0/0, `.ex5` verified newer than every `Include/*.mqh` and their own source. **Awaiting the user to run all 3 (or as many as they want) and report back CSVs before any of this goes near the default EA.** |
| 2026-09-15 | **`SessionsStrategyV2_Enhanced.mq5` created — an experimental fork to test the deep-analysis findings before touching the default EA (user request: "create a copy... if it's good, we can make it as default").** Not a shared-module change — `cp`'d from `SessionsStrategyV2.mq5`, every delta is either a different `input` default for an already-wired setting or a small additive gate living entirely in the new file, so `Include/*.mqh` and the main EA are both completely untouched. Four changes, each backed by a specific finding from the 2020-2026 analysis: (1) `InpEntryMode=EM_REVERSAL_ONLY` (was `EM_BOTH`) — REV averaged +0.039R/PF 1.10 vs BOS's -0.069R/PF 0.85. (2) `InpEntryWindowMinutes=15` (was 30) — edge decayed across the window (first 5min +0.052R vs the 15-20min bucket's -0.162R). (3) `InpMinAnchorScore=0.90` (new setting, 0=disabled elsewhere) — sub-0.90-scoring anchor sessions were the clearly-worst quality bucket (PF 0.75); enforced in `CheckAnchorPreRoll()` by flipping `SAnchorResult.found` to `false` when the score is under threshold, reusing the EXISTING "anchor not found -> AVWAP suppressed" path rather than adding new state. (4) `InpBlockContinuationShort=true` (new setting) — CONTINUATION regime + SHORT was the single worst regime/direction cell (avg -0.073R, shorting with the trend during gold's 2020-2026 structural uptrend); enforced as an inline `blockedContShort` check at the trade-opening gate using `dec.regimeZone`/`dec.regimeLocked`/`dec.direction`, already exposed on `SEngineDecision`. Also changed to avoid colliding with the main EA if run side-by-side: `InpMagic=20260915` (was 20260914) and `InpCsvPrefix="SessionsStrategyV2_Enhanced_Trades"` (was `"SessionsStrategyV2_Trades"`, already an existing input — no new setting needed there). Dashboard title says "ENHANCED" so it's visually unmistakable in the tester. Stacking all 4 filters on the SOURCE CSV post-hoc (same 1482 trades, not a re-run) showed n=240, win rate 38.3%, avg +0.129R, PF 1.34, positive in 6 of 7 years, positive in both directions roughly equally — real but a thinner sample (~36 trades/year) than the full run, and a POST-HOC approximation, not what this EA will actually produce live (tick-by-tick enforcement, not a CSV filter). Compiled 0/0, `.ex5` verified newer than every `Include/*.mqh` and its own source. **Next step is on the user: run this EA in the Strategy Tester over the same 2020-2026 range and compare its own trade CSV/equity against the baseline before promoting any of these 4 defaults into `SessionsStrategyV2.mq5` itself.** |
| 2026-09-15 | **Entry-window feature (user request) — also surfaced a real, pre-existing gap.** User asked for a hard cutoff: a new trade may only open within the first 30 minutes of a session, never after, until the next session. Investigation found `CTimeSessions::WithinEntryWindow()` already existed and was already NAMED in this spec's own §14 pseudocode (`if withinEntryWindow(now) and tries<MaxTriesPerSession...`) — but it only ever checked the LATE-session `noNewEntryOffsetSec` cutoff (default 0, i.e. a no-op), had no early-session concept at all, and — more importantly — was **never actually called by either real-order-placing EA** (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5` gated purely on `dec.take && CanOpenNew()`); only `T0_TimeSessions.mq5`'s own diagnostic dashboard ever read it. So the entry-window gate the spec pseudocode had documented since it was written was dead code in every path that mattered. Fixed both problems together: added `entryWindowMinutes` (`SSettingsV2`, default 30, `0`=unlimited) and extended `WithinEntryWindow()` to also require `brokerNow < SessionOpenBroker(...) + entryWindowMinutes*60`; added `CTimeSessions::MinsSinceSessionOpen()` + `SDiagTime.minsSinceSessionOpen` for dashboard transparency. Wired `g_time.WithinEntryWindow(now)` into the actual decision-gate in both `SessionsStrategyV2.mq5` (`dec.take && g_tm.CanOpenNew() && g_time.WithinEntryWindow(now)`, plus a verbose "TAKE blocked: entry window closed" print) and `T4_RiskAndManagement.mq5` (folded into the existing `!CanOpenNew()` "NOT OPENED" grey-marker branch, reason text distinguishes the two causes). Deliberately did NOT gate `ZoneEngine::Decide()` itself — regime capture and the CONFIRMATION arm-latch (both session-open-bar-scoped, independent of trade-taking) keep running every bar per the spec's own pseudocode ordering (regime capture happens BEFORE the `withinEntryWindow` check in §14), so the dashboard's regime/armed state stays accurate even after the entry window closes; only the act of opening an order is blocked. `InpEntryWindowMinutes` (default 30) added to `T0_TimeSessions.mq5` (dashboard now shows minutes-since-open + the window limit), `SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`. Since `V2Common.mqh`/`TimeSessions.mqh` are shared dependencies, all 10 consumers were recompiled to confirm nothing else broke (`T0`, `T1`, `T2c`, `T2d`, `T3a`, `T3b`, `T3d`, `T4`, `SessionsStrategyV2`, `SessionLabeler`) — all 0 errors/0 warnings, all `.ex5` verified newer than both changed headers and their own source. Spec doc → v0.8 (§11, §13, changelog). **General lesson: a mechanism named in the spec's pseudocode and even partially implemented (a real function, a real settings field) is not proof it's actually wired into the paths that matter — grep for the call sites, not just the definition, before assuming a feature already works.** |
| 2026-09-15 | **Breakeven-at-R feature (user request, new capability, not a bug fix).** User asked for a risk parameter that moves SL to breakeven once a trade reaches a configurable R-multiple (default 0.5R, vs the 1.5R `RR` target). Added `beEnabled`/`beTriggerR` to `SSettingsV2`. `SPositionRecordV2` gained `r` (the trade's ORIGINAL entry→SL distance, fixed at open, never re-derived after the SL moves — this is the unit `beTriggerR` multiplies, not the live post-BE distance). `CTradeManagerV2::ManageBreakEven()` (called every tick, right after `PollClosed()`): once `dir==LONG ? bid-entry : entry-ask` reaches `beTriggerR*r`, sends one `PositionModify` moving SL to entry; on success sets the one-way `m_beApplied` latch (never re-arms, never moves SL backward — checked via an `improves` guard); on a rejected modify (e.g. broker stops-level), does NOT set the latch, so it retries silently on later ticks instead of a v1-`AllOpenAtBreakEven`-style false positive — logs the failure once (`m_beFailLogged`) to avoid per-tick print spam on a persistent rejection. Both latches reset in `ResetSession()` and on every new `TryOpen()`. `SDiagTradeManager` gained `beApplied` for dashboard visibility (`OPEN position` line now appends `BE:Y`/`BE:waiting`). Wired into both real-order-placing EAs (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`) via a new `InpBeEnabled`/`InpBeTriggerR` input pair. `T3d_ZoneEngine_Flip.mq5` untouched (no `CTradeManagerV2`, preview-only SL/TP). Both recompiled 0/0, `.ex5` verified newer than `TradeManagerV2.mqh`/`V2Common.mqh`/`RiskV2.mqh` and their own source. Spec doc bumped to v0.7 (§10, §13, changelog). |
| 2026-09-15 | **CONFIRMATION-regime armed gate — second correction, same day, real user screenshot.** After the regime-lock redesign above, user showed a session that opened in Z2 (CONFIRMATION regime, correctly no direction lock) where the EA took a short BOS at `dSigma=-1.89` — deep in Z2, having never approached VWAP at all. Diagnosis: the CONFIRMATION branch hunted triggers from wherever price happened to be inside Z2, with no requirement that price ever get near the ±1σ boundary first. User's fix: *"we should enter only after the price enters the Z1 with close or wicks, then from there we check how the price reacts, whether it will go inside with momentum, or reverses."* Recognized that the second half of this ("check how it reacts") is already exactly what the existing BOS-vs-Reversal hunt-both logic does (BOS = broke through with momentum, Reversal+Momentum = snapped back) — the only missing piece was a **gate**. Implemented as `CZoneEngine`'s second piece of session state, `m_confirmArmed` (one-way latch, reset in `ResetSession()`): CONFIRMATION-regime sessions hunt no trigger at all until a closed bar's range overlaps the Z1 band (`barLow≤U1 && barHigh≥L1` — a symmetric wick-or-close touch test, direction-agnostic since we don't know which side the session opened on ahead of time), computed by each of the 3 consumer EAs from data they already fetch for `RejectBreak::Update()` (no new `CopyRates` call) and passed into `Decide()` as a new `touchedZ1ThisBar` parameter (defaulted `false` for signature back-compat). Once armed it never un-arms, even if price retreats back into Z2/Z3. If Z1 is never touched all session, no trade fires. `SEngineDecision` gained `confirmArmed` for diagnostics; all 3 dashboards now show "CONFIRMATION (both dirs, ARMED)" vs "...(waiting for Z1 touch)". CONTINUATION/REVERSAL regimes are completely unaffected — this gate only applies inside the CONFIRMATION branch. All 3 consumers (`SessionsStrategyV2.mq5`, `T4_RiskAndManagement.mq5`, `T3d_ZoneEngine_Flip.mq5`) recompiled 0/0, `.ex5` verified newer than `ZoneEngine.mqh` and every source. Spec doc updated to v0.6 (new changelog entry, §8's Z2 section, §9's directions-hunted list, §14 pseudocode, §15 edge cases, §18 assumptions). Before implementing, restated the mechanism back to the user for confirmation per their explicit "plan this first so I know you understand" request — confirmed correct, then built. |

**Deviations from the plan text:**
- Each module's `SDiag<Module>` struct lives in its own header, not `V2Common.mqh`.
- The spec's `BrokerToUTC_WinterOffsetHours` (§13) is exposed to the user as
  `ServerToRiyadhOffsetHr` — the same information, framed so "server clock == session clock"
  is the zero-config default. DST machinery unchanged.

### Next step

**Every milestone (0-12, all of P0-P5) is now code-complete and compiles 0/0 — the whole v2 EA
exists.** 1–5, 7 and 9 are visually verified; **6, 8, 10, 11 and 12 still need your check** —
this is now purely a verification backlog, not a building backlog:
- `T3b_RejectBreak.mq5` — C2d + C3b, 1-2 weeks with several band tests.
- `T3d_ZoneEngine_Flip.mq5` — C2d + C3d, hand-picked dates for Ex1-Ex6 + the Z2-flip case (spec
  §17.1). Confirm no `take` ever fires against the committed direction in Z1/Z3 with flips off.
- `T4_RiskAndManagement.mq5` — **places real orders, tester only.** 1-2 weeks, both sessions.
  One position max, 2nd try only after SL, direction stays locked, flat by force-close,
  `R×lots≈RiskPercent×balance`, TP=RR×SL distance, spread rejects work, SL clamps to STOPS_LEVEL.
- `SessionsStrategyV2.mq5` — **the integration EA itself**, run through the staged D3 plan:
  - **I1 dry run**: `InpExecute=false`, all `InpDiag*` on, 1 week — confirm the combined picture
    (anchor+zone+lean+trigger) looks right together, dashboard stays coherent bar-to-bar, nothing
    throws. This is the gate before ever flipping `InpExecute=true`.
  - **I2 one session, execute**: NY only, `InpExecute=true`, 1-2 weeks — walk every trade: the
    chart story must match `decision.reason` and the CSV row; SL/TP/lots correct; direction lock
    + 2-try + force-close all hold.
  - **I3 full range**: Asia+NY, visual off, *Every tick real ticks*, 2-3 years — collect the CSV,
    pivot by zone/trigger-type/flip/session, check expectancy/win-rate/PF/DD against spec §17.4.
  - **I4 robustness**: Asia vs NY split, walk-forward/OOS, parameter sensitivity, broker-to-broker
    (DST calendar) check.

All in the Strategy Tester (XAUUSD, M5, *Every tick based on real ticks*). This is the last
phase of the v2 rebuild — nothing left to design or build after I1-I4 pass, only tuning.

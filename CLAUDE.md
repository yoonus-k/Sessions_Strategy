# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single MetaTrader 5 Expert Advisor (MQL5) for **XAUUSD on M2**: `SessionsStrategy.mq5` plus
`Include/*.mqh`. There is no test suite, no package manager, and no build script — the only build
step is the MetaEditor compiler.

The EA is **semi-discretionary**: a directional bias (BUY/SELL/NONE) is armed per session — by
default automatically from the VWAP (`BiasMode = VWAP`), or manually from the on-chart panel — and
the EA mechanically enforces every other charter rule. The Arabic charter
in [docs/charter_ar.md](docs/charter_ar.md) is the source of truth for the 18 numbered rules;
[README.md](README.md) is the full English design spec and maps every rule to its implementation.
**Read README.md before changing strategy logic** — it documents the *why* behind the non-obvious
decisions (BOS trailing, IFVG priority, SL anchoring, the reference-only 4H range).

## Build

Compile from the CLI after **every** edit — the user runs the EA in the Strategy Tester immediately:

```powershell
& "C:\Program Files\MetaTrader 5\MetaEditor64.exe" /compile:"<abs path>\SessionsStrategy.mq5" /log:"<abs path>\compile.log"
```

The exit code is the **file count, not an error count**. Always read the log and check its
`Result: N errors` line. A second MetaEditor install exists at
`C:\Program Files\MetaTrader 5 EXNESS\MetaEditor64.exe`.

`SessionsStrategy.ex5` (the compiled binary) is committed to git — expect it in every diff.

## Verifying behavior

There are no unit tests. Behavior is verified by running the EA in the MT5 Strategy Tester and
reading three things:

1. **Dashboard `Note` line** (top-left panel) — names the *first unmet condition* (`waiting
   liquidity sweep`, `entry window closed`, `session cap reached`, …). This is the primary
   answer to "why didn't it trade here". **Two functions write it**: `EvaluateAndAct` sets it on
   bar close, and `RefreshDashboardLive` rewrites it every tick — but only when it currently
   matches one of three hard-coded strings (the two "no bias" texts and the Mon/Fri ones). A new
   note string that should stay live must be added to that list too, or it will freeze.
2. **`[SS]`-prefixed journal lines** — every order decision is printed in English
   (`LIMIT PLACED`, `POSITION OPENED`, `LIMIT CANCELLED`, `MARKET ... FAILED: retcode`,
   `SKIPPED (invalid SL / lot size = 0)`, `POSITION CLOSED`). In the tester these land in
   `Tester\...\Agent-127.0.0.1-3000\logs\*.log` — grep `[SS]` there rather than trusting the
   chart alone. `InpDebug=true` adds a per-bar detection trace.
3. **Chart drawings** — swing dots → sweep target → CHoCH/IFVG marks → entry/SL/TP rays show
   exactly what the EA saw.

`InpForcedBias` (BUY/SELL) arms a fixed bias for all sessions — a backtest-only convenience so the
tester can run without visual mode and manual clicks.

### Strategy Tester `.set` files override input defaults

Changing an `input` default in code does **not** change the user's tester runs: MT5 reloads saved
values from `MQL5\Profiles\Tester\*.set|.ini`. To retire a feature, **delete the input and its code
path entirely** (removed inputs are ignored in saved profiles). If only re-tuning a default,
explicitly tell the user to reset that field in the tester Inputs tab.

## Architecture

`SessionsStrategy.mq5` is the orchestrator: it owns all inputs, copies them into one `SSettings`
struct via `BuildSettings()`, holds one global instance of each `Include/` class, and drives
everything from `OnTick()`. The `.mqh` classes are detection and calculation helpers — they never place
orders; **all order placement lives in the main file** (`PlaceOrder`, `OpenMarket`).

### OnTick control flow

```
poll bias buttons (PollClicks)          ← the tester never calls OnChartEvent; clicks are POLLED
session-key change → wipe drawings, reset sweep
ComputeRangeIfNeeded
newBar = IsNewBar()                     ← evaluated ONCE, reused below
if any position open → g_dtp.Manage()   (BE, runner, trail for EVERY open position;
                                         every tick, or newBar only when
                                         manageOnBarClose is set)
CheckClosedPosition / ManagePending     (fill + cancel detection, per slot)
if newBar:
   if pending open              → TrailPendingOnNewBos() only; NO fresh detection
   elif open && !CanOpenAnother → NO fresh detection ("managing position")
   else                         → EvaluateAndAct() + visuals
RefreshDashboardLive()                  (every tick, so the panel stays live while paused)
```

Two invariants drive most of the code:
- **One position at a time — unless it is risk-free.** While a pending CHoCH limit is live, or a
  position still carries real risk, detection and setup drawing stop completely. `addWhenBreakEven`
  (default `false`) is the only thing that relaxes this; see below.
- **Signals confirm on bar close**, but management (BE, runner, trail, dashboard) runs every tick.

### Multi-position mode

Open positions live in `SOpenPos g_open[SS_MAX_OPEN]` (main file) with a matching
`STpTrade m_t[SS_MAX_OPEN]` inside `CDynamicTP` — each position carries its **own** entry, BE flag,
partial flag and trail. There is no "the open position" any more; use the helpers:

| Helper | Answers |
|--------|---------|
| `OpenCount()` | how many slots are active |
| `IsTracked(ticket)` | is this ticket already in a slot (guards the pending-fill fallback) |
| `AllOpenAtBreakEven()` | is every open position's **live** `POSITION_SL` at entry or better |
| `CanOpenAnother()` | the count gate: always true at 0; otherwise needs `addWhenBreakEven`, room under `maxOpenPositions`, and `AllOpenAtBreakEven()` |
| `AddDirectionAllowed(bias)` | the direction gate, evaluated against **every** open position |

`AllOpenAtBreakEven` deliberately reads the broker's SL rather than `CDynamicTP`'s `beDone` flag:
`ManageOne` sets `beDone = true` even when the `PositionModify` was rejected (stops level), so the
flag can claim protection that does not exist. Never "simplify" it to the flag.

Three places assume the slot model and will silently misbehave if you revert one of them: the
`CheckClosedPosition` loop (journals and frees each slot), `OnPositionOpened` (claims a free slot,
warns and bails when full), and the `IsTracked` skip in `ManagePending`'s fallback — without it a
limit fill adopts an older position and double-books it.

### Tick-model sensitivity (why two tester runs disagree)

Entries confirm on bar close and barely move with the tick model. **Exits do.** Every threshold in
`CDynamicTP::Manage` reads `POSITION_PROFIT` — the live price — so the model decides how many
chances BE / partial / cap / trail get per bar: 1 under *Open prices only*, ~8 under *1 min OHLC*,
thousands live. The same XAUUSD range moved PF 1.68 → 1.43 and the average winner 1,857 → 687
between those two models, with the win rate *rising* 54.5% → 62.5% — early BE and partial exits.

- **Live is finer than 1-min OHLC.** Open-prices-only numbers are unreachable; only *Every tick
  based on real ticks* is a reference. README → "Tick model" has the full table.
- `manageOnBarClose` (`InpManageOnBarClose`, default `true`) moves `Manage()` into the `newBar`
  branch to remove most of this sensitivity, at the cost of intrabar BE protection. It is `true`
  by default because the validated backtest ran that way; the trade-off is that BE arms only when
  an M2 bar *opens* past the trigger.
- **Never compare `Total Net Profit` across runs.** `LotForRisk` sizes off the live balance, so
  results compound; compare Profit Factor and Expected Payoff as a % of balance instead.

### Shipped defaults = the validated backtest configuration, plus unvalidated CSV-estimated changes

Most `input` defaults mirror the 602-trade real-tick run this history references most recently
(XAUUSD M2). `defaultTargetPercent = 2.5` / `maxTargetPercent = 5.0` are **unequal on purpose** —
`Manage()` tests the cap at `DynamicTP.mqh` before the partial and the trail, so equal values would
make it always close and return first, before `Momentum()`, `NearestSwing()` and the opposing-CHoCH
exit ever run. Do not set them equal without meaning to disable that path again. `usePartialTP =
true` / `partialPercent = 55` and `addDirection = ADD_DIR_SAME` also reflect that run's actual
tester config, not the earlier "5%/5%, partial off" configuration this file used to describe.

`breakEvenAtPercent = 0.25` with `riskPercent = 0.5` puts break-even at **≈0.5R**. It is a hair
trigger and it dominates the outcome distribution (48% of the 602 trades closed at break-even in
the reference run). Whether it earns its keep was measured directly via counterfactual tracking on
an earlier run and came out net positive — see the trade analytics CSV section below.

`useLondon = false` — the London session has never been backtested.

**Three settings below are analysis-driven but NOT yet validated by a real Strategy Tester run —
only estimated from replaying the 602-trade CSV export (`mae_r`/`mfe_r`/`net_r` columns), which
lacks intrabar path data:**

- `entryWindowMinutes = 30` (narrowed from 120) — trades entered >30min after session open were
  statistically indistinguishable from break-even in the export (Welch p=0.0175); before 30min,
  expectancy was +0.545R vs +0.006R after.
- `maxSlAtrRatio = 2.5` (new gate, `PlaceOrder` in the main file) — rejects an entry before sizing
  if the SL distance versus current ATR exceeds this ratio. Wide-SL trades were net negative as a
  group (Welch p=0.0099).
- `useRatchet = true`, `ratchetTriggerR = 2.0`, `ratchetLockFrac = 0.5` (new mechanism,
  `CDynamicTP::ManageOne`) — once a position's peak profit clears `ratchetTriggerR` × the trade's
  own risk money, the SL ratchets to `ratchetLockFrac` of that peak, one-way, before the rule-14
  gate. Motivated by 99 trades reaching mfe_r ≥ 3 of which 40 gave the entire move back to
  break-even (+831R total giveback across trades with mfe_r ≥ 0.3, against +73.9R net profit on
  that export). The simulated uplift is an **optimistic upper bound** — it assumes the mechanism
  always captures exactly the locked fraction of the peak regardless of intrabar timing. Treat the
  first live tester run with it enabled as the real measurement.

A rejected trade under `maxSlAtrRatio` prints `[SS] SKIPPED ... SL/ATR ... exceeds max` and does
not set the dashboard `Note` (consistent with the other pre-existing SKIPPED paths).

Changing an `input` default does **not** change the user's tester runs; see the `.set` note above.

### Module responsibilities

| File | Owns |
|------|------|
| `Common.mqh` | All enums, `SSettings` (every tunable), `SStratState` (dashboard feed), and the Riyadh↔server time helpers (`ToRiyadh` / `FromRiyadh` / `RiyadhMinuteOfDay`). |
| `SessionManager.mqh` | Riyadh-time session windows (Asia / London / NY), the entry-window gate, `SessionKey()` (the string that resets per-session state), prior-day 4H range computation. |
| `BiasPanel.mqh` | BUY/SELL/NONE buttons. Selection is shown by **colour** and button state is kept un-pressed, so `PollClicks()` can read a fresh press unambiguously. |
| `Liquidity.mqh` | Swing detection (`IsSwingHigh` / `IsSwingLow`, free functions reused elsewhere), the trailing sweep target, and the latched sweep state + `SweepExtreme()`. |
| `Vwap.mqh` | Anchored VWAP (Pine port: `hlc3`, daily reset at the Riyadh day-close hour, `tick_volume` fallback). Pure computation — `AnchorStart` / `Series` / `ValueAt`; the auto-bias decision itself lives in the main file. |
| `EntryModels.mqh` | `CheckCHoCH` / `CheckIFVG` / `CheckEntry`, FVG collection, plus the three window setters that constrain detection (below). |
| `RiskManager.mqh` | Lot sizing from % risk, %-of-capital ↔ price conversions, and per-session trade caps keyed on `SessionKey`. See **Risk sizing** below. |
| `DynamicTP.mqh` | Post-entry lifecycle: BE at +2%, partial at +4%, structure trail, opposing-CHoCH exit, +10% cap. |
| `Visuals.mqh` / `Dashboard.mqh` | All chart objects. Names are prefixed and cleared per session. |
| `TradeAnalytics.mqh` | Per-trade research export (`SessionsStrategy_Trades_<symbol>.csv`). **Measurement only — never gates a decision.** Owns `STradeRecord`, the excursion sampler, the counterfactual watcher and the CSV writer. |
| `TradeJournal.mqh` | Styled Excel XML report at `<AppData>/MetaQuotes/Terminal/Common/Files/SessionsStrategy_Report_<symbol>.xls`. Buffered in memory and written once in `OnDeinit`; a tester run starts it fresh. Default OFF — the analytics CSV supersedes it. |

### Sessions

Three windows, all in Riyadh time: **Asia 03:00–06:00**, **London 09:00–12:00**, **NY 15:00–18:00**.
London is **not in the charter** — it is an addition gated by `useLondon` (`InpUseLondon`, default
`false`); when false, `CurrentSession()` never returns `SESSION_LONDON` and the session is invisible
to the rest of the EA. Asia and NY have no such switch. **London has never been backtested** — the
validated run is Asia + NY only.

Adding or changing a session touches exactly three things: the `ENUM_SESSION` value, the ordered
checks in `CSessionManager::CurrentSession`, and the `StartMinOf` / `EndMinOf` pair every other
window query (`InEntryWindow`, `SessionStartServer`, `SessionEndServer`) routes through. Session
*names* come from one place too — `SessionName()` in `Common.mqh`, which feeds `SessionKey()`, the
journal's session column, the dashboard, the auto-bias log line and the box label. Never re-inline a
`(ses==SESSION_ASIA)?"ASIA":"NY"` ternary; a missed one silently mislabels a session as NY.

Overlapping windows are resolved by check order, not rejected — Asia wins over London, London over
NY. Keep them disjoint.

### Risk sizing (everything downstream is MONEY; `riskMode` picks the unit)

`riskMode` (`InpRiskMode`, default `RISK_MODE_PERCENT`) switches **sizing and every target
threshold together** between % of balance and a fixed money amount. Each setting is a pair —
`riskPercent`/`riskMoney`, `breakEvenAtPercent`/`breakEvenAtMoney`,
`defaultTargetPercent`/`defaultTargetMoney`, `maxTargetPercent`/`maxTargetMoney` — and the inactive
half is ignored.

**Never read those fields directly.** Four `CRiskManager` accessors are the only code that knows
which unit is live, and everything else (lot sizing, the TP price, all three `DynamicTP` gates)
works in money:

| Accessor | Replaces |
|----------|----------|
| `RiskMoney()` | `CapitalRef()*riskPercent/100` inside `LotForRisk` |
| `BreakEvenMoney()` | the old `pct >= breakEvenAtPercent` test |
| `DefaultTargetMoney()` | the old `pct < defaultTargetPercent` test |
| `MaxTargetMoney()` | the old `pct >= maxTargetPercent` test |
| `PriceForMoney(money, lots, …)` | the old `PriceForPercent(pct, lots, …)` |

`FloatPercent()` survives for display and journal lines only — it is not a control path.

The two units are deliberately coupled: fixed-money sizing with percent-of-balance targets would
make the reward-to-risk ratio drift as the balance compounds (10:1 at 100k, 50:1 at 500k). Do not
"improve" this by letting them be set independently.

`CRiskManager` converts money ↔ price through the broker's own `OrderCalcProfit`
(`LossPerLot`, `ValuePerLotPerPrice`), **never** manual `tickValue / tickSize` math: some brokers
report `SYMBOL_TRADE_TICK_VALUE` in scaled units, which inflated lots ~100× and turned 0.95% risk
into ~95% (fixed in `87807eb`). Do not "simplify" it back.

`LotForRisk` rounds **down** to the volume step and returns **0** — refusing the trade — when even
`SYMBOL_VOLUME_MIN` would over-risk. That is the source of the `SKIPPED … lot size = 0` journal
line; it is intended behavior, not a bug to paper over.

### Detection windowing (the subtlest part)

`CEntryModels` has three independent time constraints that must all be set before a check. Mixing
them up is the usual source of "it detected a pattern it shouldn't have":

- `SetWindow(from)` — outer scan bound: session start minus `detectPreHours`. Pre-session bars are
  visible as **confirmation neighbours only**.
- `SetSessionStart(t)` — the pattern's **core** (the broken swing for CHoCH, the gap displacement
  candle for IFVG) must be in-session.
- `SetNotBefore(t)` — set to `g_liq.TargetTime()`; IFVG zones may not pre-date the swept level's own
  bar, so only the sweeping leg or later can trigger.

The two swing strengths are deliberately different: `swingStrength` (default 2) finds the sweep
target; `chochSwing` (default 1) finds the CHoCH reaction high/low, because off a sharp sweep an
N=2 swing often never confirms before the break.

### Bias source

`BiasMode = VWAP` (default) decides the session direction in `UpdateAutoBias()`: the **open of the
session's first bar** vs the VWAP **carried into the session** (bars strictly before that bar, so
the opening bar cannot move its own reference). Above → BUY, below → SELL, equal → NONE.

- The decision is **latched per `SessionKey`** — it runs once, and a later panel click therefore
  overrides it for the rest of that session. Leaving a session disarms back to NONE.
- Precedence is `ForcedBias` → auto-bias → panel. A non-NONE `ForcedBias` **disables** the
  auto-bias; `OnInit` alerts about it, because a saved `.set` can silently keep an old value.
- `UpdateVwap()` runs immediately before it in the same new-bar block, so `g_vwapNow` and the drawn
  curve are current when the decision is made. The VWAP curve is drawn **incrementally** (one
  segment per closed bar) and is the one drawing `ClearSessionDrawings()` deliberately skips — it
  is anchored to the day, not the session, and is cleared by `ClearVwap()` on anchor rollover.

### Entry paths

- **CHoCH** → pending LIMIT at `chochEntryRetrace` (25%) of the breaking leg. While unfilled it
  **trails on new BOS**: the order always sits on the *second-newest* BOS
  (`TrailPendingOnNewBos`). It waits on its BOS indefinitely — there is deliberately no time-based
  market fallback — and is cancelled only by a newer BOS, a bias change, or the entry window closing.
- **IFVG** → immediate market entry, and it **supersedes an unfilled CHoCH limit** (charter: "first
  valid trigger after the sweep wins"). On a same-bar tie under `ENTRY_EITHER`, IFVG wins.
- **LIMIT silently degrades to MARKET.** `PlaceOrder` checks the retrace level against the live
  ask/bid and, if price is already past it, opens at market instead (printing `price already
  beyond the retrace level … -> MARKET entry`). The BOS-trailing re-place path relies on this, so
  a "CHoCH" trade in the journal is not proof a limit was ever working.
- **SL anchor** defaults to the entry pattern's own leg extreme (`SL_ANCHOR_CHOCH_LEG`), not the
  sweep wick — a session-open spike can sit far from the actual setup. `SL_ANCHOR_SWEEP_WICK`
  restores the session-extreme behavior.

### Charter rules intentionally NOT enforced in code

- **Rule 2** (price must exit the prior-day 4H range): the box is **drawn for reference only**,
  confined to its own 4 hours. The breakout check is the trader's manual job — arming a bias starts
  the hunt immediately. Do not re-add it as an entry gate.
- **Rule 17** (session direction) is automated by the VWAP rule above by default; `BiasMode =
  MANUAL` restores the charter's letter. This is an approved deviation — do not "fix" it back.
- **Rules 16 & 18** are reporting conventions, not execution logic.

`CSessionManager::AsiaRangeExited`, `EntryWindowEndServer` and `SessionEndServer` are the leftovers
of that decision — correct, complete, and deliberately **never called**. Leave them; wiring
`AsiaRangeExited` back into `EvaluateAndAct` is exactly the re-added rule-2 gate above.

## Trade analytics export

`Include/TradeAnalytics.mqh` writes one CSV row per closed position. Three things about it are
deliberate and easy to break:

- **Excursion is folded from completed-bar highs/lows**, not sampled from ticks, so MAE/MFE is
  identical under every tick model — the one part of this EA's output that is model-independent.
  `SampleExcursions` also takes a per-tick mark sample, but only to cover the partial entry and
  exit bars. The **open bar is skipped** for bar folding: its extremes predate the entry.
- **Both journals buffer and write once in `OnDeinit`.** `CTradeJournal` used to rebuild the whole
  `.xls` on every close, which dominated runtime. Buffering also lets the CSV emit rows in *open*
  order while the counterfactual watcher resolves them out of order (`Flush` insertion-sorts on
  `trade_no`). Positions still open at the end are submitted with `EXIT_END_OF_TEST`.
- **`trade_no` is a global counter (`g_tradeSeq`)**, never `g_risk.Trades()` — that one resets on
  every `SessionKey` change and would emit duplicate ids.

`ClassifyExit` splits a broker SL fill into `STOP_LOSS` / `BREAK_EVEN` / `TRAIL_STOP` by comparing
`finalSL` against the initial stop and the entry; EA-initiated closes read the reason `CDynamicTP`
stamped via `Stamp()` just before calling `PositionClose`. Adding a new EA close path means adding
a `Stamp()` call, or the row silently reports `UNKNOWN`.

`beApplied` (not `beDone`) is what the CSV reports: `beDone` is set even when the broker rejected
the modify. `SampleExcursions` pulls it live each tick so `mfe_before_be` freezes at the right
moment.

**Optimization is not wired up yet.** Parallel tester agents cannot share a file, so per-pass output
needs `OnTester` + `FrameAdd`/`OnTesterPass`. Until that exists, do not add direct file writes to
any optimization path.

## Conventions

- Everything is **English** — code, comments, journal lines, alerts, dashboard text, and replies to
  the user.
- Every order path prints an `[SS]` line on both success and failure, and raises an `Alert()` for
  opens and failures. The user debugs from these, so keep new paths instrumented the same way.
- A new tunable means three edits: a field in `SSettings` (`Common.mqh`), an `input` in the main
  file, and a line in `BuildSettings()` — plus a row in the README input table.

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
if position open  → g_dtp.Manage()      (every tick: BE, runner, trail)
CheckClosedPosition / ManagePending     (fill + cancel detection)
if new bar:
   if position OR pending open → TrailPendingOnNewBos() only; NO fresh detection
   else                        → EvaluateAndAct() + visuals
RefreshDashboardLive()                  (every tick, so the panel stays live while paused)
```

Two invariants drive most of the code:
- **One position at a time.** While a trade or a pending CHoCH limit is live, detection and setup
  drawing stop completely.
- **Signals confirm on bar close**, but management (BE, runner, trail, dashboard) runs every tick.

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
| `TradeJournal.mqh` | Styled Excel XML report at `<AppData>/MetaQuotes/Terminal/Common/Files/SessionsStrategy_Report_<symbol>.xls`. Rebuilt in full after each close; a tester run starts it fresh. |

### Sessions

Three windows, all in Riyadh time: **Asia 03:00–06:00**, **London 09:00–12:00**, **NY 15:00–18:00**.
London is **not in the charter** — it is an addition gated by `useLondon` (`InpUseLondon`, default
`true`); when false, `CurrentSession()` never returns `SESSION_LONDON` and the session is invisible
to the rest of the EA. Asia and NY have no such switch.

Adding or changing a session touches exactly three things: the `ENUM_SESSION` value, the ordered
checks in `CSessionManager::CurrentSession`, and the `StartMinOf` / `EndMinOf` pair every other
window query (`InEntryWindow`, `SessionStartServer`, `SessionEndServer`) routes through. Session
*names* come from one place too — `SessionName()` in `Common.mqh`, which feeds `SessionKey()`, the
journal's session column, the dashboard, the auto-bias log line and the box label. Never re-inline a
`(ses==SESSION_ASIA)?"ASIA":"NY"` ternary; a missed one silently mislabels a session as NY.

Overlapping windows are resolved by check order, not rejected — Asia wins over London, London over
NY. Keep them disjoint.

### Risk sizing (every % in this EA is % of account balance)

`breakEvenAtPercent`, `defaultTargetPercent` and `maxTargetPercent` are **percentages of
`AccountInfoDouble(ACCOUNT_BALANCE)`**, not R-multiples — which is why the TP price comes from
`PriceForPercent(maxTargetPercent, lots, …)` and `DynamicTP` gates on `rm.FloatPercent(profit)`.

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

## Conventions

- Everything in code and logs is **English** — comments, journal lines, alerts, dashboard text. The
  user communicates in **Arabic**; reply in Arabic.
- Every order path prints an `[SS]` line on both success and failure, and raises an `Alert()` for
  opens and failures. The user debugs from these, so keep new paths instrumented the same way.
- A new tunable means three edits: a field in `SSettings` (`Common.mqh`), an `input` in the main
  file, and a line in `BuildSettings()` — plus a row in the README input table.

# Sessions Strategy EA (MQL5)

A session-based, discretionary-bias Expert Advisor for MetaTrader 5, for **XAUUSD (Gold)**,
trading primarily on the **M2** timeframe. **You** set the directional bias at the start of each
session from your own analysis; the EA enforces every mechanical rule of the trading charter
(entry model, timing window, liquidity sweep, risk, trade caps, break-even, and a **dynamic
momentum-aware take-profit**) on top of that bias.

> This README is the **specification / design document**. No code is written yet. Review it,
> correct anything that's off, and once you approve, implementation begins.

---

## 1. Strategy in one paragraph

Trade only during two approved sessions (**Riyadh local time, GMT+3**). At each session open you
click a bias button (**BUY / SELL / NONE**). The EA then waits for price to **sweep the nearest
opposing liquidity** — for a buy, price simply trades **below** a prior low; for a sell, **above**
a prior high (just taking the level is enough). After the sweep, it requires a **CHoCH**
(close-confirmed) or an **IFVG** reaction as the entry trigger. If that confirmation appears
within a **configurable entry window** (default 90 min) from the session open, it opens a
position sized to a fixed **0.95% risk**, with stop **at the sweep wick**. The **default target
is 4%**; from there the exit is managed **dynamically** — the trade can extend toward the nearest
structural high/low, up to a **10% cap**, while momentum supports continuation. Stop moves to
break-even at **+2%**, and the EA never auto-closes before **+4%**. Per session: **stop after the
first win**, otherwise up to **two** trades; the next session (same day or next day) starts fresh.

---

## 2. Resolved configuration (your decisions)

| Topic | Decision |
|-------|----------|
| **Timeframe** | Primarily **M2** (configurable). |
| **Timezone** | Sessions in **Riyadh local time (GMT+3, no DST)**; converted from broker server time via offset. |
| **Bias input** | **On-chart BUY / SELL / NONE buttons.** Default `NONE`. |
| **Entry confirmation** | **CHoCH** (close-confirmed break) → **pending LIMIT at 25% retrace of the breaking leg**; **IFVG** secondary → market entry. First valid trigger after the sweep wins. |
| **Entry window** | **Configurable minutes** from session open (default 90). |
| **Sweep** | Price simply **takes the level** (trades beyond the prior high/low). No close-back-inside required — the *entry model* provides the reversal confirmation. |
| **Default target** | **4%** by default, regardless of structure. Extension beyond 4% is decided by nearest high/low + momentum, capped at 10%. |
| **Stop loss** | **At the entry pattern's own leg extreme** by default (`SLAnchor`): CHoCH → the breaking-leg extreme; IFVG → the extreme of the reclaim leg since the zone formed. The `SWEEP_WICK` option anchors at the session extreme instead. Optional small buffer. |
| **Session caps** | Stop after **1 win**; otherwise up to **2** trades. No daily cap — next session continues normally, same day or next. |
| **Rule 14** | EA simply never auto-closes before +4% (no manual-block logic). |
| **TP > 10%** | Cap at 10%, always trade if valid. |
| **Symbol** | **XAUUSD (Gold) only.** |

---

## 3. The Charter — rule-by-rule mapping

| # | Rule (charter) | EA implementation |
|---|----------------|-------------------|
| 1 | **Approved sessions** — Asia 03:00–06:00, NY 15:00–18:00 | Two windows in **Riyadh time**. |
| 2 | **Asia condition** — price must exit the prior 4-hour range | The range = High/Low of the **last 4 hours of the previous day** (the 4h ending at the day's close). Before an Asia entry, price must have traded **outside** that range. |
| 3 | **Entry timing** — only within the first ~1.5 hours | Hard gate via input `EntryWindowMinutes` (default 90). No entry after. |
| 4 | **Sell** — sweep prior **highs** first | SELL requires price to trade **above** the nearest prior swing high. |
| 5 | **Buy** — sweep prior **lows** first | BUY requires price to trade **below** the nearest prior swing low. |
| 6 | **Entry model** — IFVG or clear BOS, candle close | **CHoCH**: break confirmed on candle close, then a **pending LIMIT at 25% retrace of the breaking leg** (no chasing a long break bar). **IFVG**: market entry on the close-confirmed reclaim. |
| 7 | **Protection** — at **+2%**, SL → entry | Floating-gain monitor moves SL to break-even. |
| 8 | **Target** — prior high/low, clear reading | Default 4%; **dynamic engine** (Section 6) extends to structural levels by momentum, 10% cap. |
| 9 | **Risk** — fixed **0.95%** of capital | Lot size = 0.95% equity ÷ (entry-to-SL distance). |
| 10 | **Trades/session** — max **2** (losing) / **1** (winning) | Stop after **1 win**; otherwise up to **2**, then stop for that session. |
| 11 | **Max RR** — target ≤ **10%** | Hard 10% cap on the runner. |
| 12 | **Min RR** — target ≥ **4%** | **Default target is 4%**, so every trade meets the minimum by construction. |
| 13 | **Stop after target hit** — no more trades | TP hit → session locked. |
| 14 | **No early close** — not before **+4%** | EA never auto-closes before +4%. |
| 15 | **Don't skip valid setups** | EA auto-takes every qualifying setup. |
| 16 | **Notion/TradingView documentation** | Out of EA scope; optional CSV journal. |
| 17 | **Session direction** — trader's own analysis | **You** input bias each session. |
| 18 | **Profit accounting** — `total % × 2` | Reporting convention in journal; not used in execution. |

---

## 4. Key concepts (algorithmic definitions)

### 4.1 Liquidity Sweep (rules 4 & 5) — trailing target
- **Swing high/low** = candle whose high/low exceeds `SwingStrength` (N) candles on each side (default N=2).
- The *level to be swept* = the **most recent confirmed swing low** (for a BUY) / **swing high**
  (for a SELL). It is chosen from a window reaching back `PreSweepHours` (default 8h) before the
  session open, so at the open it is the nearest pre-session low/high, and it **trails continuously**
  to each newer swing as price prints lower lows / higher highs. Drawn as `low to sweep` (gold).
- **Sweep is MET** the moment a more-recent in-session bar trades **beyond** the marked level
  (a swing low's right-side bars are higher by definition, so a later bar below it is a genuine
  downward sweep — no "was it above first" gate needed). It **latches** for the session and the
  label flips to `low SWEPT` (khaki).
- **SL anchor** = the session's extreme (lowest low for a buy / highest high for a sell).
- **Detection of CHoCH / IFVG / FVG / swings** uses **only in-session bars** (the reversal happens
  inside the session); only the *sweep target* reaches back before the open.
- **One position at a time**: while a trade or a pending CHoCH limit is live, the EA **stops all
  detection and setup drawing** and only manages the open position.

### 4.2 Asia previous-day 4h range (rule 2)
- Computed once per day: **High/Low of the last 4 hours of the previous day**, i.e. the 4-hour window ending at the configured day-close time (`DayCloseHourRiyadh`).
- An Asia-session entry is allowed only after price has traded **outside** that High/Low.

### 4.3 CHoCH — Change of Character (primary trigger, LIMIT entry)
- The first structural break against the short-term micro-trend after the sweep.
- **Uses its own swing strength `ChochSwing` (default 1)**, *not* the sweep's `SwingStrength`.
  Reason: off a sharp sweep, price often breaks the reaction high within ~1 bar, so an N=2 swing
  never gets confirmed and the break is missed (the EA would otherwise only fire on a later, bigger
  break — sometimes after the entry window). N=1 recognises the fast reaction-high break.
- BUY: after sweeping a low, price **closes** above the most recent minor lower-high → CHoCH up.
- SELL: after sweeping a high, price **closes** below the most recent minor higher-low → CHoCH down.
- **The break is close-confirmed** (M2 by default), but the **entry is NOT taken at that close**.
  Because the candle/leg that breaks structure can be very long, entering at its close gives a
  poor price and an oversized stop. Instead the EA places a **pending LIMIT order at a
  retracement of the breaking leg**:
  - Breaking leg = from the leg's low to its high over the bars that produced the break.
  - `range = legHi − legLo`.
  - **BUY limit** = `legHi − ChochRetrace × range`  (default `ChochRetrace = 0.25` → 25% pullback).
  - **SELL limit** = `legLo + ChochRetrace × range`.
  - Order **expires at the end of the entry window** (rule 3); if unfilled it is cancelled. If
    price has already retraced past the level by the time of the signal, the EA falls back to a
    market entry at current price.
  - Stop loss still sits at the **sweep wick**; lot size is computed from the limit price → SL.

### 4.4 IFVG — Inverse Fair Value Gap (secondary trigger)
- A **FVG** is a 3-candle imbalance; an **IFVG** forms when an existing FVG is traded through and closed beyond (invalidated), flipping into opposite S/R. Entry on a close-confirmed reaction from the inverted zone. First valid trigger after the sweep wins.

### 4.5 Entry sequence (per session)
```
1. Session open → bias set (BUY/SELL)?                ──no──► idle
2. (Asia only) price exited prior-day last-4h range?  ──no──► wait
3. Within EntryWindowMinutes of open?                 ──no──► lock session
4. Nearest opposing high/low taken (sweep)?           ──no──► wait
5. CHoCH or IFVG fires on candle close?               ──no──► wait
6a. CHoCH → place LIMIT at 25% retrace of breaking leg (expires at window end)
6b. IFVG  → enter at market
7. On fill → size 0.95% risk, SL at wick, TP cap 10%, arm dynamic runner
```
There is **no "structural target ≥ 4%" gate** — the default target is always 4%; structure only
governs whether to extend *beyond* 4%.

---

## 5. Risk & sizing

- **Sizing**: lots = `(Equity × 0.95%) / (|entry − SL| × tickValue)`. Never exceeds 0.95%.
- **Stop loss** (`SLAnchor`): default **entry-pattern leg** — the extreme of the leg that
  produced the entry, plus optional `SLBufferPoints`:
  - **CHoCH** → the breaking-leg extreme (below the leg low for a buy / above the leg high
    for a sell).
  - **IFVG** → the extreme of the reclaim leg, i.e. the highest high (sell) / lowest low (buy)
    since the inverted zone formed — the wick that poked the zone, not a distant session spike.
  This keeps the stop tight behind the actual setup instead of at a sweep flush / session-open
  spike that can sit much deeper. The `SWEEP_WICK` option restores the old behavior (session
  extreme of the sweeping leg).
- **Break-even**: +2% floating gain → SL to entry (rule 7).
- **Session cap**: stop after 1 winner; else up to 2 trades; TP hit → session locked. Next session starts fresh (same or next day).

---

## 6. Dynamic Take-Profit Engine ⭐

**Default target is 4%. Beyond that, ride toward the nearest high/low — or to the 10% cap — while
momentum says the move continues.**

### 6.1 Principle
- The trade carries a hard SL (at the wick) and a hard safety cap at **+10%** (rule 11).
- **4% is the default objective**, not a structural calculation — every valid setup targets at least 4%.
- Between 4% and 10%, the exit is decided by **structure + momentum**, so strong moves aren't cut short and weak ones aren't given back.

### 6.2 Lifecycle of a trade
```
+0%  → entry. SL at wick. Default TP target = +4%. Hard cap = +10%.
+2%  → SL moved to break-even (rule 7).
+4%  → DEFAULT TARGET reached. Decision point:
        ├─ Momentum WEAK / nearest structure right here → take the 4% (optionally
        │   close `PartialPercent` and trail the rest).
        └─ otherwise → don't close; trail SL behind the last swing and ride toward 10%.
4%→10% → RUNNER. Rides the structure trail toward the 10% cap.
         The ONLY early exit is a genuine reversal (opposing CHoCH). A stall or a
         single opposite candle does NOT close it — the trailing stop handles those.
+10% → hard cap. Close remainder (rule 11).
```

### 6.3 Runner exit rules (let winners run)
After +4% the position **rides the structure trail toward the +10% cap**. It is closed early
**only** by a genuine close-confirmed **opposing CHoCH** (a real structure reversal against the
trade). It is **not** closed by a stall, by ATR contraction, or by a single opposite candle — those
were closing trades prematurely. Profit is protected instead by:
- the **structure trailing stop** (Section 6.4), and
- **break-even** at +2%, and
- the hard **+10%** cap.

`MomentumBodyATR` / `MomentumStallBars` are still used to classify a bar as STRONG (displacement +
new extreme) for future tuning, but a non-strong bar no longer forces an exit.

### 6.4 The structure trail
While the runner is open, SL trails just beyond the most recent confirmed swing in the trade
direction, padded by `TrailPadPoints`. This banks most of an extended move even if it reverses
before 10%, and is what actually takes a trade out when momentum fades (rather than a hard close).

### 6.5 Charter compliance
- **Never closes before 4%** (rule 14): the runner and partials only activate at/after +4%; before that the trail never sits below break-even.
- **Min 4% / Max 10%** (rules 11, 12): default target is 4%; hard cap is 10%.
- **Target = prior high/low** (rule 8): every *extension* target is a real structural swing; momentum only decides whether to hold to the next one.

### 6.6 Tunable behavior
- `UsePartialTP` (default **true**) + `PartialPercent` (default **50%**): close part at +4% to lock the minimum, ride the rest on the trail. Set `false` to ride the full position.

---

## 7. Proposed inputs (parameters)

| Group | Input | Default | Notes |
|-------|-------|---------|-------|
| General | `WorkingTimeframe` | M2 | Primary analysis TF |
| Sessions | `AsiaStart` / `AsiaEnd` | 03:00 / 06:00 | Riyadh time |
| Sessions | `NYStart` / `NYEnd` | 15:00 / 18:00 | Riyadh time |
| Sessions | `BrokerToRiyadhOffsetHours` | TBD | Server → Riyadh |
| Asia | `DayCloseHourRiyadh` | 00:00 | Anchor for prior-day last-4h range |
| Asia | `RangeLengthHours` | 4 | Rule 2 |
| Timing | `EntryWindowMinutes` | 90 | Rule 3 (configurable) |
| Structure | `SwingStrength` (N) | 2 | Sweep-target swing detection |
| Structure | `ChochSwing` (N) | 1 | CHoCH reaction-high/low detection (smaller = catches faster breaks) |
| Entry | `EntryModel` | CHoCH-first | CHoCH / IFVG / either |
| Entry | `ChochRetrace` | 0.25 | Limit at 25% retrace of breaking leg |
| Entry | `PreSweepHours` | 8.0 | Hours left of session open to find the low/high to sweep |
| Risk | `RiskPercent` | 0.95 | Rule 9 |
| Risk | `SLAnchor` | CHoCH leg | SL at breaking-leg extreme (CHoCH) or sweep wick |
| Risk | `SLBufferPoints` | 0 | Pad beyond anchor |
| Risk | `BreakEvenAtPercent` | 2.0 | Rule 7 |
| TP | `DefaultTargetPercent` | 4.0 | Rule 12 default |
| TP | `MaxTargetPercent` | 10.0 | Rule 11 cap |
| TP | `UsePartialTP` | true | Section 6.6 |
| TP | `PartialPercent` | 50 | Closed at +4% |
| TP | `MomentumBodyATR` | 1.3 | Displacement |
| TP | `MomentumStallBars` | 3 | Stall/progress window |
| TP | `AtrContractionFactor` | 0.6 | Exhaustion |
| TP | `TrailPadPoints` | broker-tuned | Structure-trail pad |
| Caps | `MaxTradesPerSession` | 2 | Rule 10 |
| Caps | `StopAfterFirstWin` | true | Rule 10 |
| Logging | `WriteTradeJournalCSV` | true | Rule 16 helper |
| Logging | `Debug` | false | Per-bar detection trace to the Experts log |
| Visuals | `ShowVisuals` | true | Range/session boxes |
| Visuals | `ShowSignals` | true | Sweep / CHoCH / IFVG / trade levels |
| Visuals | `ColorRange / Asia / NY` | gold / blue / red | Box colors |
| Visuals | `ColorChoch / Ifvg / Sweep` | aqua / orchid / khaki | Signal colors |
| Visuals | `ShowSwings` | true | Detected swing-high/low dots |
| Visuals | `ColorSwingHi / Lo` | tomato / green | Swing dot colors |
| Visuals | `SwingDrawLookback` | 300 | Bars scanned for swing dots |
| Visuals | `ShowFVGs` | true | Live FVG / IFVG zones |
| Visuals | `ColorFvg` | slate gray | Non-inverted FVG zone (IFVG uses orchid) |
| Visuals | `MaxFVGs` | 8 | Max live FVG zones shown |
| Visuals | `ShowDashboard` | true | On-chart status panel |

### Chart legend (what gets drawn)
- **Dashboard panel** (top-left) — live state: bias, session, entry window, 4H range + values,
  sweep met?, entry model met?, trade count/caps, position P/L, and a "what's blocking" note.
- **Prev-Day 4H** (gold, **outline only**) — the rule-2 range with dotted high/low rays.
- **ASIA / NY boxes** (blue / red, **outline only**) — developing session high–low (no fill, so it no longer covers the candles).
- **Swing dots** (tomato highs / green lows) — the structure skeleton.
- **Sweep target** (gold `low to sweep` → khaki `low SWEPT`) — the single marked level, trailing to the newest swing.
- **Newest FVG / IFVG** (gray = FVG, orchid = inverted IFVG) — only the **most recent** zone is shown.
- **CHoCH watch line** (aqua) — the swing level a CHoCH would break next.
- **CHoCH signal** (aqua) — only the **newest** breaking leg + broken level + limit line.
- **Trade** — entry (silver), SL (red), TP (green) rays + an up/down arrow at the fill.

> **Debugging "no trades":** read the dashboard **Note** line — it names the first unmet condition
> (e.g. *waiting liquidity sweep*, *Asia: range not exited yet*, *entry window closed*). That tells
> you exactly which gate is stopping entries.

---

## 8. Planned file structure

```
Sessions_Strategy/
├── README.md                     ← this document
├── SessionsStrategy.mq5          ← main EA
├── Include/
│   ├── SessionManager.mqh        ← session windows, Riyadh TZ, timing gate
│   ├── BiasPanel.mqh             ← on-chart BUY/SELL/NONE buttons
│   ├── Liquidity.mqh             ← swing detection, sweep, prior-day 4h range
│   ├── EntryModels.mqh           ← CHoCH + IFVG detection
│   ├── DynamicTP.mqh             ← momentum/structure runner (Section 6)
│   ├── RiskManager.mqh           ← sizing, BE, trade caps
│   ├── Visuals.mqh               ← draws prior-day & session range boxes
│   └── TradeJournal.mqh          ← CSV logging
└── docs/
    └── charter_ar.md             ← original Arabic charter (reference)
```

---

## 9. Out of scope / assumptions

- **Notion / TradingView documentation (rule 16)** is manual; EA provides only a CSV journal.
- **Profit ×2 (rule 18)** is an accounting convention in the journal, not used in execution.
- **Direction (rule 17)** is always your manual input.
- One symbol per chart instance — **XAUUSD**.

---

## 10. Install & Backtest

### A. Install
1. In MetaTrader 5: **File → Open Data Folder**. This opens `…/MQL5/`.
2. Copy the whole project into **`MQL5/Experts/SessionsStrategy/`** so it looks like:
   ```
   MQL5/Experts/SessionsStrategy/
   ├── SessionsStrategy.mq5
   └── Include/   (all the .mqh files)
   ```
   The `#include "Include/…"` paths are relative, so the `Include` folder **must** sit next to the `.mq5`.
3. Open **MetaEditor** (in MT5 press **F4**), open `SessionsStrategy.mq5`, press **F7** to compile.
   Expect `0 errors`. This produces `SessionsStrategy.ex5`.
4. Back in MT5, refresh the **Navigator** (right-click → Refresh). The EA appears under
   *Expert Advisors → SessionsStrategy*.

### B. Set the timezone offset (do this once — it's critical)
Sessions are in **Riyadh time (GMT+3)**. The EA needs your broker's **server-time → Riyadh** offset:
- Look at the server clock in **Market Watch** (top of the symbol list) vs the actual Riyadh time.
- `BrokerToRiyadhHr = Riyadh_hour − Server_hour`.
  - Server is **GMT+3** → offset **0**
  - Server is **GMT+2** → offset **1**
  - Server is **GMT** → offset **3**
- **Verify visually:** on an M2 XAUUSD chart the **ASIA box must start at 03:00** and **NY at 15:00**
  Riyadh time. If the boxes are shifted, adjust the offset until they line up.

### C. Backtest in the Strategy Tester
1. Open the tester: **View → Strategy Tester** (Ctrl+R).
2. Settings:
   - **Expert:** `SessionsStrategy`
   - **Symbol:** your broker's **Gold** symbol (often `XAUUSD`, sometimes `GOLD`, `XAUUSD.r`, …)
   - **Period (chart TF):** `M2` (the EA works on M2; matching the chart makes the visuals line up)
   - **Modelling:** **Every tick based on real ticks** (M2 entries need tick precision)
   - **Date range:** pick a week or two to start
   - **Visual mode:** see the two modes below
3. Set inputs (gear/Inputs tab): at minimum `BrokerToRiyadhHr`. Leave the rest at defaults.
4. **Start**.

**Two ways to run it:**

| Mode | How | Use for |
|------|-----|---------|
| **Realistic (discretionary)** | **Visual mode ON.** Leave `ForcedBias = NONE`. When a session opens, click **BUY/SELL** on the panel. Clicks are detected by **polling the button state every tick** (the tester does *not* call `OnChartEvent`), so a click registers on the next tick — pausing, clicking, then resuming also works. | Reproducing how you'll actually trade it. |
| **Fast (mechanical)** | **Visual mode OFF.** Set **`ForcedBias = BUY`** (or `SELL`). The EA arms that bias for every session automatically. | Quickly checking the entry/risk/TP engine over long ranges, one direction at a time. |

> `ForcedBias` is a **backtest-only** convenience — it applies one fixed direction to all sessions.
> Leave it `NONE` for live trading and use the panel.

### D. Read the results
- **Visual chart:** swing dots → sweep level → CHoCH/IFVG marks → entry/SL/TP arrows show exactly
  what the EA did (Section 7 legend).
- **Journal CSV:** `MQL5/Files/SessionsStrategy_<symbol>.csv` — every open/close with profit %, and
  the rule-18 `×2` column.
- **Tester → Journal tab:** prints each limit placement / order error if something is rejected.

### E. Common gotchas
- **Wrong Gold symbol name** → "unknown symbol"/no trades. Use the exact name from Market Watch.
- **Boxes at the wrong hours** → fix `BrokerToRiyadhHr` (Step B).
- **No trades** → bias not armed (panel still `NONE` and `ForcedBias = NONE`), or no setup met the
  sweep + CHoCH/IFVG conditions in the entry window. The Tester Journal and the chart marks tell you which.
- **`ChochRetrace` fills** → if a CHoCH limit never fills, price didn't retrace 25% within the window;
  that's by design (it's cancelled). Lower `ChochRetrace` toward 0 for shallower (more frequent) fills.

---

## 11. Status / next step

Code is written but **not yet compiled in MetaEditor** in this environment — Step A.3 is your first
checkpoint; fix any compiler messages (or paste them to me). The IFVG/CHoCH detection is **v1** and is
best validated in **visual mode** using the on-chart marks, then tuned (`SwingStrength`, `ChochRetrace`).
```

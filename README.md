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

Trade only during the approved sessions (**Riyadh local time, GMT+3**) — Asia, London and NY,
with London switchable via `UseLondon`. At each session open you
click a bias button (**BUY / SELL / NONE**). The EA then waits for price to **sweep the nearest
opposing liquidity** — for a buy, price simply trades **below** a prior low; for a sell, **above**
a prior high (just taking the level is enough). After the sweep, it requires a **CHoCH**
(close-confirmed) or an **IFVG** reaction as the entry trigger. If that confirmation appears
within a **configurable entry window** (default 120 min) from the session open, it opens a
position sized to a fixed **0.5% risk**, with stop **at the sweep wick**. The **default target
is 5%**; from there the exit is managed **dynamically** — the trade can extend toward the nearest
structural high/low, up to the **cap**, while momentum supports continuation. Stop moves to
break-even at **+0.25%** (≈0.5R), and the EA never auto-closes before the default target. Per
session: **stop after the first win**, otherwise up to **three** trades; the next session (same day
or next day) starts fresh.

---

## 2. Resolved configuration (your decisions)

| Topic | Decision |
|-------|----------|
| **Timeframe** | Primarily **M2** (configurable). |
| **Timezone** | Sessions in **Riyadh local time (GMT+3, no DST)**; converted from broker server time via offset. |
| **Bias input** | **Automatic from VWAP** by default (`BiasMode = VWAP`): the session opens above the VWAP -> BUY, below -> SELL. The on-chart BUY / SELL / NONE buttons remain, as a manual override and as the sole source when `BiasMode = MANUAL`. |
| **Entry confirmation** | **CHoCH** (close-confirmed break) → **pending LIMIT at 25% retrace of the breaking leg**; **IFVG** secondary → market entry. First valid trigger after the sweep wins. |
| **Entry window** | **Configurable minutes** from session open (default 120). |
| **Sweep** | Price simply **takes the level** (trades beyond the prior high/low). No close-back-inside required — the *entry model* provides the reversal confirmation. |
| **Default target** | **5%** by default, regardless of structure. Extension is decided by nearest high/low + momentum, capped at `MaxTargetPercent` — which ships **equal** to the default, disabling extension entirely (§6.6). |
| **Stop loss** | **At the entry pattern's own leg extreme** by default (`SLAnchor`): CHoCH → the breaking-leg extreme; IFVG → the extreme of the reclaim leg since the zone formed. The `SWEEP_WICK` option anchors at the session extreme instead. Optional small buffer. |
| **Session caps** | Stop after **1 win**; otherwise up to **3** trades (charter says 2). No daily cap — next session continues normally, same day or next. |
| **Rule 14** | EA simply never auto-closes before +4% (no manual-block logic). |
| **TP > 10%** | Cap at 10%, always trade if valid. |
| **Symbol** | **XAUUSD (Gold) only.** |

---

## 3. The Charter — rule-by-rule mapping

| # | Rule (charter) | EA implementation |
|---|----------------|-------------------|
| 1 | **Approved sessions** — Asia 03:00–06:00, NY 15:00–18:00 | Windows in **Riyadh time**. A third window, **London 09:00–12:00**, is added on top of the charter and is toggled with `UseLondon` (default **off**); set it to `true` to trade it as well. It has never been backtested. |
| 2 | **Asia condition** — price must exit the prior 4-hour range | The range box (last 4h of the previous day) is **drawn for reference only**, confined to its own 4 hours. The breakout check is the **trader's manual job** — the EA does not gate entries on it. |
| 3 | **Entry timing** — only within the first ~1.5 hours | Hard gate via input `EntryWindowMinutes` (default 120). No entry after. |
| 4 | **Sell** — sweep prior **highs** first | SELL requires price to trade **above** the nearest prior swing high. |
| 5 | **Buy** — sweep prior **lows** first | BUY requires price to trade **below** the nearest prior swing low. |
| 6 | **Entry model** — IFVG or clear BOS, candle close | **CHoCH**: break confirmed on candle close, then a **pending LIMIT at 25% retrace of the breaking leg** (no chasing a long break bar). **IFVG**: market entry on the close-confirmed reclaim. |
| 7 | **Protection** — at **+2%**, SL → entry | Floating-gain monitor moves SL to break-even. |
| 8 | **Target** — prior high/low, clear reading | Default 4%; **dynamic engine** (Section 6) extends to structural levels by momentum, 10% cap. |
| 9 | **Risk** — fixed **0.95%** of capital | Lot size = `RiskPercent` ÷ (entry-to-SL distance). The charter says 0.95%; the shipped default is **0.5%**, matching the validated backtest. |
| 10 | **Trades/session** — max **2** (losing) / **1** (winning) | Stop after **1 win**; otherwise up to **2**, then stop for that session. |
| 11 | **Max RR** — target ≤ **10%** | Hard 10% cap on the runner. |
| 12 | **Min RR** — target ≥ **4%** | **Default target is 4%**, so every trade meets the minimum by construction. |
| 13 | **Stop after target hit** — no more trades | TP hit → session locked. |
| 14 | **No early close** — not before **+4%** | EA never auto-closes before +4%. |
| 15 | **Don't skip valid setups** | EA auto-takes every qualifying setup. |
| 16 | **Notion/TradingView documentation** | Out of EA scope; optional CSV journal. |
| 17 | **Session direction** — trader's own analysis | **Automated via VWAP** (Section 4.6) when `BiasMode = VWAP` (default); set `BiasMode = MANUAL` to restore the charter's letter and input the bias yourself. The panel overrides either way. |
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
- **Detection of CHoCH / IFVG** requires the pattern's CORE to be **in-session**: the broken
  swing of a CHoCH and the displacement candle of an IFVG gap must be session bars. Bars from
  `DetectPreHours` (default 2h) before the open are copied **only as confirmation neighbours**
  — so the very first session candle can form a confirmed swing or a 3-candle gap with the bar
  before the open (e.g. the opening sweep candle being itself the gap). The confirming close is
  always in-session, and only the *sweep target* may reference structure outside the session
  (its own deeper `PreSweepHours` window).
- **One position at a time**: while a trade or a pending CHoCH limit is live, the EA **stops all
  detection and setup drawing** and only manages the open position.

### 4.2 Asia previous-day 4h range (rule 2) — reference drawing only
- Computed once per day: **High/Low of the last 4 hours of the previous day**, i.e. the 4-hour window ending at the configured day-close time (`DayCloseHourRiyadh`).
- The box is drawn **strictly over its own 4 hours** (it never extends into the Asia session, no
  projected rays). Whether price exited it is checked **manually by the trader** — the EA does
  not use it as an entry condition; arming a bias starts the setup hunt immediately.

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
  - **IFVG supersedes an unfilled limit**: while the CHoCH limit is pending, IFVG detection
    keeps running (post-sweep zones only). If an IFVG confirms on a candle close before the
    limit fills, the limit is cancelled and the IFVG enters at **market** — "first valid
    trigger after the sweep wins".
  - **BOS trailing**: while the limit is pending, new structure breaks keep being detected. The
    order always sits on the **second-newest BOS** — BOS #2 keeps the order on BOS #1; from
    BOS #3 on, the order is lifted to the previous newest BOS, and so on. The newest BOS is
    treated as the liquidity being built; the order's price, SL and lots are recomputed from
    the BOS it moves to. The dashboard shows `limit pending (BOS n, order on prev BOS)`.
  - Stop loss still sits at the **sweep wick**; lot size is computed from the limit price → SL.

### 4.4 IFVG — Inverse Fair Value Gap (secondary trigger)
- A **FVG** is a 3-candle imbalance; an **IFVG** forms when an existing FVG is traded through and closed beyond (invalidated), flipping into opposite S/R. Entry on a close-confirmed reaction from the inverted zone. First valid trigger after the sweep wins — and **if a CHoCH and an IFVG fire on the same candle (`EntryModel = EITHER`), the IFVG takes priority** (it is an immediate market entry at a confirmed rejection, no pullback needed).
- **Sweep-leg or later only**: the gap's displacement candle must not pre-date the **swept
  level's own bar** — i.e. it must belong to the leg that runs to take the liquidity, or come
  after it. The entry model is *looked for after the sweep* (charter): gaps made by the
  sweeping leg itself count, while zones older than that leg can never trigger an entry, even
  if price reclaims them later.
- **Trigger = fresh close through the far edge**: prior bar closed at/inside the zone edge,
  last bar closed beyond it in the trade direction. A wick-touch is NOT required, so a straight
  displacement candle that closes through the whole zone fires too. Direction mapping: a SELL
  inverts a **bullish** gap (close below it); a BUY inverts a **bearish** gap (close above it).

### 4.5 Entry sequence (per session)
```
1. Session open → bias set (BUY/SELL)?                ──no──► idle
   (BiasMode=VWAP arms it automatically here — Section 4.6;
    rule-2 4H-range breakout is still the trader's MANUAL check)
2. Within EntryWindowMinutes of open?                 ──no──► lock session
3. Nearest opposing high/low taken (sweep)?           ──no──► wait
4. CHoCH or IFVG fires on candle close?               ──no──► wait
5a. CHoCH → place LIMIT at 25% retrace of breaking leg (BOS trailing rules)
5b. IFVG  → enter at market
6. On fill → size RiskPercent, SL at pattern leg, TP at the cap, arm dynamic runner
```
There is **no "structural target ≥ default" gate** — the default target always applies; structure
only governs whether to extend *beyond* it, and only when `MaxTargetPercent > DefaultTargetPercent`.

### 4.6 VWAP auto-bias (rule 17, automated)
Ported from the TradingView **Volume Weighted Average Price** indicator (Pine v6):

```
vwap = Σ(src × volume) / Σ(volume)      since the anchor
```

with the Pine defaults — `src = hlc3`, anchor `"Session"` (a **daily** reset). Two deliberate
adaptations:
- **Anchor boundary** = the strategy's own `DayCloseHourRiyadh`, so the VWAP resets on the same
  calendar the sessions and the prior-day 4H range already use (`VwapAnchor = WEEK` resets on
  Monday instead).
- **Volume source**: most Gold/CFD feeds report `real_volume = 0`, so the series falls back to
  `tick_volume` when no real volume is present (Pine would raise *"No volume is provided by the
  data vendor"*).

**The rule** — decided **once per session, on its first bar**:

| Session's first bar opens… | Bias armed |
|---|---|
| **above** the VWAP | **BUY** |
| **below** the VWAP | **SELL** |
| exactly on it | NONE (session skipped) |

The VWAP it is compared against is the value **carried into the session** — computed from the bars
*strictly before* the opening bar — so the opening bar itself cannot move the level it is being
judged by.

**Precedence**: `ForcedBias` (backtest override) → VWAP auto-bias → panel. The panel is still live:
a click **after** the automatic decision wins for the rest of that session, because the decision is
latched per session. Leaving a session disarms the bias back to `NONE`.

Every decision prints `[SS] AUTO BIAS (VWAP): ASIA open 3412.55 vs VWAP 3408.10 -> BUY`, raises an
alert, and is drawn on the chart as a blue level at the compared VWAP with the verdict text.

> If `ForcedBias` is not `NONE`, the auto-bias is **disabled** — the EA alerts about this at
> startup, because a saved tester `.set` can silently keep an old `ForcedBias` value.


---

## 5. Risk & sizing

- **Sizing**: lots = `(Balance × RiskPercent) / lossPerLot`, where `lossPerLot` is the broker's own
  `OrderCalcProfit(entry → SL, 1.0 lot)` — **not** `|entry − SL| × tickValue`, which some brokers
  report in scaled units and which inflated the size ~100×. Rounded down to the volume step, so
  realized risk never exceeds `RiskPercent`; if even the broker minimum lot would over-risk, the trade
  is refused (`lot size = 0`).
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
- **Min default / Max cap** (rules 11, 12): `DefaultTargetPercent` and `MaxTargetPercent`. **They ship equal (5% / 5%)** — see the warning under §6.6.
- **Target = prior high/low** (rule 8): every *extension* target is a real structural swing; momentum only decides whether to hold to the next one.

### 6.6 Tunable behavior
- `UsePartialTP` (default **false**) + `PartialPercent` (default **50%**): close part at the default target to lock the minimum, ride the rest on the trail. Set `true` to bank a partial.

> **Equal targets disable the runner.** `DynamicTP::Manage` tests the cap *before* the partial and
> the trail (`DynamicTP.mqh:132-147`), so whenever `DefaultTargetPercent == MaxTargetPercent` the
> function closes the position and returns before either can run. The shipped defaults are 5% / 5%,
> which is why the validated backtest shows a hard wall at +5% and no trade above +5.37%. To use the
> partial or the structure trail at all, set `MaxTargetPercent` strictly greater than
> `DefaultTargetPercent`.

---

## 7. Proposed inputs (parameters)

| Group | Input | Default | Notes |
|-------|-------|---------|-------|
| General | `WorkingTimeframe` | M2 | Primary analysis TF |
| Sessions | `AsiaStart` / `AsiaEnd` | 03:00 / 06:00 | Riyadh time |
| Sessions | `UseLondon` | false | Enable the London session (never backtested) |
| Sessions | `LondonStart` / `LondonEnd` | 09:00 / 12:00 | Riyadh time; ignored when `UseLondon = false` |
| Sessions | `NYStart` / `NYEnd` | 15:00 / 18:00 | Riyadh time |
| Sessions | `BrokerToRiyadhOffsetHours` | TBD | Server → Riyadh |
| Asia | `DayCloseHourRiyadh` | 00:00 | Anchor for prior-day last-4h range |
| Asia | `RangeLengthHours` | 4 | Rule 2 |
| Timing | `EntryWindowMinutes` | 120 | Rule 3 (configurable) |
| Bias | `BiasMode` | VWAP | Rule 17: `VWAP` = auto from the session open, `MANUAL` = panel only |
| Bias | `VwapAnchor` | Day | VWAP reset period (Day = Riyadh day-close hour / Week = Monday) |
| Bias | `VwapSource` | hlc3 | VWAP price source (Pine `src`) |
| Bias | `ShowVwap` | true | Draw the VWAP curve |
| Bias | `ColorVwap` | #2962FF | VWAP colour (TradingView blue) |
| Bias | `VwapDrawBars` | 400 | Max VWAP segments drawn |
| Structure | `SwingStrength` (N) | 2 | Sweep-target swing detection |
| Structure | `ChochSwing` (N) | 1 | CHoCH reaction-high/low detection (smaller = catches faster breaks) |
| Entry | `EntryModel` | CHoCH-first | CHoCH / IFVG / either |
| Entry | `ChochRetrace` | 0.25 | Limit at 25% retrace of breaking leg |
| Entry | `PreSweepHours` | 8.0 | Hours left of session open to find the low/high to sweep |
| Entry | `DetectPreHours` | 2.0 | CHoCH/IFVG structure sees this many hours before the open (0 = session only) |
| Risk | `RiskPercent` | 0.5 | Rule 9 (charter says 0.95; 0.5 is the validated default) |
| Risk | `SLAnchor` | CHoCH leg | SL at breaking-leg extreme (CHoCH) or sweep wick |
| Risk | `SLBufferPoints` | 0 | Pad beyond anchor |
| Risk | `BreakEvenAtPercent` | 0.25 | Rule 7 — ≈0.5R at `RiskPercent = 0.5`. Hair-trigger; see **Tick model** |
| TP | `DefaultTargetPercent` | 5.0 | Rule 12 default |
| TP | `MaxTargetPercent` | 5.0 | Rule 11 cap — **equal to the default target, which disables the partial and the trail** |
| TP | `UsePartialTP` | false | Section 6.6 |
| TP | `PartialPercent` | 50 | Closed at +4% |
| TP | `MomentumBodyATR` | 1.3 | Displacement |
| TP | `MomentumStallBars` | 3 | Stall/progress window |
| TP | `AtrContractionFactor` | 0.6 | Exhaustion |
| TP | `TrailPadPoints` | broker-tuned | Structure-trail pad |
| Cadence | `ManageOnBarClose` | true | Run the management stack on bar close only — see **Tick model** |
| Caps | `MaxTradesPerSession` | 3 | Rule 10 (charter says 2) |
| Caps | `StopAfterFirstWin` | true | Rule 10 |
| Logging | `WriteTradeJournalCSV` | true | Rule 16 helper |
| Logging | `Debug` | false | Per-bar detection trace to the Experts log |
| Visuals | `ShowVisuals` | true | Range/session boxes |
| Visuals | `ShowSignals` | true | Sweep / CHoCH / IFVG / trade levels |
| Visuals | `ColorRange / Asia / London / NY` | gold / blue / sea-green / red | Box colors |
| Visuals | `ColorChoch / Ifvg / Sweep` | aqua / orchid / khaki | Signal colors |
| Visuals | `ShowSwings` | true | Detected swing-high/low dots |
| Visuals | `ColorSwingHi / Lo` | tomato / green | Swing dot colors |
| Visuals | `SwingDrawLookback` | 300 | Bars scanned for swing dots |
| Visuals | `ShowFVGs` | true | Live FVG / IFVG zones |
| Visuals | `ColorFvg` | slate gray | Non-inverted FVG zone (IFVG uses orchid) |
| Visuals | `MaxFVGs` | 8 | Max live FVG zones shown |
| Visuals | `ShowDashboard` | true | On-chart status panel |

### Chart legend (what gets drawn)
- **VWAP curve** (blue #2962FF) — the anchored VWAP, plus a thicker level at the value the
  session open was compared against, labelled with the verdict (`open ABOVE -> BUY`).
- **Dashboard panel** (top-left) — live state: bias (+ auto/manual tag), VWAP & the open-vs-VWAP
  comparison, session, entry window, 4H range + values,
  sweep met?, entry model met?, trade count/caps, position P/L, and a "what's blocking" note.
- **Prev-Day 4H** (gold, **outline only**) — the rule-2 range box, confined to its own 4 hours
  (no rays, never extends into Asia). Reference for the trader's manual breakout check.
- **ASIA / LONDON / NY boxes** (blue / sea-green / red, **outline only**) — developing session high–low (no fill, so it no longer covers the candles).
- **Swing dots** (tomato highs / green lows) — the structure skeleton.
- **Sweep target** (gold `low to sweep` → khaki `low SWEPT`) — the single marked level, trailing to the newest swing.
- **Newest FVG / IFVG** (gray = FVG, orchid = inverted IFVG) — only the most recent zone
  **relevant to the armed bias** is shown (SELL → newest bullish gap, BUY → newest bearish gap).
- **CHoCH watch line** (aqua) — the swing level a CHoCH would break next.
- **CHoCH signal** (aqua) — only the **newest** breaking leg + broken level + limit line.
- **Trade** — entry (silver), SL (red), TP (green) rays + an up/down arrow at the fill.

> **Debugging "no trades":** read the dashboard **Note** line — it names the first unmet condition
> (e.g. *waiting liquidity sweep*, *entry window closed*). That tells
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
│   ├── Vwap.mqh                  ← anchored VWAP + auto-bias source (Section 4.6)
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
- **Direction (rule 17)** is the VWAP rule by default (Section 4.6); `BiasMode = MANUAL` hands it back to you.
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
- **Verify visually:** on an M2 XAUUSD chart the **ASIA box must start at 03:00**, **LONDON at
  09:00** and **NY at 15:00** Riyadh time. If the boxes are shifted, adjust the offset until they
  line up.

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
| **Realistic (discretionary)** | **Visual mode ON.** Leave `ForcedBias = NONE`. With `BiasMode = VWAP` the bias arms itself at each session open; with `BiasMode = MANUAL` (or to override the automatic choice) click **BUY/SELL** on the panel. Clicks are detected by **polling the button state every tick** (the tester does *not* call `OnChartEvent`), so a click registers on the next tick — pausing, clicking, then resuming also works. | Reproducing how you'll actually trade it. |
| **Fast (mechanical)** | **Visual mode OFF.** Set **`ForcedBias = BUY`** (or `SELL`). The EA arms that bias for every session automatically. | Quickly checking the entry/risk/TP engine over long ranges, one direction at a time. |

> `ForcedBias` is a **backtest-only** convenience — it applies one fixed direction to all sessions.
> Leave it `NONE` for live trading and use the panel.

#### Tick model — why the same range gives very different results

Entries confirm on bar close and are essentially model-independent. **Exits are not.** The whole
management stack — break-even at +2%, the partial at +4%, the +10% cap, the structure trail and the
opposing-CHoCH exit — reads `POSITION_PROFIT`, i.e. the *live* price, and `OnTick` calls it on every
tick. So the tick model decides how often those thresholds get a chance to fire:

| Model | `OnTick` calls per M2 bar | Effect on exits |
|-------|---------------------------|-----------------|
| Open prices only | 1, at the bar open | BE/partial/trail almost never fire intrabar — winners run far |
| 1 minute OHLC | ~8, including each M1 high and low | thresholds fire on intrabar extremes — more BE and +4% exits |
| Every tick (real ticks) | thousands | closest to live |

Measured on the same XAUUSD range, Open-prices-only vs 1-minute-OHLC moved the average winner from
1,857 to 687 and the profit factor from 1.68 to 1.43, while the *win rate rose* from 54.5% to 62.5% —
the signature of BE and the partial triggering early. Balance drawdown went from 18.0% to 26.3%.

Two consequences:

- **Live is finer than 1-minute OHLC, not coarser.** Open-prices-only results are unreachable in
  live trading; treat that model as a parameter-screening tool only. **Every tick based on real
  ticks** is the only reference number.
- **Never compare `Total Net Profit` across runs.** `LotForRisk` sizes off the live balance, so the
  test compounds; a small expectancy difference becomes a 3× profit difference over ~1400 trades.
  Compare **Profit Factor** and **Expected Payoff as a % of balance**.

`ManageOnBarClose = true` moves the management stack into the new-bar branch, which largely removes
the tick-model sensitivity above and makes a backtest directly believable. The trade-off is real:
BE and the +10% cap are then evaluated once every 2 minutes, so intrabar break-even protection is
lost. The +10% cap itself is still safe — it is also a broker-side TP set at order time — but the
partial and the trail will lag. Residual model sensitivity remains either way, because the tester
resolves broker-side SL/TP fills from the bar's OHLC path, and an M2 bar carries less path
information than two M1 bars.

### D. Read the results
- **Visual chart:** swing dots → sweep level → CHoCH/IFVG marks → entry/SL/TP arrows show exactly
  what the EA did (Section 7 legend).
- **Excel report:** `<AppData>/MetaQuotes/Terminal/Common/Files/SessionsStrategy_Report_<symbol>.xls`
  — a single styled Excel file in the **Common** folder (one fixed path shared by the tester and
  live charts). Real columns with set widths, blue header, **WIN rows green / LOSS rows red**.
  One row per closed trade: No, Riyadh week-day, date, session, bias, model, lots, profit/loss,
  WIN/LOSS, **account balance after the trade**, and **balance as it would be without Friday &
  Monday trades**. Two styled summary blocks follow: **ALL TRADES** and **EXCLUDING FRIDAY &
  MONDAY** (trades, wins, losses, total profit, total loss, net P/L, final balance). Rewritten
  with fresh totals after every close. A **tester run starts the file fresh**; a live chart
  re-reads its rows on restart and continues the same file. (Excel shows a one-time
  "format/extension don't match" prompt — answer Yes.)
- **Tester → Journal tab:** prints each limit placement / order error if something is rejected.

### E. Common gotchas
- **Wrong Gold symbol name** → "unknown symbol"/no trades. Use the exact name from Market Watch.
- **Boxes at the wrong hours** → fix `BrokerToRiyadhHr` (Step B).
- **No trades** → bias not armed (`BiasMode = MANUAL` with the panel still `NONE`, or the auto-bias
  found no VWAP data before the open — see the `[SS] AUTO BIAS` lines), or no setup met the
  sweep + CHoCH/IFVG conditions in the entry window. The Tester Journal and the chart marks tell you which.
- **`ChochRetrace` fills** → a CHoCH limit that never fills waits on its BOS (per the BOS-trailing
  rule) until a newer BOS lifts it or the entry window closes. Lower `ChochRetrace` toward 0 for
  shallower (more frequent) limit fills.
- **Every order decision is logged in English** in the Experts/Journal tab with the `[SS]` prefix:
  `LIMIT PLACED`, `POSITION OPENED`, `LIMIT NOT FILLED ... switching to MARKET`, `LIMIT CANCELLED`,
  `MARKET/LIMIT ... FAILED: retcode`, `SKIPPED (invalid SL / lot size = 0)`, `POSITION CLOSED`.
  Opens and failures also raise an `Alert()` popup.

---

## 11. Status / next step

Code is written but **not yet compiled in MetaEditor** in this environment — Step A.3 is your first
checkpoint; fix any compiler messages (or paste them to me). The IFVG/CHoCH detection is **v1** and is
best validated in **visual mode** using the on-chart marks, then tuned (`SwingStrength`, `ChochRetrace`).
```

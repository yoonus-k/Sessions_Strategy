# v2/ml — offline calibration, not a live model

This folder is intentionally small. After the "should we use ML/RL for the
session-quality classifier" discussion (see `v2/doc/IMPLEMENTATION_PLAN.md`,
section "Discussion: why it's leaking chop..."), the answer for v2 is:

- **No RL.** Wrong problem shape — there's no sequential action/reward here,
  just a static classification of a completed session from a handful of
  numbers.
- **No live supervised model either.** `../../v1/ml/` already tried a proper
  LightGBM trade-quality filter and a VWAP-direction model on this codebase;
  both came back negative (see git commit `b145f7e`). More importantly, a
  trained model would replace the on-chart "score 0.71, rng/base 1.30 → PASS"
  explanation with a black box — which breaks the whole point of this
  project's visual-testing methodology.
- **Use "ML" only as an offline threshold-discovery tool.** `calibrate_quality.py`
  reads the CSV `T2c_SessionQuality.mq5` already writes plus a small
  hand-labelled file (you eyeballing sessions and marking green/red), and
  turns that into 3-4 threshold numbers you paste back into the EA's inputs.
  The "learning" happens once, in Python, on your machine; nothing about it
  runs at runtime.

## Getting labelled data

**Recommended: `../tools/SessionLabeler.mq5`.** Run it in the Strategy Tester
(Visual mode). It pauses the tester at every session close, draws that
session's box with every metric on the chart, and shows GREEN / RED / SKIP
buttons — click one and it appends a row straight to
`Common\Files\SessionsStrategyV2_Labels_<symbol>.csv`, already labelled, no
extra step:

```
python calibrate_quality.py --labelled-csv <path to SessionsStrategyV2_Labels_XAUUSD.csv>
```

**Manual alternative:** run `T2c_SessionQuality.mq5` over a few months, then
label its CSV by eye after the fact:

```
python calibrate_quality.py --csv <path to SessionsStrategyV2_Quality_XAUUSD.csv> --make-template
#  -> fill quality_labels_template.csv's 'label' column (1 = green, 0 = red), save as quality_labels.csv
python calibrate_quality.py --csv <path to the CSV> --labels quality_labels.csv
```

Either CSV lives in the terminal's **Common** files folder:
`C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\Common\Files\`

## Output

Per-metric correlation with your labels (now including the extra volatility
features: `body_impulse_bars` — conviction-candle count using candle body
instead of full range, so a wick spike doesn't count; `max_bar_range_share` —
how much of the session's range came from a single bar; `run_ratio` —
longest same-direction streak, a persistence signal distinct from Kaufman
efficiency; `volume_ratio` — session tick-volume vs the same baseline
machinery already used for range), a grid search over the same gate shape
`SessionQuality.mqh` uses (ranked by precision/recall/F1), and — if
scikit-learn is installed — a depth-3 decision tree printed as plain-English
rules, as a cross-check. Dependencies: `pandas`, `numpy`; `scikit-learn` optional.

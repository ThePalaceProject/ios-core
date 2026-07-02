# app-rating-sentiment-gate — visual baselines (3.3.0)

Per-appearance reference renders of the app-rating sentiment gate (Epic PP-4086),
captured against the shipped 3.3.0 UI on the iOS 26 simulator.

| File | Appearance | What it pins |
|---|---|---|
| `gate-sentiment-dark.png` | Dark | Primary "Yes, I love it!" is navy (`palaceBlueBase`) with legible white text — the regression guard for the white-on-white bug fixed in PR #1171 (wall-failure `2026-07-02-pr1168-darkmode-contrast`). |
| `gate-sentiment-light.png` | Light | Same layout/contrast in light mode. |

**Why these exist:** OCR text-presence assertions are contrast-blind — they read the
label of an invisible white-on-white button as "present". These pixel baselines,
compared via SSIM in `simdrive replay`, catch a contrast/layout regression that text
assertions cannot. Pair with the `visual_checks` blocks in
`.simdrive/journeys/app-rating-sentiment-gate.yaml` and
`.simdrive/fixtures/flows/app-rating-sentiment-gate.yaml`.

**Refresh:** re-capture when the gate's copy, layout, or colors intentionally change,
and bump the version dir to the then-current `MARKETING_VERSION`.

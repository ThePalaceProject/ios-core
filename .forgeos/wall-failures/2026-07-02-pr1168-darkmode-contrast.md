---
date: 2026-07-02
pr: "#1168"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: verify-pr
walls: [TDD, verify-pr]
severity: medium
wall_status: proposed
applied_in: ""
detector_script: ""
detector_status: no-detector
no-detector: |
  Contrast/legibility is a rendered-pixel property, not a static-diff property.
  A grep/AST check cannot know that `.accentColor` resolves to ~white in this
  app's dark mode, nor that the resulting fill collides with a `.white` label.
  The correct gate is a vision review of the actual screenshot in the simdrive
  loop (added to the flow fixture) plus per-appearance visual baselines — not a
  source-scanning script.
name: wall-failures-2026-07-02-pr1168-darkmode-contrast
type: evolving
status: active
created: 2026-07-02
last_refresh: 2026-07-02
freshness_window: 365d
owners: [general]
description: OCR text-presence assertions passed on a white-on-white dark-mode button; the human-invisible label was caught only by a manual look
---

# Dark-mode white-on-white button — OCR passed, the label was invisible

## Finding (verbatim from user)

> "are you seeing the button color issue on dark mode?"

The sentiment gate's primary "Yes, I love it!" button rendered as a solid white
pill with white text in **dark mode** — the label was completely invisible to a
human. My simdrive validation had reported the gate "renders correctly with all
3 buttons" because the OCR `observe` marks read "Yes, I love it!" as present.

## What actually happened

`SentimentGateView.primaryButton` used `.background(Color.accentColor)` +
`.foregroundColor(.white)`. In the Palace app, `Color.accentColor` resolves to
~white in dark mode (the brand green/blue lives in named color assets, not the
SwiftUI accent). So the fill was white and the label was white → invisible.

The simdrive OCR pass (`observe` with Set-of-Mark) reads text from the rendered
glyphs regardless of their contrast against the background — the glyphs ARE
drawn, just in the same color as the fill. So `contains_text: ["Yes, I love
it!"]` passed. I reported the run green off the OCR marks WITHOUT looking at the
actual screenshot pixels. The bug was invisible to text assertions and only
surfaced when the user (and then I) looked at the image.

Fix: primary button now uses the fixed brand navy `Color.palaceBlueBase`
(identical in both appearances) + white text; secondary/tertiary use semantic
`.primary`/`.secondary`. Verified legible in BOTH light and dark via a vision
review of the rendered screenshots.

## Walls that should have caught it (and why they didn't)

- **TDD**: the XCTest layer is deliberately behavior/routing only — SwiftUI
  color rendering is not unit-tested (and image-snapshot XCTest is banned here
  as flaky per CLAUDE.md). So no unit test could catch a contrast bug.
- **verify-pr / simdrive**: the simdrive flow asserted OCR **text presence**,
  which is contrast-blind. The flow had no visual/legibility check and no
  per-appearance baseline, so a white-on-white render passed. The reporting
  step compounded it: "renders correctly" was claimed off OCR marks, not a look
  at the pixels.

## Proposed permanent fix

Two-part, both landed/queued:

1. **Mandatory visual check in every simdrive gate flow (landed).** The
   `app-rating-sentiment-gate.yaml` fixture now carries a `visual_checks:` block
   requiring a vision review of the rendered screenshot for label legibility
   (NOT white-on-white / same-color-on-same-color), run in BOTH appearances.
   Standing rule for authoring any simdrive UI flow: *OCR text presence is
   necessary but not sufficient — every screen with rendered UI gets a vision
   review of the actual image, and any flow that renders themed UI runs in both
   light and dark.*

2. **Per-appearance visual baselines (queued for PP-4716).** Capture
   `.simdrive/fixtures/baselines/<version>/app-rating-sentiment-gate/<step>.png`
   for light AND dark once the corrected build ships, and gate regressions via
   SSIM `replay`. A baseline comparison catches a future white-on-white
   regression structurally (the pixels change), where OCR cannot.

## No detector — justification

See frontmatter `no-detector`. Contrast is a rendered-pixel property; no static
source scan can encode "this color pair collides at runtime in this appearance."
The gate is the vision-in-the-loop review + per-appearance baselines, both in
the simdrive layer, not a `scripts/check-*.py`.

## Application log

- 2026-07-02 — button-color fix + fixture `visual_checks` applied on PR #1168
  (branch feature/PP-4089-4090-4091-app-rating-ui). Verified legible in light +
  dark via screenshot vision review.
- Per-appearance baselines tracked in PP-4716.

## Related entries

- `2026-07-02-pr1167-arch1.md` — same PR family; that one was "claimed done,
  partially done" (partial replace_all). This one is "claimed verified,
  verified-by-the-wrong-signal" (OCR presence instead of visual legibility).
  Both are reporting-off-an-insufficient-signal failures.

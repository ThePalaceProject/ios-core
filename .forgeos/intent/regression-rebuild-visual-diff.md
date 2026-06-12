# Intent — RC-VISUAL: pixel visual-diff stage for the regression rebuild

**Workstream:** RC-VISUAL (owner: w-lane). Stage 3 of the fleet regression
rebuild (`REGRESSION-REBUILD-DESIGN.md` §4.3). Coordinator: palace-pm.

**Motivation:** today's "visual regression" is OCR-marks structural diff only
(`marks-diff.py`). An empty-but-correctly-labelled loading skeleton (PP-4553:
`CatalogLaneModel(isLoading: books.count < 3)` rendered a perpetual shimmer)
passes marks checks while looking broken. The net-new capability is a **masked
perceptual / SSIM pixel diff** against per-device-cell golden baselines that
catches PP-4553-class empty-skeleton regressions, layered alongside the existing
structural marks diff.

## Claims (this diff does exactly these)
1. Adds `scripts/visual-diff.py` — a masked SSIM + structural pixel-diff tool.
   - Subcommand `diff`: compares a candidate PNG (or dir) vs a per-cell golden
     baseline PNG (or dir); writes a diff heatmap image; appends `visual-parity`
     findings to a findings.csv in the **BUILD-PLAN schema**
     (`id,area,device_cell,severity,classification,verified,evidence_paths,screenshot_pair,first_seen_commit,dedup_cluster,disposition`).
   - Subcommand `baseline`: capture / promote / list golden baselines per device
     cell under the artifact-dir layout (`baselines/<cell>/<area>/*.png`).
2. Implements masked SSIM in **pure numpy** (no scikit-image / scipy dependency)
   via a uniform-window integral-image SSIM.
3. Implements two mask-region types in a JSON mask config:
   - `exclude` — region fully ignored (clock, battery, other dynamic chrome).
   - `content` — cover/lane regions compared for **structural presence**
     (variance / edge density), not pixel identity — so a different book cover
     does NOT fire, but covers→empty-skeleton collapse DOES (the PP-4553 catch).
4. Integration with the existing `marks-diff.py` via `--with-marks`: runs the
   structural marks diff on the `.json` sidecars and merges those rows into the
   same findings.csv (mapped to the BUILD-PLAN schema, `classification=visual-parity`).
5. Adds `scripts/tests/test_visual_diff.py` — pytest unit + CLI tests that build
   synthetic fixtures and prove: (a) a clock-only change is suppressed by an
   `exclude` mask; (b) a covers→skeleton change is caught as a `visual-parity`
   finding; (c) the diff image + findings.csv row are written in the right schema.

## Anti-claims (this diff does NOT do these)
- Does NOT modify any `Palace/` production source, app behavior, or DRM/auth/
  borrow/return/download paths. Test-tooling only under `scripts/` + `.forgeos/`.
- Does NOT touch `marks-diff.py` itself (only calls it as a subprocess/import).
- Does NOT add the campaign driver, area-workers, Fable-triage, or the device
  matrix (other workstreams: RC-AREA, RC-TRIAGE, RC-CAMPAIGN, HC-DEVICE-CELLS).
- Does NOT add a new third-party Python dependency (numpy + Pillow already used).
- Does NOT auto-file Jira or open downstream PRs — emits findings rows only.

## Files in scope
- `scripts/visual-diff.py` (new)
- `scripts/tests/test_visual_diff.py` (new)
- `.forgeos/intent/regression-rebuild-visual-diff.md` (this file)
- `docs/` or `scripts/` README note for the tool CLI (new, optional)

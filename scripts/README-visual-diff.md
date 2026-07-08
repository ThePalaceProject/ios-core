# visual-diff.py — masked pixel visual-diff (RC-VISUAL, regression rebuild stage 3)

The net-new pixel layer of the fleet regression campaign. It catches the bug
class the OCR-marks structural diff (`marks-diff.py`) misses: an
empty-but-correctly-labelled loading skeleton that *looks* broken while passing
every text check — i.e. **PP-4553** (final catalog lanes rendered a perpetual
shimmer). Pure `numpy` + `Pillow`; no scikit-image / scipy.

## What it does

Compares a candidate screenshot vs a per-device-cell **golden baseline** with a
**masked, uniform-window SSIM**, plus a **structural-presence** check on content
regions, and emits `visual-parity` findings in the campaign `findings.csv`
schema (one row per finding) with a diff-heatmap image as evidence.

### Mask region types (the PP-4553 nuance)

You cannot simply mask the cover region — that is exactly where the
empty-skeleton bug hides. So masks have two kinds:

| type | meaning | catches | suppresses |
|------|---------|---------|------------|
| `exclude` | region fully ignored | — | clock, battery, dynamic chrome |
| `content` | compared for **structural presence** (gradient energy), not pixel identity | covers → flat skeleton (PP-4553) | a *different* book cover (legitimate server-side variation) |

Everything outside the masks is compared with the global masked SSIM (chrome,
layout, labels, skeleton background).

Mask rects may be **fractional** (0..1, recommended — one config per cell across
resolutions) or absolute pixels. See `.simdrive/fixtures/masks/example-catalog.json`.

## Findings emitted (`classification = visual-parity`)

- `pixel_regressed`  — global masked SSIM below `--threshold`
- `empty_skeleton`   — a content region's structure collapsed vs baseline (PP-4553)
- `dims_mismatch`    — candidate resolution differs from baseline (layout regression)
- `text_*` (via `--with-marks`) — structural marks-diff rows folded in

Rows are written through the campaign's single source of truth for findings.csv
I/O, `scripts/regression_findings.py` (`append_findings(csv_path, rows)`) — no
parallel CSV writer is hand-rolled, and a missing module is a hard error rather
than a silent fallback. Output is a **per-shard** CSV
(`<run-dir>/findings/<cell>__<area>.csv`) so parallel cells never race.

## CLI

```bash
# Campaign mode — derive baselines/candidates/diffs/findings from the run dir
# per the ratified path convention (<run-dir>/<kind>/<cell>/<area>/...):
visual-diff.py diff --run-dir .regression-runs/run-1 \
  --device-cell C-iphone-26 --area catalog \
  --mask-config .simdrive/fixtures/masks/example-catalog.json --with-marks

# Single pair:
visual-diff.py diff \
  --baseline a.png --candidate b.png --mask-config mask.json \
  --device-cell C-iphone-26 --area catalog/03-catalog \
  --diff-out diff.png --append-csv findings/C-iphone-26__catalog.csv

# Promote a candidate run to the golden baseline for a cell, then list:
visual-diff.py baseline promote --from candidates/C-iphone-26/catalog \
  --cell C-iphone-26 --area catalog --root .regression-runs/golden
visual-diff.py baseline list --root .regression-runs/golden
```

`--strict` exits non-zero if any finding is emitted (CI gate). Tuning:
`--threshold`, `--window`, `--content-min-structure`, `--content-collapse-ratio`
(design open-question #3 — calibrate per area).

## Tests

`scripts/tests/test_visual_diff.py` (pytest) — builds synthetic fixtures and
proves: clock-only change suppressed (+ control that it would fire unmasked),
covers→skeleton caught, different-covers tolerated, dims-mismatch flagged, the
BUILD-PLAN CSV schema, the shared-writer adapter binds `append_findings` (never
`write_findings`), the `--run-dir` shard path, and the CLI end-to-end.

```bash
python3 -m pytest scripts/tests/test_visual_diff.py -q
```

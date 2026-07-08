---
name: regression-rebuild-area-chaos
created: 2026-06-12
author: claude-opus-4-8
tracking: Regression-rebuild fleet campaign — workstream RC-AREA+CHAOS (palace-pm REGRESSION-BUILD-PLAN.md, REGRESSION-REBUILD-DESIGN.md §4.1 stages 1–2, §4.4)
---

## Summary

Build the **area-worker runner** + **chaos-on-every-area** integration for the
fleet-orchestrated regression campaign. This is product test-tooling that ships
to ThePalaceProject via `ios-core` (`scripts/`, `.simdrive/`) — the fleet
orchestration (campaign driver, rails) stays Synctek-local and is NOT in this
diff. Branch `feat/regression-rebuild-area-chaos` off `origin/develop`.

The runner replaces the serial manual `/regression` walk with a shardable unit
— one (area-group × device-cell) per worker — so N workers cover the matrix
exhaustively in parallel, each on its own dedicated keychain-reset sim. Conforms
to the BUILD-PLAN shared contracts (findings.csv schema, artifact dir layout,
hermeticity).

## Claims

1. **Adds `.simdrive/regression-areas.json`** — an area-group manifest mapping
   each area-group (`auth`, `circulation`, `reading`, `audiobook`, `catalog`,
   `ui-nav`) to its `matrix_ids` (REGRESSION_TEST_MATRIX rows), its `journeys`
   (existing `.simdrive/journeys/*.yaml` ids), and its `chaos_seeds` (fixture
   `flow/step` seeds for `run-chaos-pass.sh`). This is the shard-key source the
   campaign driver reads to fan (area-group × device-cell) workers.

2. **Adds `scripts/regression_findings.py`** — the shared findings writer. Emits
   the BUILD-PLAN findings.csv schema
   (`id,area,device_cell,severity,classification,verified,evidence_paths,screenshot_pair,first_seen_commit,dedup_cluster,disposition`)
   with a header guarantee and an `append_finding` that both the area-worker and
   chaos-fan use, plus manifest-loading and area→journey resolution helpers.
   Discovery-time rows set `verified=false` and leave `severity/dedup_cluster/
   disposition` empty for the downstream Fable-triage stage to fill.

3. **Adds `scripts/regression-area-worker.sh`** — the shard runner. Takes
   `--area-group × --device-cell × --run-dir` (+ `--sim-id` or env
   `HARNESS_SESSION_SIM_UDID`). Keychain-resets its sim (hermeticity), replays
   the area's journeys via simdrive (reusing the proven replay+structural+perf+
   crash-capture path from `simdrive-regress.sh`), ALWAYS writes a per-journey
   log under `<run-dir>/logs/<cell>/<area>/` (the evidence trail), captures a
   candidate screenshot under `<run-dir>/candidates/<cell>/<area>/` (feeds the
   RC-VISUAL stage), dumps crash files under `<run-dir>/crashes/<cell>/`, and
   appends a findings row per real failure (errored / crash / perf-high /
   structural-fail) — every finding carrying evidence paths. A journey with no
   local recording is SKIPPED with a logged warning (not a finding), and no
   evidence ⇒ no finding (anti-hallucination).

4. **Adds `scripts/regression-chaos-fan.sh`** — fans `run-chaos-pass.sh` across
   EVERY area-group's `chaos_seeds` (not just PR-diff seeds), preserving the hard
   rules already enforced in `run-chaos-pass.sh` (Palace Bookshelf only, no
   `simctl erase`, no credential lockout, log-evidence required). Ingests each
   chaos run's findings.csv (the legacy chaos schema) and translates the rows
   into the campaign findings schema + evidence dirs. Supports `--dry-run`
   passthrough for cheap wiring verification.

5. **Adds `scripts/tests/test_regression_area_chaos.py`** — pytest covering the
   findings schema header/row conformance, manifest integrity (every referenced
   journey exists on disk), and area→journey resolution. Wired into the existing
   `.github/workflows/tooling-checks.yml` detector suite + `bash -n` gate.

## Anti-claims (explicitly NOT in this diff)

- No fleet orchestration / campaign driver / rails (that is RC-CAMPAIGN, harness-
  local, Synctek IP — never committed here).
- No pixel visual-diff tool or golden-baseline management (that is RC-VISUAL).
- No Fable-triage stage, HTML report changes, or ForgeOS-changeset-per-finding
  automation (that is RC-TRIAGE+REPORT).
- No device-cell host provisioning (iPad-on-Mac, iOS-18 floor) (that is
  HC-DEVICE-CELLS). The worker is cell-agnostic: it carries `--device-cell`
  through to the findings + dirs but does not provision the cell.
- No changes to any `Palace/` production code. Tooling only.

## Files in scope

- `.simdrive/regression-areas.json` (new)
- `scripts/regression_findings.py` (new)
- `scripts/regression-area-worker.sh` (new)
- `scripts/regression-chaos-fan.sh` (new)
- `scripts/tests/test_regression_area_chaos.py` (new)
- `.forgeos/intent/regression-rebuild-area-chaos.md` (this file)

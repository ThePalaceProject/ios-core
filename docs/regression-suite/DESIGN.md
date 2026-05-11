# Palace iOS Regression Suite — Design

**Status:** Draft / proposed (feat/regression-suite, not merged)
**Author:** This document is a design artifact for review. The orchestrator + importers in `scripts/regression/` are the implementation.

## Why this exists

The existing `/regression` skill (`.claude/skills/regression/SKILL.md`) executes mechanically but has six structural gaps observed during the 3.1.0 regression run on 2026-05-06:

1. **No side-by-side.** Regression by definition compares two versions; nothing in the skill installs both baseline and candidate and runs the same flow on both.
2. **No baseline-version pinning** on simdrive journeys — recordings captured weeks ago against a different app state cause 8/8 false-fail patterns when the run-state diverges.
3. **Perf gate is unanchored** — Δ100 MB RSS flags HIGH but with no per-version baseline, "is it warmup or a leak" can't be answered automatically.
4. **No automated CSV population.** Every finding is hand-typed from `regress.json` and mutation outputs. High friction, high transcription error.
5. **No cred/device pre-flight.** The TEST_MATRIX requires 5-of-7 auth coverage; today nothing checks whether those creds or the WDA-bootstrapped phone is available before starting.
6. **No in-field signal.** Crashlytics top-N, HelpSpot top-N, CM contract drift — all available via MCP but never ingested into the test plan. The regression isn't biased toward where users are bleeding.

This document specifies the suite that closes those gaps.

## Goals

- **Definitive comparison.** Same journey, same device, baseline+candidate, structural+perf+drift diff per step.
- **Honest classification.** A finding is `regression` only if baseline passed and candidate failed. Otherwise `pre-existing`, `pending-baseline`, or `tooling`.
- **Low-friction workflow.** Findings flow into `findings.csv` automatically; humans verify, don't transcribe.
- **Pre-flight rigor.** Refuse to claim a "complete" regression without the auth-coverage matrix that TEST_MATRIX mandates.
- **In-field bias.** Test what users are reporting on baseline first.
- **Tool/product separation.** Tooling bugs go to a sidecar, not the product CSV or Jira.

## Non-goals

- Replacing CI's `verify-pr.sh` per-PR gate — the suite *uses* it as a Phase-2 step but doesn't replace it.
- Replacing the chaos-qa subagent — the suite *invokes* `run-chaos-pass.sh` as a Phase-2c step.
- Replacing the unit test suite — assumes unit tests are green (verified-pr already enforces).

## Architecture

```
scripts/regression/
  regression-suite.sh         # Top-level orchestrator (Phase 0…6)
  preflight.sh                # Phase 0: creds + devices + in-field signal
  side-by-side.sh             # Phase 2d: dual-install + journey diff
  import-simdrive.py          # regress.json → findings.csv (auto, verified=false)
  import-mutation.py          # mutation summary → findings.csv (kill-rate <50% on critical files = finding)
  capture-perf-baseline.sh    # End-of-release: snapshot per-version perf baselines
  manual-checklist.py         # TEST_MATRIX.md → MANUAL_CHECKLIST.md with checkboxes
  in-field-signal.py          # Crashlytics + HelpSpot + CM via MCP → MUST_TEST.md
```

Existing scripts the suite calls (unchanged contracts):

```
scripts/regression-report.sh  # setup, auto, report, tickets — unchanged
scripts/simdrive-regress.sh   # journey replay — unchanged
scripts/run-chaos-pass.sh     # chaos-qa subagent — unchanged
scripts/verify-pr.sh          # per-PR gate — unchanged
```

## The 7 phases (run by `regression-suite.sh`)

### Phase 0 — Pre-flight

`scripts/regression/preflight.sh` runs four checks and emits a blocking report:

1. **Cred-availability matrix:** `harness creds list` + intersect with TEST_MATRIX auth-type axes. Output to `~/Desktop/regression-<TICKET>/preflight/creds-matrix.md`. **Blocking warning** if <5 of 7 auth types are coverable.
2. **Device-availability:** `mcp__simdrive__list_devices` + cross-check `~/.simdrive/wda/<udid>.json`. For each paired device, status: `ready`, `needs-rebootstrap`, `needs-xcode-account`. **Blocking warning** if zero device-leg-ready phones.
3. **In-field signal:** `scripts/regression/in-field-signal.py` queries Crashlytics (top-5 events by impacted users on baseline version), HelpSpot (top-5 open tickets on baseline version), CM contract monitor (drift since baseline). Output to `~/Desktop/regression-<TICKET>/preflight/MUST_TEST.md` — areas to scrutinize.
4. **Build cache check:** is there a cached `.app` for the baseline tag? If not, recommend building via `--build-baseline` flag.

### Phase 1 — Setup (unchanged)

`scripts/regression-report.sh setup` (existing). Creates workspace + scaffolding. Plus the suite emits an `ENVIRONMENT.md` enriched with what preflight found (devices ready, auth coverable, in-field signal summary).

### Phase 2 — Automated sweep

**2a — simdrive journey replay against the candidate** (`scripts/simdrive-regress.sh`). Existing.

**2b — full automated tool sweep** (`scripts/regression-report.sh auto`). Existing. Now sync-tests run if creds are available (preflight result feeds in); push tests run if Firebase service-account file is present.

**2c — chaos pass** (`scripts/run-chaos-pass.sh --diff-files-from automated/mutation/changed-files.txt --max-minutes 15`). Adversarial seeds derived from the changed-files diff. Findings auto-merged into the workspace CSV.

**2d — side-by-side journey replay** (NEW: `scripts/regression/side-by-side.sh`):
- Resolve `--baseline-ref` to a git tag, `git stash + checkout` the tag, build a baseline `.app`, restore HEAD.
- Boot a second sim (allocated via `harness sim claim`).
- Install baseline on sim-A, candidate on sim-B.
- For each `.simdrive/journeys/*.yaml`: run on sim-A, run on sim-B, capture both regress.json fragments, diff per-step structural/perf/drift.
- Per-step diff JSON to `automated/side-by-side/<journey>.json`.
- Auto-classify: `regression` iff baseline passed and candidate failed at the same step. `pending-investigation` iff both fail (could be infra). `regression-improvement` iff candidate passes a step where baseline failed.

**2e — mutation real-run scoped to critical-path FRs** (NEW): The FR↔Tests matrix sidecar (existing per memory) maps changed-files → tests → FRs. Read it; recommend the file set to mutate-real (cap to ~20 files / ~3 hours wall-clock, or override). Invoke `regression-report.sh auto --mutation-run --mutation-files <list>`.

### Phase 3 — Manual P0/P1 (with generated checklist)

`scripts/regression/manual-checklist.py` reads `TEST_MATRIX.md`, the changed-files list, and the in-field MUST_TEST.md, and emits `MANUAL_CHECKLIST.md` — a sequence of explicit checkbox items per area, ordered by:
1. In-field-signal areas (highest priority).
2. Auth coverage matrix (explicit per-auth-type rows).
3. P0 areas with changed files in the diff.
4. P0 areas without changes (sanity).
5. P1 areas with changes.

Each item has: area, baseline behavior, candidate behavior boxes (pre-filled if simdrive captured them), Verified checkbox, Findings F-NNN reference.

The agent walks the human through this; auto-imports any "found" rows into `findings.csv`.

### Phase 4 — Finding review

Same as today. CSV summary table; verified-vs-unverified; `--strict` gate.

### Phase 5 — Report generation

Same as today, **plus** the report includes:
- Coverage delta (tests added/removed on changed files between baseline and candidate)
- Mutation kill-rate delta on changed files (real-run only)
- Per-area TEST_MATRIX coverage badge (which areas exercised, which not)
- In-field signal alignment ("we tested the top 3 Crashlytics paths from 3.0.0")
- Side-by-side per-step heatmap (baseline-pass → candidate-fail = red; both-pass = green; etc.)

### Phase 6 — Jira tickets + capture-baseline + publishing

Same as today, **plus** at the end of a clean run:
- `scripts/regression/capture-perf-baseline.sh --version <CANDIDATE>` snapshots p50/p95 RSS per step per journey to `.simdrive/fixtures/perf-baselines/<CANDIDATE>/<journey>.json`. The released version becomes the next release's gate.

## Tooling-findings sidecar

`tooling-findings.csv` (separate from `findings.csv`) — for simdrive, harness, ForgeOS, build-system bugs found during regression. Same column shape, but:
- Not consumed by `regression-report.sh report`
- Not consumed by `regression-report.sh tickets`
- Captured into a memory entry at end-of-run for upstream filing
- A blocking finding here doesn't gate Palace release; it gates the next regression cycle (or files an issue in the tool's repo)

## Auth coverage enforcement

TEST_MATRIX mandates: minimum 5 of 7 auth types every release. The 7:
1. `basic` — A1QA Test Library (cred: `palace-ios.lib.a1qa`)
2. `token` — Lyrasis Reads (cred: `palace-ios.lib.lyrasis-reads`)
3. `oauthIntermediary` — NYPL via Clever (manual)
4. `saml` — BiblioCommons / academic libraries (manual + SMS)
5. `oidc` — Palace OIDC test library (manual)
6. `anonymous` — Palace Bookshelf (no cred)
7. `coppa` — Open eBooks (no cred, age-gated)

Pre-flight emits `creds-matrix.md` with one row per auth type, columns: vault key, harness coverage, manual required, last regressed-on. Refuses `--strict` final report if <5 covered.

## In-field signal ingestion

`scripts/regression/in-field-signal.py` reads:
- **Crashlytics** via `mcp__firebase__crashlytics_list_events` for the baseline version. Top 5 by impacted users.
- **HelpSpot** via `mcp__helpspot__helpspot_list_by_filter` for filter "open / iOS / 3.0.x." Top 5 by recency.
- **CM contract monitor** via `mcp__palace-cm-monitor__cm_drift` since baseline.

Emits `MUST_TEST.md` — a prioritized list of code areas/flows to scrutinize. Drives Phase-3 ordering.

## Per-version baseline storage

Two kinds of baselines pinned per shipped version:
1. **Perf baselines** at `.simdrive/fixtures/perf-baselines/<version>/<journey>.json`:
   ```json
   {"journey": "settings-tour-stateless", "version": "3.0.0", "device": "iPhone 16 Pro / iOS 18.4",
    "steps": [{"id": "tap_settings", "rss_p50_mb": 462, "rss_p95_mb": 484}, …]}
   ```
2. **Structural baselines** at `.simdrive/fixtures/baselines/<version>/<flow>/<step>.{json,png}` (existing format).

Capture during the release-cycle freeze — automated by `capture-perf-baseline.sh`.

## Continuous baseline (Tier-3, future)

A nightly job runs all journeys on `develop` tip; stores artifacts at `.simdrive/baselines/<git-sha>/`. A regression's "baseline" can be `--baseline-ref develop@HEAD` (yesterday's green) instead of always the previous shipped version. Not in MVP.

## Replay-corpus seeding (Tier-3, future)

Findings with severity `major` or `blocker` and a saved replay become permanent regression coverage at `.simdrive/replays/chaos/<finding-id>.yaml`. Wired into `chaos-replay-on-pr.yml` (referenced in CLAUDE.md but not yet present). Out of MVP.

## Implementation order (phases delivered)

| Wave | Pieces | Status |
|------|--------|--------|
| **MVP — must ship to call this v1** | preflight (creds + devices + in-field), import-simdrive, side-by-side, manual-checklist, tooling sidecar, capture-perf-baseline | This branch |
| **Stabilization** | import-mutation auto-classify, perf-baseline gate enforcement, in-field-signal MCP integration tests | Next sprint |
| **Polish** | continuous-baseline nightly, replay-corpus seeding, report enrichment heatmap | Tier 3 |

## Compatibility

The suite **wraps** the existing scripts; it does not replace them. Anyone running `scripts/regression-report.sh setup` directly still gets the same workspace. The new `regression-suite.sh` is additive.

## CarPlay coverage

CarPlay is a tier-one Palace feature (audiobook playback in the car) but the
CarPlay simulator window in `Simulator.app` is a separate macOS process from
the iPhone simulator. simdrive's HID injection targets the iPhone sim's
CoreSimulator process; it cannot drive the CarPlay window. So:

| Layer | Tool | Coverage |
|-------|------|----------|
| Unit (XCTest) | `PalaceTests/CarPlayTimeTrackingTests` (in `AudiobookTrackerTests.swift`) | Time-tracking through CarPlay's `BookService.open() → AudiobookManager` flow. **Auto-run by suite Phase 2b.5.** |
| Unit (XCTest) | `PalaceTests/CoverageGapTests3` `isCarPlayEnabled` surface | Feature-flag gate. **Auto-run by suite Phase 2b.** |
| Manual (Simulator.app CarPlay window) | Section 6 in `MANUAL_CHECKLIST.md` | UI rendering, transport controls, disconnect/reconnect, feature-flag gate. **CP1–CP7 in the manual checklist.** |
| Real device (CarPlay-capable headunit) | Out of suite scope | True hardware-side validation lives outside the iOS regression — needs a CarPlay rig. |

The suite's role: run the XCTest layer automatically; surface explicit manual
items for the Simulator.app CarPlay window in Section 6 of the checklist;
document that real-device CarPlay validation isn't part of every regression.

## Open questions

- Mutation real-run wall-clock budget — 30 min for >20 files. Probably split: smoke (~6 files, <10 min) per regression, full (~50 files, hours) per release-cycle.
- Where does in-field signal live — workspace-local `MUST_TEST.md` only, or also a memory entry the next regression reads?
- How does the suite handle a release-branch regression vs. a develop-tip regression — different baselines, different in-field signal scope.
- Real-device CarPlay validation cadence — every release? Quarterly? Behind a feature-flag deployment?

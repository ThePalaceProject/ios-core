---
name: regression
description: Run a full release regression test — sets up workspace, runs automated tools, guides manual testing, generates report and Jira tickets. Use for release gates and QA cycles.
argument-hint: <ticket> [--baseline-version X.X.X] [--candidate-version X.X.X]
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent
---

# Palace iOS Release Regression

You are guiding a QA tester through a full release regression test. This is a structured, multi-phase workflow. Follow each phase in order. Be conversational — explain what you're doing and why, ask for confirmation at key checkpoints.

> **This skill assumes simdrive is installed and licensed** (Phase 2a runs `simdrive-regress.sh`, Phase 3 references the simdrive MCP toolkit). If `python3 -c "import simdrive"` fails on the user's machine, or they don't have a simdrive license / API key, **redirect them to `/regression-qa` instead** — that skill is the manual-only variant with the same workspace, test matrix, report, and Jira flow but without simdrive dependencies.

## Arguments

The user provides:
- `<ticket>` — the Jira ticket for this regression (e.g., PP-4200)
- `--baseline-version` — the version being compared against (e.g., 2.2.5). Defaults to "develop"
- `--candidate-version` — the version being tested (e.g., 3.0.0). Defaults to "candidate"

Parse these from `$ARGUMENTS`. If no ticket is provided, ask the user for one.

## Phase 1: Setup

Run the workspace setup:

```bash
scripts/regression-report.sh setup \
  --ticket <TICKET> \
  --output-dir ~/Desktop/regression-<TICKET>
```

Tell the user what was created:
- `findings.csv` — where all findings go (CSV is the single source of truth)
- `TEST_MATRIX.md` — the test checklist (40+ areas across P0/P1/P2 tiers)
- `ENVIRONMENT.md` — fill in with build details
- `screenshots/` — evidence goes here (800px max width for images, 720p for video)

Ask the user to fill in ENVIRONMENT.md with their build details, devices, and credentials. Read the file back and confirm it looks correct.

## Phase 2: Automated Sweep

**Step 2a — pre-flight simdrive journey replay** (catches obvious regressions fast):

```bash
SIMDRIVE_SIM_ID=<UDID> scripts/simdrive-regress.sh \
  --report ~/Desktop/regression-<TICKET>/automated/simdrive/regress.json
```

Reports per-journey: steps run, drift count (informational), errors, perf delta
(severity low/medium/high), crash count. Any journey with severity `high` perf
delta or crashes>0 is auto-failed. Each failing journey becomes a finding.

**Step 2b — full automated tool sweep**:

```bash
# IMPORTANT: --mutation-run is now MANDATORY for a release regression.
# CI no longer runs mutation (removed 2026-05-15 — too expensive on every
# PR push); the local regression run is the only place mutation results
# get produced for a candidate. Skipping it leaves test-quality regressions
# unmonitored.
scripts/regression-report.sh auto \
  --output-dir ~/Desktop/regression-<TICKET> \
  --baseline-ref <BASELINE_REF> \
  --candidate-branch <CANDIDATE_BRANCH> \
  --run-sync-tests \
  --mutation-run
```

Notes on flags:
- `--baseline-ref` accepts any git ref (tag OR branch). `--baseline-tag` still works as an alias.
- `--mutation-run` triggers REAL mutation execution (otherwise dry-run enumeration).
  The script auto-derives the right XCTest class for each source file via filename
  matching; override per-file with `--mutation-test-class CLASSNAME`.
- `--mutation-files file1,file2,...` lets you target a specific list (overrides the
  changed-files derivation from baseline...candidate). Use this when you want to
  scope mutation to high-risk files instead of running over the full delta.
- `--mutation-limit N` caps the file count; `--mutation-max-per-file N` caps mutations
  per file (default 8).
- For long real-mutation runs (>30 min estimated), the script aborts unless you pass
  `--yes-long-mutation`. Tighten the caps or split the run.
- `--sim-id UDID` overrides the simulator. Default is read from `~/harness/projects/palace-ios.yml`
  if present, else falls back to a sane default.

Report results from each tool:
- Annotation sync tests (pass/fail)
- Push notification tests (pass/fail) — skipped automatically if no Firebase service
  account at `~/.palace/firebase-service-account.json`
- Mutation testing — dry-run gives a top-N-by-surface histogram; real execution
  gives kill/survive rates per file. Always check `automated/mutation/summary.txt`.

Any automated failures should be logged as findings. Help the user add them to the CSV:
- `Verified` = `false` until they confirm on device
- `Classification` = `regression` or `pre-existing` as appropriate

**Watch out for**: a mutation kill rate <50% on a critical-path file is itself a
finding worth filing as `pre-existing major` even if it isn't a regression — the
test suite has insufficient discriminating power. PP-4164 found `AccountsManager.swift`
at 0% kill rate this way.

## Phase 3: Manual Side-by-Side Testing

This is the highest-value phase. Read `TEST_MATRIX.md` and walk through each priority tier.

### Driving the sim: `simdrive` (MCP, current version 0.3.0a1)

`simdrive` is the canonical iOS sim driver. Real CoreSimulator HID input — taps focus
UITextFields and accept keyboard input on iOS 26+ (the v15/v16 cliclick path didn't).
SpecterQA was deprecated 2026-04-29 and fully migrated under `.simdrive/` on
2026-04-30.

**Install / upgrade** (PyPI alpha track):
```bash
pip3 install --pre --upgrade simdrive
~/harness/bin/harness simdrive status   # verify version + active sessions
```

After upgrade, run `/mcp` reload so new MCP tools become available.

**Tool surface** (all `mcp__simdrive__*`):

*Vision + driving*
- `session_start` / `session_end` / `session_status` — boot/find sim, launch app
- `observe` — screenshot + annotated PNG + OCR marks (each w/ `stable_id` + `stable_id_loose`)
- `tap` — by `{x,y}`, `{stable_id}`, `{stable_id_loose}`, `{mark}`, or `{text}`
- `swipe`, `type_text` (with optional `tap_first`), `press_key`
- `record_start` / `record_stop` / `replay` — replay supports `mask_regions` + auto-load `ssim_masks` from YAML

*Diagnostics + perf (new in 0.3.0a1)*
- `app_state`, `apps`, `crashes`, `doctor`, `memory`
- `perf` (snapshot), `perf_baseline` (labeled), `perf_compare` (returns severity: low/medium/high)

*Robustness (new in 0.3.0a1)*
- `pre_grant_permissions` — `simctl privacy grant` BEFORE launch (avoids SpringBoard PIDChange race)
- `set_appearance` — light/dark mode
- `dismiss_first_launch_alerts` — handles the 1-in-4 Allow-button-misses race
- `dismiss_sheet`, `validate_replay`, `list_replays`

### Three orchestrators (use the right one for the job)

1. **`scripts/simdrive-regress.sh`** — pre-PR opt-in journey replay against an active sim.
   Runs every `.simdrive/journeys/*.yaml`, replays the recording, runs structural checks,
   captures perf baseline + delta + crash count per journey. Fails on `errored>0`,
   `crashes>0`, or perf severity `high`. Use this for the pre-regression pre-flight.

   ```bash
   SIMDRIVE_SIM_ID=<UDID> scripts/simdrive-regress.sh --report /tmp/sd.json
   scripts/simdrive-regress.sh --tier stateless         # only blocking-tier journeys
   scripts/simdrive-regress.sh --only book-detail-stateless
   ```

2. **`scripts/run-chaos-pass.sh`** — adversarial exploration. Seeds from
   `.simdrive/fixtures/flows/<flow>/<step>` and deviates with rapid-tap, pathological
   input, bg/fg races. Discovers new bugs that deterministic tests miss.
   See `.simdrive/CHAOS_QA_README.md`.

3. **MarksFixture XCTest** (`PalaceTests/VisualRegression/`) — compile-time XCTest
   assertions against `.simdrive/fixtures/baselines/<version>/<flow>/<step>.json`.
   NOT mutation-killing (asserts against static JSON), but catches fixture corruption
   + drift between versions. Runs in the unit suite.

The three layers are complementary:

| Layer | Catches | Mutation-killing? |
|---|---|---|
| Fixture JSON + MarksFixture XCTest | Fixture drift, layout shifts | No |
| `simdrive-regress.sh` journey replay | Functional + perf regressions during a flow | Yes (drives live) |
| Replay corpus (`.simdrive/replays/chaos/`) on every PR via `chaos-replay-on-pr.yml` | Production regressions of fixed-once bugs | Yes (drives live) |
| Live chaos sessions (`run-chaos-pass.sh`) | New unknown bugs | Yes (drives live) |

### Per-area workflow (use this for each P0/P1 area)

### P0 — Critical Path (mandatory)

Walk through each P0 area one at a time:

1. **Tell the user what to test.** Read the test area description from the matrix.
2. **Ask what they see.** After they test, ask: "Any differences between baseline and candidate?"
3. **If they find something:**
   - Ask them to capture a screenshot pair (baseline + candidate)
   - Ask for naming: `F-NNN-baseline-description.png` / `F-NNN-candidate-description.png`
   - Help them write the CSV row. Set `Verified=false` initially.
   - Ask: "Can you verify this on the actual device right now?" If yes, set `Verified=true`.
4. **If no differences:** Mark the area as tested and move on.
5. **Track progress.** After each area, show how many P0 areas remain.

### P1 — Core Experience (mandatory)

Same process as P0. These cover reading, playback, sync, and catalog.

### P2 — Polish & Edge Cases (sample)

Ask the user: "Which P2 areas are relevant to the changes in this release?" Only test the areas they select.

## Phase 4: Finding Review

After all testing is complete:

1. Read the CSV and show a summary table:
   - Total findings by classification (regression, pre-existing, fixed, behavior-change)
   - How many are verified vs unverified
   - How many have severity blocker or major

2. For any unverified findings, ask: "Can you verify these now, or should we exclude them from the report?"

3. Ask: "Are there any findings you want to reclassify or remove?"

## Phase 5: Report Generation

Generate the HTML report:

```bash
scripts/regression-report.sh report \
  --output-dir ~/Desktop/regression-<TICKET> \
  --baseline-version <BASELINE> \
  --candidate-version <CANDIDATE> \
  --strict
```

If `--strict` fails (unverified findings), show which findings are unverified and ask the user what to do:
- Verify them now
- Remove them from the CSV
- Run without `--strict` (will include warning badges)

Open the report for review:
```bash
open ~/Desktop/regression-<TICKET>/report/index.html
```

Ask: "Does the report look correct? Any findings to adjust?"

## Phase 6: Jira Tickets

Generate Jira tickets from findings:

```bash
# Dry run first
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET> \
  --dry-run
```

Show the dry-run output and ask: "These tickets will be created. Proceed?"

If confirmed:
```bash
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET>
```

## Phase 7: Publishing

Ask the user where to publish the report:
1. GitHub Pages (push to `mauricecarrier7/pp-regression-reports`)
2. Local only (just the HTML file)
3. Confluence (provide instructions)

If GitHub Pages:
- Compress assets (video to 720p, PNGs to 800px) using ffmpeg and sips
- Push to the regression-reports repo
- Enable Pages if needed
- Provide the URL

Add the report URL as a comment on the parent Jira ticket.

## Rules

- **CSV is the contract.** All findings go into findings.csv. Report and tickets are generated from it.
- **Verified column matters.** Don't let unverified findings into the final report without flagging them.
- **Screenshot evidence for every finding.** If a finding doesn't have screenshots, ask the tester to capture them.
- **Compress media on capture.** 800px max width for screenshots, 720p for video.
- **Never create Jira tickets without showing dry-run first.**
- **Be encouraging.** Regression testing is tedious. Acknowledge progress and celebrate when blockers are found — that's the whole point.

## Quick Reference

| Classification | Jira Type | When to Use |
|---------------|-----------|-------------|
| `regression` | Bug | Worked in baseline, broken in candidate |
| `pre-existing` | Bug | Broken in both versions |
| `fixed` | N/A | Broken in baseline, fixed in candidate |
| `behavior-change` | N/A | Intentional change |
| `new-feature` | N/A | Only in candidate |
| `superseded` | N/A | Found to be incorrect |

| Severity | Jira Priority | Criteria |
|----------|--------------|----------|
| `blocker` | Blocker | Data loss, credential leak, unrecoverable |
| `major` | High | Core flow broken, painful workaround |
| `minor` | Normal | Noticeable but low impact |
| `cosmetic` | Low | Visual only |

# scripts/

Build, test, release, and quality-gate automation for the Palace iOS app. Most scripts in here are invoked by GitHub Actions workflows under `.github/workflows/`. A handful are developer-facing (run locally before opening a PR) and a handful are maintainer-internal (ForgeOS governance).

If you are an outside contributor, the only scripts you generally need to run by hand are listed under [Quick reference](#quick-reference). Everything else is invoked by CI on your behalf.

## Quick reference

| Task | Command |
|------|---------|
| Set up the repo with DRM (first-time clone) | `./scripts/setup-repo-drm.sh` |
| Set up the repo without DRM | `./scripts/setup-repo-nodrm.sh` |
| Build third-party dependencies | `./scripts/build-3rd-party-dependencies.sh` |
| Run unit tests the way CI does | `./scripts/xcode-test-optimized.sh` |
| Run the full pre-PR battery (build, test, lint, coverage, mutation) | `./scripts/verify-pr.sh` |
| Run pre-PR battery skipping mutation | `./scripts/verify-pr.sh --quick` |
| Generate release notes from git history | `./scripts/create-release-notes.sh` |
| Run mutation testing on a single file | `python3 scripts/palace_mutate.py --file Palace/Path.swift --tests PalaceTests/` |
| Lint test quality (find fluff tests) | `python3 scripts/lint-test-quality.py` |
| Count lines of code | `./scripts/count-loc.sh` |

## Categories

### Build and dependencies

| Script | What it does | Called by |
|--------|--------------|-----------|
| `setup-repo-drm.sh` | Initial repo setup with Adobe RMSDK / LCP wired in. | `unit-testing.yml`, `ui-testing.yml`, `upload.yml`, `upload-on-merge.yml` |
| `setup-repo-nodrm.sh` | Initial repo setup for the open-source `Palace-noDRM` target. | `non-drm-build.yml` |
| `build-3rd-party-dependencies.sh` | Builds non-Carthage third-party deps (Readium etc.). | `unit-testing.yml`, `ui-testing.yml`, `non-drm-build.yml`, `upload*.yml` |
| `build-carthage.sh` | Carthage bootstrap for binary frameworks (DRM path: also fetches AudioEngine + builds R2LCPClient). | invoked by `build-3rd-party-dependencies.sh` |
| `bootstrap-drm.sh` | Pulls Adobe RMSDK / LCP into the working tree. | dev/local |
| `fetch-audioengine.sh` | Fetches AudioEngine and unzips it into the build tree. | dev/local |
| `xcode-build-nodrm.sh` | Builds the `Palace-noDRM` scheme. | `non-drm-build.yml` |
| `xcode-archive.sh` | Creates a release archive of the app. | `upload*.yml` |
| `xcode-settings.sh` | Sources common build env vars. | `release-rc.yml`, dev/local |
| `xcode-export-adhoc.sh` | Exports an ad-hoc-signed `.ipa`. | `upload*.yml` |
| `xcode-export-appstore.sh` | Exports an App Store-signed `.ipa`. | `upload*.yml` |
| `archive-and-upload-adhoc.sh` | Archive + ad-hoc export + upload in one step. | dev/local |
| `add_palace_catalog_package.rb` | Wires the local PalaceCatalog SPM package into `Palace.xcodeproj`. | one-shot, dev/local |
| `add_palace_keychain_package.rb` | Wires PalaceKeychain SPM package into the project. | one-shot, dev/local |
| `add_palace_logging_package.rb` | Wires PalaceLogging SPM package into the project. | one-shot, dev/local |
| `pbxproj_add_swift.rb` | Canonical helper for adding Swift source files to both `Palace` + `Palace-noDRM` targets (replaces hand-editing the pbxproj). | dev/local |

### Test and coverage

| Script | What it does | Called by |
|--------|--------------|-----------|
| `xcode-test-optimized.sh` | Runs the full Palace test plan with caching and timeouts tuned for CI. | `unit-testing.yml` |
| `verify-pr.sh` | One-shot pre-PR battery: build, tests, lint, coverage, mutation, a11y. | dev/local (run before pushing) |
| `parse-xcresult.py` | Parses an `.xcresult` bundle into JSON for downstream reporting. | `unit-testing.yml`, `ui-testing.yml` |
| `parse-test-results.py` | Older test-results parser; kept for compatibility. | dev/local |
| `coverage-report.py` | Extracts code coverage from `.xcresult` and writes JSON. | `unit-testing.yml` |
| `coverage-floors.json` | Per-target coverage thresholds (see `README_coverage_floors.md`). | `enforce_coverage_floors.py` |
| `coverage-exclude.json` | Files excluded from the testable-coverage denominator (UI/lifecycle). | `coverage-report.py` |
| `enforce_coverage_floors.py` | Fails CI if any target drops below its floor. | `unit-testing.yml` |
| `test_coverage_classifier.py` | Classifies coverage gaps by surface type. | `coverage-report.py` |
| `test-history.py` | Compares this run against historical results to flag flakes/regressions. | `unit-testing.yml` |
| `generate-test-report.py` | Renders a Markdown test report from parsed JSON. | `unit-testing.yml` |
| `generate-html-report.py` | Renders an interactive HTML test report. | `unit-testing.yml` |
| `process-snapshots.py` | Generates a snapshot-failure viewer with diff images. | `unit-testing.yml` |
| `record-snapshots.sh` | Records baseline snapshots for snapshot-test classes. | dev/local |
| `test-visual-regression.sh` | End-to-end smoke test for the visual-regression infrastructure. | dev/local |
| `wire_orphan_tests.py` | Adds orphaned test files into the `PalaceTests` Sources phase. | dev/local (after extracting tests) |
| `wire_untracked_tests.py` | Wires fully-untracked test files into the Xcode project. | dev/local |

### simdrive (E2E sim driving)

| Script | What it does | Called by |
|--------|--------------|-----------|
| `simdrive-test.sh` | Builds Palace and runs the simdrive integration tests. | dev/local, chaos workflows |
| `simdrive-regress.sh` | Replays every `.simdrive/journeys/*.yaml` against a booted simulator. | `chaos-replay-on-pr.yml`, dev/local |
| `simdrive-coverage.sh` | Captures code coverage from simdrive runs and merges with unit coverage. | dev/local |
| `simdrive-report.sh` | Generates a Markdown report of simdrive replay results for PR evidence. | dev/local |
| `simdrive-structural-check.py` | OPDS-tolerant journey verifier (checks structure, not pixels). | `chaos-replay-on-pr.yml` |
| `fix-replay-assertions.py` | Trims `expect_elements` in replay YAMLs to stable, screen-appropriate elements. | dev/local (after recording) |
| `fix-replay-timing.py` | Removes `expect_elements` from steps where timing makes assertions unreliable. | dev/local |
| `marks-diff.py` | Diffs two simdrive fixture corpora and emits findings rows. | dev/local |
| `chaos-targets.py` | Maps changed file paths to fixture flow seeds whose mutation targets cover them. | `chaos-replay-on-pr.yml` |
| `run-chaos-pass.sh` | Runs a chaos QA pass (mutation + simdrive replay). | `chaos-qa-on-demand.yml` |

### Mutation and test-quality

| Script | What it does | Called by |
|--------|--------------|-----------|
| `palace_mutate.py` | Mutation testing harness: mutates a Swift file, runs tests, reports surviving mutants. | dev/local, `mutation-gate.yml` |
| `test_palace_mutate.py` | Unit tests for `palace_mutate.py` itself. | dev/local |
| `summarize-mutation-reports.py` | Aggregates per-file mutation reports into a single summary. | `mutation-gate.yml` |
| `regression-report.sh` | Orchestrates the regression-testing workflow (workspace + tools + report). | `mutation-gate.yml`, dev/local |
| `generate-regression-report.py` | Renders an interactive HTML regression report from a findings CSV. | `regression-report.sh` |
| `generate-jira-tickets.py` | Creates Jira tickets from a regression-findings CSV. | dev/local (post-regression) |
| `lint-test-quality.py` | Static linter that flags fluff tests (tautologies, no-op asserts, etc.). | dev/local, pre-PR check |

### Performance

| Script | What it does | Called by |
|--------|--------------|-----------|
| `run-perf-suite.sh` | Runs Allocations / Leaks / Time Profiler traces on a physical device while the walker drives the app. | dev/local |
| `perf-walker-device.py` | Appium walker that drives Palace through major flows on a real device. | `run-perf-suite.sh`, dev/local |
| `browserstack-screenshot-walker.py` | Drives Palace on BrowserStack devices and captures screenshots. | dev/local |

### Code quality

| Script | What it does | Called by |
|--------|--------------|-----------|
| `accessibility-lint.sh` | Runs AccessLint accessibility analysis on the project. | `ledger.yml` |
| `a11y-coverage.py` | Measures VoiceOver label coverage against a simdrive fixture. | dev/local |
| `count-loc.sh` | Reports lines of code by language using `scc`. | dev/local |

### Release and TestFlight

| Script | What it does | Called by |
|--------|--------------|-----------|
| `create-release-notes.sh` | CI-side wrapper that activates a venv and calls `release-notes.sh` for both `RELEASE_NOTES.md` and `CHANGELOG.md`. | `release.yml`, `release-rc.yml`, `release-on-merge.yml`, `upload*.yml` |
| `release-notes.sh` | Walks git history (`fetch-depth: 0` required) to build release notes from commit messages. | `create-release-notes.sh`, RELEASING.md |
| `ios-check-version.sh` | Validates the build number against tags before upload. | `upload*.yml`, `check-build-number.yml` |
| `ios-binaries-check.sh` | Checks whether a binary with the current build number already exists. | `check-build-number.yml` |
| `ios-binaries-upload.sh` | Uploads exported `.ipa` to the Palace binaries bucket. | `upload*.yml` |
| `firebase-upload.sh` | Uploads an `.ipa` to Firebase App Distribution. | `upload*.yml` |
| `firebase-upload-symbols.sh` | Uploads dSYMs to Firebase. | `upload*.yml` |
| `testflight-upload.sh` | Uploads an `.ipa` to TestFlight. | `upload*.yml` |
| `install-profile.sh` | Installs a distribution provisioning profile on the CI runner. | `upload*.yml` |
| `decode-install-secrets.sh` | Creates a build keychain and installs the Apple distribution identity. | `upload*.yml` |
| `update-certificates.sh` | Refreshes the developer certificates checked into `mobile-certificates`. | dev/local |
| `firebase/` | Firebase CLI helpers and config. | `firebase-upload*.sh` |

### Crash and Jira reporting

| Script | What it does | Called by |
|--------|--------------|-----------|
| `fetch-crashlytics.py` | Pulls crash data from GA4 Analytics for Palace iOS. | dev/local (weekly check) |
| `update-crashlytics-report.py` | Updates the PP-4020 report HTML with fresh Crashlytics data. | dev/local |
| `jira-integration.sh` | Helpers for transitioning Jira tickets and adding fix comments from CI. | `jira-pr-opened.yml`, `jira-update-on-merge.yml` |
| `test-push-notifications.py` | Test harness for sending push notifications to a development build. | dev/local |

### ForgeOS governance (maintainer-only)

These are maintainer scripts; outside contributors do not run them. ForgeOS is the governance system that enforces gates on commits, pushes, and PRs. See `CLAUDE.md` for context.

> **Maintainer note:** Existing local sessions need `export FORGEOS_API_URL=<your-forgeos-instance>` in `~/harness/.env` (or wherever you keep your env). Without it, the three forgeos scripts (`forgeos-session.sh`, `forgeos-orchestrate.sh`, `forgeos-gate-hook.sh`) will fail loud with a message pointing back at this README.

| Script | What it does | When |
|--------|--------------|------|
| `forgeos-session.sh` | Per-session governance: start, evidence, promote, close changesets. | every maintainer session that produces code |
| `forgeos-orchestrate.sh` | Multi-agent orchestration extension on top of `forgeos-session.sh`. | multi-agent / multi-task sessions |
| `forgeos-gate-hook.sh` | Pre-PR gate check, called by the Claude Code hook before `gh pr create`. | automatic via hook |
| `forgeos-bootstrap-palace-evolution.sh` | One-time bootstrap that creates the Palace evolution initiative + changesets. | one-time bootstrap |
| `forgeos-apply-palace-gate-template.sh` | One-time setup that applies the Palace gate template to the ForgeOS project. | one-time setup |
| `forgeos-full-suite.sh` | Ad-hoc smoke run that exercises every ForgeOS gate against the current branch. | gate-template development |

### git hooks

There are two hook directories with different audiences. Do not confuse them.

- **`scripts/git-hooks/`** — portable, committed to the repo. Outside contributors install these by running `git config core.hooksPath scripts/git-hooks` (see `CONTRIBUTING.md`). They run lint and basic sanity checks. Safe on any clone.
- **`scripts/hooks/`** — symlinks into Maurice's local `~/harness/` workspace. **Do not run, copy, or wire these on a fresh clone** — they hard-depend on the harness, ForgeOS API keys, and a specific dev-machine layout. They will fail loudly on any other machine. Listed here only for transparency.

If `scripts/git-hooks/` does not exist in your clone, see `CONTRIBUTING.md` for the current hook-install instructions.

## Archived scripts

`scripts/_archive/` contains historical one-shots kept purely for archaeology. **Do not run them.**

- `_archive/pbxproj/` — file-add / duplicate-fix scripts from past extraction sprints. Their target file counts are baked in (e.g. "76 new Swift files"); they would corrupt the project file if re-run. Also includes `_add_palace_auth_package.rb` (one-shot Phase 6 PalaceAuth wiring helper).
- `_archive/one-offs/` — `xcode-test.sh` (superseded by `xcode-test-optimized.sh`), `objc-cutover*.py` (one-shot Objective-C → Swift migration tools), `build-carthage-R2-integration.sh` (R2 integration variant — references `r2-shared-swift@2.0.0-beta.1` and the old Simplified-iOS sibling layout, neither of which exist anymore).

If you need the behavior of one of these scripts, copy + adapt into a new file rather than running the archived version directly.

## See also

- `verify-pr.sh` is the load-bearing local-dev gate; read its header for the full check list.
- `CLAUDE.md` documents the build invocations, project layout, and DRM/no-DRM target split.
- `RELEASING.md` documents the release-notes flow that ties `create-release-notes.sh` and `release-notes.sh` together.
- `.github/workflows/` is the source of truth for which scripts CI calls; if a script is not referenced in any workflow under there, it is dev-local or archived.

# scripts/

Build, test, release, and quality-gate automation for the Palace iOS app. Most scripts in here are invoked by GitHub Actions workflows under `.github/workflows/`. A handful are developer-facing (run locally before opening a PR) and a handful are maintainer-internal (ForgeOS governance).

If you are an outside contributor, the only scripts you generally need to run by hand are listed under [Quick reference](#quick-reference). Everything else is invoked by CI on your behalf.

## The five workhorses

These five scripts handle most of the day-to-day work. Read these first if you only have time for five:

| Script | Purpose | When you'll touch it |
|--------|---------|----------------------|
| **`verify-pr.sh`** | One-shot pre-PR battery (build, tests, lint, coverage, mutation, a11y). | Before every `gh pr create`. Run `--quick` to skip mutation. |
| **`pre-push-test-gate.sh`** | Pre-push hook that runs the changed-file test selection before allowing a push. | Automatic via git hook; tune timeouts when CI lag surfaces. |
| **`lint-test-quality.py`** | Static linter for fluff/flake test patterns. Supports `// lint-ignore: FLUFF-XXX` per-line markers. | Every test PR — failures here block CI. |
| **`snapshot-library-registry.py`** | Snapshots the library registry (account JSON) and produces a diff against the live registry. | Account/auth-doc churn investigations; weekly drift checks. |
| **`palace_mutate.py`** | Mutation-testing harness (mutate Swift file, run tests, report surviving mutants). | Anything on a critical path (sign-in, borrow, download, DRM). |

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
| Export an archive for ad-hoc or App Store distribution | `./scripts/xcode-export.sh --format <adhoc\|appstore>` |

## Categories

### Build and dependencies

| Script | What it does | Called by |
|--------|--------------|-----------|
| `setup-repo-drm.sh` | Initial repo setup with Adobe RMSDK / LCP wired in. | `unit-testing.yml`, `upload.yml`, `upload-on-merge.yml` |
| `setup-repo-nodrm.sh` | Initial repo setup for the open-source `Palace-noDRM` target. | `non-drm-build.yml` |
| `build-3rd-party-dependencies.sh` | Builds non-Carthage third-party deps (Readium etc.). | `unit-testing.yml`, `non-drm-build.yml`, `upload*.yml` |
| `build-carthage.sh` | Carthage bootstrap for binary frameworks (DRM path: also fetches AudioEngine + builds R2LCPClient). | invoked by `build-3rd-party-dependencies.sh` |
| `bootstrap-drm.sh` | Pulls Adobe RMSDK / LCP into the working tree. | dev/local |
| `fetch-audioengine.sh` | Fetches AudioEngine and unzips it into the build tree. | dev/local |
| `xcode-build-nodrm.sh` | Builds the `Palace-noDRM` scheme. | `non-drm-build.yml` |
| `xcode-archive.sh` | Creates a release archive of the app. | `upload*.yml` |
| `xcode-settings.sh` | Sources common build env vars. | `release-rc.yml`, dev/local |
| `xcode-export.sh` | Unified export driver. `--format adhoc` or `--format appstore`. Sources `xcode-settings.sh` once, branches on format. | invoked by the two shims below; new call sites should use this directly |
| `xcode-export-adhoc.sh` | Thin shim → `xcode-export.sh --format adhoc`. Kept so `upload*.yml` CI workflows don't break. | `upload*.yml` |
| `xcode-export-appstore.sh` | Thin shim → `xcode-export.sh --format appstore`. Kept so `upload*.yml` CI workflows don't break. | `upload*.yml` |
| `add_palace_catalog_package.rb` | Wires the local PalaceCatalog SPM package into `Palace.xcodeproj`. | one-shot, dev/local |
| `add_palace_keychain_package.rb` | Wires PalaceKeychain SPM package into the project. | one-shot, dev/local |
| `add_palace_logging_package.rb` | Wires PalaceLogging SPM package into the project. | one-shot, dev/local |
| `pbxproj_add_swift.rb` | Canonical helper for adding Swift source files to both `Palace` + `Palace-noDRM` targets (replaces hand-editing the pbxproj). | dev/local |

### Test and coverage

| Script | What it does | Called by |
|--------|--------------|-----------|
| `xcode-test-optimized.sh` | Runs the full Palace test plan with caching and timeouts tuned for CI. | `unit-testing.yml` |
| `verify-pr.sh` | One-shot pre-PR battery: build, tests, lint, coverage, mutation, a11y. | dev/local (run before pushing) |
| `pre-push-test-gate.sh` | Pre-push hook that runs the changed-file test selection before allowing `git push`. | local git hook |
| `resolve-tests-for.py` | Maps a changed production-file path to the XCTest class selectors that cover it. | `verify-pr.sh`, `palace_mutate.py` |
| `parse-xcresult.py` | Parses an `.xcresult` bundle into JSON for downstream reporting. | `unit-testing.yml` |
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
| `wire_orphan_tests.py` | Adds orphaned test files into the `PalaceTests` Sources phase. | dev/local (after extracting tests) |
| `wire_untracked_tests.py` | Wires fully-untracked test files into the Xcode project. | dev/local |


### Mutation and test-quality

| Script | What it does | Called by |
|--------|--------------|-----------|
| `palace_mutate.py` | Mutation testing harness: mutates a Swift file, runs tests, reports surviving mutants. | dev/local |
| `test_palace_mutate.py` | Unit tests for `palace_mutate.py` itself. | dev/local |
| `generate-jira-tickets.py` | Creates Jira tickets from a regression-findings CSV. | dev/local (post-regression) |
| `lint-test-quality.py` | Static linter that flags fluff tests (tautologies, no-op asserts, etc.). | dev/local, pre-PR check |

### Code quality

| Script | What it does | Called by |
|--------|--------------|-----------|
| `snapshot-library-registry.py` | Snapshots the library registry JSON and diffs against live; surfaces account/auth-doc drift. | dev/local, drift-investigation |
| `check_registry_snapshot_freshness.sh` | CI guard that fails if the committed registry snapshot is older than the live registry. | `ledger.yml` |
| `export-module-contracts.py` | Emits module public-API contracts to `.forgeos/contracts/<module>.json`; consumed by the architect agent and `verify-pr.sh --check`. | dev/local, swarm |
| `crashlytics-sentinel.py` | Compares Crashlytics issue counts week-over-week and alerts on new top issues. | `crashlytics-sentinel.yml` |

### Release and TestFlight

| Script | What it does | Called by |
|--------|--------------|-----------|
| `create-release-notes.sh` | CI-side wrapper that activates a venv and calls `release-notes.sh` for both `RELEASE_NOTES.md` and `CHANGELOG.md`. | `release.yml`, `release-rc.yml`, `release-on-merge.yml`, `upload*.yml` |
| `release-notes.sh` | Walks git history (`fetch-depth: 0` required) to build release notes from commit messages. | `create-release-notes.sh`, RELEASING.md |
| `ios-check-version.sh` | Validates the build number against tags before upload. | `upload.yml`, `upload-on-merge.yml` |
| `ios-binaries-check.sh` | Checks whether a binary with the current build number already exists. | dev/local (no workflow calls it) |
| `ios-binaries-upload.sh` | Uploads exported `.ipa` to the Palace binaries bucket. | `upload*.yml` |
| `testflight-upload.sh` | Uploads an `.ipa` to TestFlight. | dev/local (manual maintainer run) |
| `install-profile.sh` | Installs a distribution provisioning profile on the CI runner. | `upload*.yml` |
| `update-certificates.sh` | Refreshes the developer certificates checked into `mobile-certificates`. | dev/local |

### Crash and Jira reporting

| Script | What it does | Called by |
|--------|--------------|-----------|
| `fetch-crashlytics.py` | Pulls crash data from GA4 Analytics for Palace iOS. | dev/local (weekly check) |
| `update-crashlytics-report.py` | Updates the PP-4020 report HTML with fresh Crashlytics data. | dev/local |
| `jira-integration.sh` | Helpers for transitioning Jira tickets and adding fix comments from CI. | `jira-pr-opened.yml`, `jira-update-on-merge.yml` |
| `test-push-notifications.py` | Test harness for sending push notifications to a development build. | dev/local |

### ForgeOS governance — moved out of this repo (2026-08-26)

The five `forgeos-*` scripts that used to live here now live in the maintainer's
local harness at `~/harness/stacks/ios/forgeos/`.

They were never runnable from a clone: every one of them talks to a private
ForgeOS API instance via `FORGEOS_API_URL` and a key no outside contributor has.
Keeping 1,330 lines of them in a public repository advertised a workflow nobody
reading this could follow, and cost every doc-reference sweep and shell-syntax
gate a walk through code that could not execute. ForgeOS is also currently
switched off for this project, so they were not running for maintainers either.

The rule they failed is the one this repository already states: only tooling any
contributor can run unaided belongs here. `verify-pr.sh`, the standalone
detectors, and `palace_mutate.py` pass that test and stay.


The previous one-shot bootstrap scripts (`forgeos-bootstrap-palace-evolution.sh`,
`forgeos-apply-palace-gate-template.sh`, `forgeos-full-suite.sh`,
`palace-agentic-readiness-scan.sh`) were removed as zombie scripts —
they had zero callers in CI, fastlane, or other scripts and had not run
since the original Palace evolution bootstrap. If you need the bootstrap
flow again, replay it via the ForgeOS MCP (`mcp__forgeos__forge_init`).

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

## QA / regression harness (not in this repo)

The simulator-driving QA apparatus — chaos passes, regression campaign
fan-out, simdrive journey replay and the visual-diff tooling — is
maintainer-local and lives outside this repo. It needs a driven simulator
and an agent runner, so no CI job and no clean clone can run it. Nothing
here depends on it.

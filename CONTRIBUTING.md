# Contributing to Palace iOS

Thanks for your interest in The Palace Project. This file is the public-facing
guide for outside contributors.

## Quick start

```bash
# Clone and branch from develop (never main)
git clone git@github.com:ThePalaceProject/ios-core.git
cd ios-core
git checkout develop
git checkout -b feat/your-change

# Set up dependencies — pick one:
./scripts/setup-repo-nodrm.sh    # open-source build (Palace-noDRM target)
./scripts/bootstrap-drm.sh       # full DRM build (requires private repo access)

# Install the committed git hooks (one-time, optional but recommended)
git config core.hooksPath scripts/git-hooks

# Open the project
open Palace.xcodeproj
```

The hooks under `scripts/git-hooks/` are lightweight: they reject obvious
secret leaks, warn before pushing without a self-check, and gracefully no-op
when optional internal tooling is not installed.

See [`README.md`](./README.md) for the full system requirements (Xcode 26,
Carthage; Apple Silicon builds DRM natively, no Rosetta needed).

## Before opening a PR

1. **Write tests first.** Production changes require tests. The TDD discipline
   and the test-quality rules (no fluff, no tautologies, mutation-aware) are
   documented in the
   [TDD & Test Quality](./CLAUDE.md#tdd--test-quality--mandatory)
   section of `CLAUDE.md` and in [`TESTING.md`](./TESTING.md). Read them before
   writing tests for an unfamiliar area.
2. **Run the local self-check.**
   ```bash
   scripts/verify-pr.sh --quick
   ```
   This runs the same battery CI does (build, unit tests, lint, coverage,
   snapshots, accessibility) but skips mutation testing. It is the single
   command outside contributors need to pass before opening a PR.
3. **Fill out the PR template.** What, Why, How verified, and optionally Not
   done — about 20 lines. Attach before/after screenshots for UI changes.
   Commit and PR conventions are in
   [`.github/COMMIT_AND_PR_FOR_JIRA.md`](./.github/COMMIT_AND_PR_FOR_JIRA.md).
4. **Target `develop`.** Never open a PR against `main` directly. Release
   branches are cut from `develop` by maintainers.

## Local automation vs CI — the honest gap

This repo has two layers of automation.

### CI gates (run on every PR)

The workflows under [`.github/workflows/`](./.github/workflows) run on every
pull request. Build, unit tests and coverage floors make up the
`build-and-test` check; tooling checks fail their own check; the rest report
without failing a run:

- Build (Palace and Palace-noDRM targets)
- Unit tests
- Coverage floors (`scripts/enforce_coverage_floors.py`): an app floor (overall
  or per-module) more than 1.5 points below its value fails `build-and-test`,
  and so does incomplete coverage data (for example a missing result bundle or
  a planned test class that did not run), which is reported as INCOMPLETE
  rather than as a pass. Package floors are reported but advisory, because
  their measurements vary between runs of identical code. See
  [`scripts/README_coverage_floors.md`](./scripts/README_coverage_floors.md).
- Screenshot captures, stored as artifacts with no comparison gate (the JSON
  contract-snapshot tests run with the unit tests and do block)
- Tooling checks (`tooling-checks.yml`: test-quality lint, doc reference,
  index and hygiene checks), which fail the run on a violation
- Accessibility lint, reported through the ledger (non-blocking)

A red CI run means do not merge, regardless of who opened the PR. GitHub does
not enforce this: `develop` and `main` have no branch protection, so the rule
holds only if whoever merges checks CI first (`CLAUDE.md`, "Red means stop").

Mutation testing and simulator-driven E2E are **not** CI gates. Both need
something CI does not have — a booted simulator for E2E, and a long serial run
for mutation — so they are local pre-PR steps (`scripts/palace_mutate.py`,
`scripts/verify-pr.sh --simdrive --chaos`). Nothing in CI enforces them.

### Local self-check (anyone can run)

```bash
scripts/verify-pr.sh --quick
```

Same checks as CI minus mutation testing, all run against a single iPhone
simulator. Use this before pushing to catch breakage locally instead of
burning a CI cycle.

## AI-assisted development

The maintainers use AI-assisted development. Every change is reviewed and
tested by the maintainer who lands it, and PRs and commits carry no per-change
AI attribution.

## Where to learn more

- [`README.md`](./README.md) — system requirements, build instructions for
  both DRM and no-DRM targets, branching conventions.
- [`TESTING.md`](./TESTING.md) — test layout, mocking patterns, how to run
  individual test classes.
- [`docs/architecture/README.md`](./docs/architecture/README.md) — design
  decisions behind the major refactors (architectural triad, AppContainer,
  reducer pattern, parallel-agent rebases).
- [`docs/Testing/TESTING_POSTURE.md`](./docs/Testing/TESTING_POSTURE.md) —
  full testing posture, confidence matrix, and known coverage gaps.
- [`RELEASING.md`](./RELEASING.md) — release process and version-bump
  conventions.
- [`CLAUDE.md`](./CLAUDE.md) — AI-agent-facing reference. Most useful if you
  are collaborating with Claude Code on this repo; outside contributors can
  treat it as background reading.

## Reporting issues / questions

Open an issue on the public repo:
[ThePalaceProject/ios-core/issues](https://github.com/ThePalaceProject/ios-core/issues).
Please include the iOS version, device, app version (Settings → tap version
seven times for developer info), and steps to reproduce. For security issues,
do not open a public issue — contact the project maintainers directly via the
contact info on [thepalaceproject.org](https://thepalaceproject.org).

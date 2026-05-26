# Contributing to Palace iOS

Thanks for your interest in The Palace Project. This file is the public-facing
guide for outside contributors. If you are a maintainer, you will additionally
use the agent-driven workflow described in `CLAUDE.md` — but none of that is
required to land a PR from the outside.

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
3. **Fill out the PR template.** The `Verification` checklist asks for the
   self-check, before/after screenshots for UI changes, and confirmation that
   both the `Palace` and `Palace-noDRM` targets build for cross-cutting
   changes. The "Internal-only checklist" section is for maintainers — leave
   it blank if it does not apply to you.
4. **Target `develop`.** Never open a PR against `main` directly. Release
   branches are cut from `develop` by maintainers.

## Local automation vs CI — the honest gap

This repo has three layers of automation. Only the first two matter for
outside contributors.

### CI gates (run on every PR, enforced by GitHub)

The workflows under [`.github/workflows/`](./.github/workflows) gate every
pull request:

- Build (Palace and Palace-noDRM targets)
- Unit tests
- Coverage floors (`scripts/enforce_coverage_floors.py`)
- Snapshot tests
- Lint / accessibility lint
- Chaos replay on PR (simdrive-driven E2E regression for critical flows)
- Mutation gate on changed Swift files

A red CI run blocks merge regardless of who opened the PR.

### Local self-check (anyone can run)

```bash
scripts/verify-pr.sh --quick
```

Same checks as CI minus mutation testing, all run against a single iPhone
simulator. Use this before pushing to catch breakage locally instead of
burning a CI cycle.

### Agent-driven workflow (maintainer-internal, not required for outside PRs)

The maintainers use a Claude-Code-based agent harness day-to-day. This shows
up in the codebase as:

- `forge_init`, `forge_propose_changeset`, `forge_release_check` references
  in `CLAUDE.md` — that is **ForgeOS governance**, an internal changeset and
  evidence tracker.
- `harness test`, `harness simdrive` references — that is the **harness**,
  a local-only orchestration layer at `~/harness/` not in this repo.
- `simdrive` MCP tools — used internally to drive the iOS simulator for E2E
  regressions. The recorded artifacts under `.simdrive/` ARE in the repo and
  are exercised by CI; the recording tooling is internal.

**None of this gates outside PRs.** If you do not have ForgeOS, the harness,
or simdrive set up, you can ignore every reference to them in `CLAUDE.md`
and still open a perfectly mergeable PR. The committed git hooks under
`scripts/git-hooks/` will not call out to any of that internal tooling —
they degrade to plain Bash checks.

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

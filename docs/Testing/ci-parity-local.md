# Local CI-parity test harness

**Goal:** reproduce GitHub Actions `macos-15` test conditions on a local
(many-core) Mac so CI-only flakes/crashes reproduce and verify **before** a
PR/merge — instead of costing a ~45-minute GitHub cycle each.

## Why a fast Mac hides CI failures

GitHub's `macos-15` runners have **~3 vCPUs**. A dev Mac has many more (24+).
`scripts/xcode-test-optimized.sh` requests `-maximum-parallel-testing-workers 4`.
On the 3-core runner that **oversubscribes the CPU**, so:

- **Deadline-poll starvation** — a test that waits on fire-and-forget async work
  via a wall-clock/hop deadline loses the CPU race, blows its own 5s/6-hop
  deadline, and fails all 3 retries. A different victim starves each run → the
  board looks "randomly" red.
- **Off-main `@MainActor` SIGTRAP** — a leaked off-main task only crashes a clone
  under the full ~7k-test interleaving.

On a 24-core Mac the same run has ample CPU and never runs the full suite in one
process/pool, so **neither reproduces** — `-only-testing` subsets always pass.
That is the trap behind "green on my machine, red on CI."

## The harness

`scripts/ci-parity-local.sh` closes both gaps:

1. Runs the **exact CI script** (`scripts/xcode-test-optimized.sh`, full suite,
   identical flags, parallel + serial-isolated passes, merged xcresult) so the
   crash-triggering interleaving is present.
2. Pins the run to `CI_PARITY_CORES` effective cores via CPU pressure
   (busy-loop burners occupy `ncpu - CI_PARITY_CORES` cores) so the starvation
   that surfaces the deadline-poll flakes is present.
3. Applies the **same gate** CI applies — parses `TestResults.xcresult` with
   `scripts/parse-xcresult.py` and fails on `summary.failed > 0` (any test that
   failed all 3 retries). A pass here means a pass there.

```bash
scripts/ci-parity-local.sh                              # default: 3 cores, 2 workers
CI_PARITY_CORES=3 CI_PARITY_WORKERS=2 scripts/ci-parity-local.sh
CI_PARITY_NO_PRESSURE=1 scripts/ci-parity-local.sh      # full suite, no CPU pinning
PALACE_TEST_NO_CLEAN=1 scripts/ci-parity-local.sh       # reuse the current build (faster iteration)
```

On pass it stamps the commit (`.git/ci-parity-pass.sha`) so the gate below can
require it.

## Systemic gate — parity must pass before PR/merge

`scripts/check-ci-parity-stamp.sh` blocks a push whose range changes production
Swift (`Palace/**/*.swift`, excluding tests) unless `ci-parity-local.sh` has
passed on that **exact** commit. Test-only / docs / scripts / config changes are
exempt (they can't introduce the runtime flake class this protects).

Bypass (logged): `SKIP_CI_PARITY=1 git push …` — only for a docs/test-only
follow-up on an already-verified commit, or an out-of-band-verified hotfix.
Overuse defeats the gate (see CLAUDE.md "green-board contract").

**Wiring (opt-in):** call the gate from your pre-push hook, e.g. prepend to
`scripts/pre-push-test-gate.sh` or add to your local hook:

```bash
scripts/check-ci-parity-stamp.sh || exit 1
```

## Debugging a reproduced failure

- **Deadline-poll starvation** (`XCTAssert … 0 vs 1`, or a `fulfillment`/
  `awaitCondition` timeout): convert the test to a deterministic Task-join — see
  the pattern in `AccountsManager._awaitAllCrawlTasksForTesting`,
  `CatalogRepository._awaitAllBackgroundRefreshesForTesting`,
  `TokenRefreshInterceptor._awaitAuthDispatchForTesting` (all XCTest-gated,
  RELEASE byte-identical).
- **`failed … (0.000 seconds)` + a clone process restart**: crash-collateral —
  an earlier test leaked an off-main `@MainActor` task that SIGTRAPs the clone.
  The 0.000s victim is innocent; find the leaker (the last test to run on the
  crashed clone process before the restart) and fix its isolation
  (`@Sendable` / `.receive(on: .main)` / `await MainActor.run`).

## Fidelity caveats

macOS has no hard per-process core cap, so CPU pressure is an *approximation* of
the runner (the scheduler still hands the test some burner-core slices). It
amplifies the starvation reliably but timing is not bit-identical. Treat a
parity **failure** as a real CI failure; treat a parity **pass** as high
confidence, not a proof — GitHub CI remains authoritative.

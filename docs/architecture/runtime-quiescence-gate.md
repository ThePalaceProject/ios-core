<!-- audit-verified -->
# Runtime-quiescence gate — preventing cross-test cooperative-pool starvation

**Status:** Proposed (awaiting Chairman ratification)
**Date:** 2026-06-11
**Workstream:** WS-0 / M0 (3.2.0 release gate)
**Scope:** test-target only (`PalaceTests`); zero production-code behaviour change

## Context

The unit suite intermittently timed out: an async test would exceed its
watchdog (CatalogPreloaderTests ~60s, OpenAccessAdapterTests ~163s, a
CatalogRepository `testIntegration_FullFetchFlow` 1735s outlier) and the
**victim varied from run to run**. CI PR #1063 failed all three retries on a
single-sim runner, proving the failure is a real, single-process defect — not a
fleet/sim-collision artifact.

### Root cause (already fixed in production; this gate is the backstop)

`AccountsManager.deferInitialLoadCatalogsForTesting` is a process-global flag.
While `true` (the test-safe default pinned by `PalaceTestSetup.bootstrap()`),
every `AccountsManager.init` — including the one
`AppContainer._resetForTesting()` rebuilds after **each** test — skips the
background `loadCatalogs` Task. While `false`, that init spawns a live registry
crawl on a detached background Task.

If a test sets the flag `false` and does not restore it, the value leaks
forward: the next test class's first `AppContainer.production()` read rebuilds
the cached graph, whose fresh `AccountsManager` now reads `false` and starts a
crawl Task that outlives the test, leaks past the boundary, and **starves the
shared cooperative pool / main queue**. Whichever async test runs while the
pool is saturated is the victim — hence "victim varies per run."

That root cause was fixed in production across PRs #1050/#1051/#1056/#1057/#1061
(both known leak sites now leave the flag `true`). **This gate does not fix the
bug — it makes the bug class structurally impossible to reintroduce silently.**

### Why "victim varies per run" — confirmed at the scheme level

`Palace.xcscheme` runs `testExecutionOrdering = "random"` (lines 88 and 99).
The suite is shuffled every run, so a leaked-flag polluter saturates the pool at
a different point each time and a different async test times out. This is the
mechanism, not a coincidence — and it dictates the gate's shape (below).

## Decision

A two-layer, deterministic, order-independent gate, reusing the existing
test-isolation hierarchy rather than building a parallel one:

1. **`PalaceTestCase: XCTestCase`** (`PalaceTests/Support/PalaceTestCase.swift`)
   — its `tearDownWithError` calls `super` first, then asserts runtime
   quiescence (currently: `deferInitialLoadCatalogsForTesting == true`). A real
   `XCTFail` inside the offending test's own lifecycle, so the failure is
   **attributed to the polluter** and **reddens the run deterministically under
   randomized order**. `PalaceWiringTestCase` now inherits `PalaceTestCase`, so
   the wiring suite gets the assert for free (one hierarchy).

2. **`RuntimeQuiescenceLintTests`** (`PalaceTests/MetaTests/`) — the structural
   backstop that makes layer 1's opt-in adoption **mandatory** for the tests
   that can violate the invariant: any `PalaceTests` file containing a real
   (non-comment, non-string) `deferInitialLoadCatalogsForTesting = false`
   assignment must not declare a direct `XCTestCase` subclass — it must extend
   the quiescence base. Broad pattern match across all of `PalaceTests`, not a
   hard-coded file list. Self-tested on BAD, GOOD, and CLEAN inputs.

The three current false-setters (`AppContainerResetTests`,
`TestAppContainerFactoryTests`, `RuntimeQuiescenceGateTests`) were migrated to
`PalaceTestCase`; all restore the flag (via `tearDown`/`defer`) and pass the
inherited assert.

### Assert-after-super (a real ordering bug we caught)

`XCTestCase.tearDownWithError()` invokes the subclass's `tearDown()`, where
flag-flippers restore the flag. So the quiescence assert MUST run **after**
`super.tearDownWithError()`; asserting before would false-fail a class that
correctly restores in `tearDown()`. Verified empirically.

## What the gate DOES and does NOT catch (honest scope)

**DOES:**
- A test that sets `deferInitialLoadCatalogsForTesting = false` (literal) and
  forgets to restore it — caught at runtime by `PalaceTestCase.tearDown`
  (if adopted) and forced to adopt by the lint (structurally).
- Any non-quiescence state the auditor grows to check later — `PalaceTestCase`
  is the single extension point; new invariants added to
  `RuntimeQuiescenceAuditor` apply to every adopting test automatically.

**DOES NOT (named residuals — not silent gaps):**
- **Indirection.** A test that leaves the flag `false` via a *helper* or a
  *non-literal RHS* (`deferInitialLoadCatalogsForTesting = someBoolVar`, or a
  shared setUp in another file that sets it `false`) is NOT caught by the lint —
  the lint matches the literal `= false` textually. The **runtime** assert still
  catches it *if* the class subclasses `PalaceTestCase`; a non-adopting class
  that flips the flag only via indirection escapes both layers. No current test
  does this; if one is added, prefer extending the lint to flag any
  non-`true` assignment, or route flag changes through a gated helper.
- **Non-flag quiescence leaks.** Un-cancelled detached Tasks, leaked
  `NotificationCenter` observers, dirty on-disk catalog cache, and
  `.shared`/`UserDefaults.standard` bleed are NOT this gate's concern. They
  remain covered by the existing `TearDownRequiredLintTests`,
  `AccountsManagerIsolationLintTests`, and `PalaceWiringTestCase` machinery.
  The defer flag is the single *documented* starvation root cause; this gate
  closes exactly that class.

## Three inertness traps we caught before shipping a fake gate

This gate went through three silent-no-op forms, each caught by an **empirical
RED→GREEN wiring proof** (a synthetic polluter that must fail) rather than by
"it compiles / it's green." Recording them so the next person cannot rebuild an
inert gate:

1. **Inert observer `record()`.** The first design failed the run from
   `XCTestObservation.testCaseDidFinish` via `XCTestCase.record(XCTIssue(...))`.
   Empirically, recording an issue against an already-finished test from that
   hook is **silently dropped** — the synthetic polluter passed. A non-failing
   "gate" is the canonical inert-gate anti-pattern. Fix: fail inside the test's
   own `tearDown`.
2. **Randomized order defeats a trailing "final gate."** The second design
   accumulated breaches and asserted in a `ZZZZ…`-named class meant to sort
   last. Under `testExecutionOrdering = "random"`, the "final" gate ran *first*
   and saw an empty accumulator. No statically-named class is guaranteed last.
   Fix: per-test `tearDown`, which holds under any order.
3. **`#if DEBUG` compiling to a no-op.** The auditor guarded its flag read with
   `#if DEBUG`. The **`PalaceTests` target does not define `DEBUG`** (its
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` is `LCP FEATURE_OVERDRIVE`), so the
   guard compiled to the `#else` constant `true` and the whole gate read clean
   forever. Fix: reference the flag directly (it is reachable via
   `@testable import Palace` because the main module *is* built with `DEBUG`),
   matching how `AppContainerResetTests` already references it. This also aligns
   with the blast-radius rule against `#if DEBUG` seams — gate on
   `XCTestConfigurationFilePath`, never `#if DEBUG`.

**Lesson:** a test-isolation gate must be proven to FAIL a known polluter (RED)
*and* pass clean (GREEN) before it is trusted. "Compiles" and "suite green" are
both satisfied by an inert gate.

## Alternatives considered

- **Global auto-fail from the observer** — rejected: `record()` is inert from
  `testCaseDidFinish` (trap #1).
- **Trailing final-gate test** — rejected: randomized order (trap #2).
- **Force-migrate every test onto `PalaceTestCase`** — rejected: ~200 classes,
  high risk, no payoff (only flag-setters can violate the invariant; the lint
  covers them).
- **Disable `testExecutionOrdering = "random"`** — rejected here: randomized
  order is a *feature* (it surfaces order-dependent pollution); re-enabling
  determinism is a separate, already-scoped initiative.

## Consequences

- New tests that need the background catalog load must subclass `PalaceTestCase`
  (or `PalaceWiringTestCase`) — enforced by `RuntimeQuiescenceLintTests`.
- `RuntimeQuiescenceAuditor` is the single place to add future quiescence
  invariants; every adopting test inherits them.
- Zero production-code change; no runtime cost in shipping builds.

## Future work — the residual classes are a bounded gate-extension, not whack-a-mole

The iters-1 no-retry diagnostic exposed three further order-dependent
test-isolation classes that CI's `-test-iterations 3` retry-masks
(keychain-auth-state, alert-presentation, accumulation pool-starvation). They
are NOT this gate's class (the gate's defer-flag invariant held suite-wide: 0
breadcrumbs / 6069 executions) and are tracked post-3.2.0. Critically, the
pool-starvation class is catchable by the SAME architecture — a bounded
pool+main-queue responsiveness probe added as a second `RuntimeQuiescenceAuditor`
invariant — which converts a silent suite-hang into an attributed `tearDown`
failure. Design + the seed-replay-bisection recipe for naming an accumulation
leaker: [`runtime-quiescence-gate-backlog.md`](./runtime-quiescence-gate-backlog.md).

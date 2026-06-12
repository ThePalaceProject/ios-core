# Runtime-quiescence gate — post-3.2.0 stabilization backlog (handoff)

**Status:** land-ready designs, NOT 3.2.0-blocking (Chairman: M0 = operational-green @ CI iters-3).
**Owner:** post-3.2.0 test-stabilization initiative.
**Companion to:** [`runtime-quiescence-gate.md`](./runtime-quiescence-gate.md) (the shipped defer-flag gate).
**Origin:** WS-0/M0 iters-1 no-retry diagnostic exposed 4 distinct test-isolation classes that CI's `-test-iterations 3` retry-masks. The defer-flag class is fixed + gated (shipped). This doc hands off the next two structural steps so the owner inherits them clean.

---

## Context: the 4 test-isolation classes the no-retry suite exposed

Running the suite at `-test-iterations 1` with no retry (the diagnostic bar) surfaced what CI's iters-3 config hides:

| # | Class | Mechanism | Status |
|---|-------|-----------|--------|
| 1 | **defer-flag** | a test leaves `AccountsManager.deferInitialLoadCatalogsForTesting = false` → next class's `production()` rebuild spawns a leaked catalog crawl → pool starvation | **FIXED + GATED** (shipped: `PalaceTestCase` + `RuntimeQuiescenceLintTests`) |
| 2 | **keychain-auth-state** | a sign-in test leaves an (expired) token in the sim keychain → later token-gated tests (`LocalFileAdapterTests`, audiobook adapter routing) see stale auth → fail/skip-chain | post-3.2.0 (w-lane: keychain-hermetic) |
| 3 | **alert-presentation** | a test leaves a `UIAlertController` on the window hierarchy → later `TPPAlertUtilsTests` presentation retries exhaust → fail | post-3.2.0 (w-mutex: alert-hermetic) |
| 4 | **pool-starvation (accumulation)** | MULTIPLE earlier tests leak blocking Tasks that gradually saturate the cooperative pool's threads → a later `await` (e.g. `DownloadQueueOrchestratorTests.testSchedulePendingStartsAsync_atCap`) never resumes → silent hang | post-3.2.0 (THIS doc) |

Classes 2–4 are **order-dependent** and therefore retry-masked at iters-3: a hung test is killed at the 120s `-default-test-execution-time-allowance` and **retried in a fresh shuffle**; if the retry dodges the polluter→victim ordering it goes green. That is why iters-3 is the correct *ship* bar and iters-1 is the correct *diagnostic* bar.

---

## Deliverable A — pool-responsiveness gate extension

### Goal
Convert a **silent suite-hang** (class 4) into an **attributed `tearDown` failure**, using the same `RuntimeQuiescenceAuditor` / `PalaceTestCase` substrate the defer-flag gate already established.

### Why a literal "no leaked Tasks" assert is impossible
Swift has **no public API to enumerate outstanding `Task`s** or query cooperative-pool occupancy. So you cannot assert "this test leaked N Tasks" directly. The tractable move is a **symptom probe**: after each test, verify the runtime is *responsive* (main queue flushes + the cooperative pool can still schedule work) within a budget. If it can't, something the just-finished test (or its predecessors) left running is saturating the runtime → fail, attributed to the finishing test.

### Design (add as a 2nd invariant)

1. **Add a `Violation` producer to `RuntimeQuiescenceAuditor`** — `poolResponsivenessViolations(probeCompleted: Bool)` mirroring the pure `deferFlagViolations(deferFlagLeftByTest:)` shape, so it is self-testable without staging a real leak.

2. **Add the live probe to `PalaceTestCase`** (runs in `tearDownWithError`, AFTER `super`, alongside the existing `assertRuntimeQuiescent()`):

   ```swift
   /// Bounded check that the runtime is at rest. Runs on the MAIN thread so the
   /// XCTWaiter blocks main — NOT a cooperative-pool thread — letting a probe
   /// Task actually run if the pool has any free thread. If the pool is fully
   /// saturated by leaked blocking Tasks, the probe never runs → timeout → fail.
   func assertRuntimeResponsive(budget: TimeInterval = 5.0,
                                file: StaticString = #file, line: UInt = #line) {
       // 1. Main-queue drain (reuses the existing helper).
       drainMainQueue(timeout: budget)            // XCTestCase+drainMainQueue.swift
       // 2. Cooperative-pool probe.
       let probe = expectation(description: "cooperative pool schedules work")
       Task.detached(priority: .high) { probe.fulfill() }
       let result = XCTWaiter().wait(for: [probe], timeout: budget)
       for v in RuntimeQuiescenceAuditor.poolResponsivenessViolations(
                    probeCompleted: result == .completed) {
           XCTFail("Runtime-quiescence gate [\(v.invariant)]: \(v.detail)", file: file, line: line)
       }
   }
   ```

   - **Main-thread `XCTWaiter().wait` is load-bearing**: it blocks the *main* thread, which is not a cooperative-pool worker, so a free pool thread can still run the probe. (Do NOT use this from an `@MainActor async` test body — same deadlock caveat as `drainMainQueue` vs `drainMainQueueAsync`; provide an `async` sibling using `await fulfillment(of:)` for async tests.)

3. **Self-test BOTH directions** (green-board contract #4, same discipline as `RuntimeQuiescenceGateTests`):
   - RED: a test that spawns a deliberately-blocking detached Task (e.g. holds a `DispatchSemaphore` long enough to occupy every pool thread — spawn `ProcessInfo.activeProcessorCount` of them) → the probe times out → `poolResponsivenessViolations(probeCompleted: false)` returns 1.
   - GREEN: a clean test → probe completes → 0 violations.
   - Pure-function self-test: `poolResponsivenessViolations(probeCompleted: false).count == 1`, `(probeCompleted: true).isEmpty`.

### Caveats to encode in the doc-comment (honesty, per the ADR)
- **Symptom, not root.** It detects "runtime not at rest," not "test X leaked a Task." The root leak still needs a per-leaker fix (Deliverable B family).
- **Budget tuning / false-positive risk.** The hang is *indefinite*; legitimate background work finishes in <1s. A 5s budget cleanly separates them, but a test that legitimately awaits a 6s operation in teardown would false-fail — audit for those before promoting to a hard gate (start warn-only, like the NotificationCenter audit, then promote).
- **Gradual-saturation attribution.** Accumulation means the probe fails at whichever test's tearDown *first* sees the pool saturated — often the last big leaker, not necessarily the first. It narrows the suspect window; it does not always finger the exact polluter. Pair with Deliverable B for naming.

---

## Deliverable B — seed-replay bisection recipe (naming the accumulation leaker)

`find-test-polluter.sh` cannot catch class 4: it runs **2-class pairs** (`-only-testing:SUSPECT -only-testing:VICTIM`), and a single suspect can't accumulate enough leaked Tasks to saturate the pool. Naming an accumulation leaker needs **ordered-prefix** reproduction.

### Recipe
1. **Capture the failing order.** Run the full suite at iters-1 with `-test-timeouts-enabled YES -default-test-execution-time-allowance 120` until a run reproduces the hang (the random shuffle makes this probabilistic; the 120s timeout bounds each attempt). Extract the **ordered list of `Test Case '…' started` lines** up to and including the victim from the log — that is the reproduction order.
2. **Pin the order.** Re-run with that exact order via an explicit `-only-testing:` list (or a generated `.xctestplan` with `testExecutionOrdering = "alphabetical"` + a wrapper that renames/sequences) so the order is deterministic and the hang reproduces every run. Confirm reproduction.
3. **Binary-bisect the prefix.** Remove the first half of the classes that ran *before* the victim (`-skip-testing:` them) and re-run:
   - Still hangs → the leaker is in the surviving (second) half.
   - Now passes → the leaker is in the removed (first) half.
   Recurse on the half that contains it until a single class remains. That class is the (or a) accumulation leaker.
4. **Confirm + fix family.** The fix is the owner's: typically cancel the leaked detached Task in the leaker's `tearDown`, `await` its background work to completion, or adopt `PalaceTestCase` + (once it ships) the pool-responsiveness probe so the leak is caught at its own boundary.

### Tooling note
Consider extending `find-test-polluter.sh` with an `--ordered-prefix <file>` + `--bisect` mode that automates steps 2–3 (it already has the run/destination scaffolding). That makes class-4 naming a single command for the next victim instead of a manual hour.

---

## Deliverable C — direct retry-recovery proof (optional demonstration)

The M0 operational-green decision rests on an **inferred** property: when a shuffle
hits the pool-starvation ordering, CI's `-test-timeouts-enabled YES
-default-test-execution-time-allowance 120` kills the hung test at 120s and
`-retry-tests-on-failure` re-runs it **in a fresh/isolated context** that escapes
the accumulated pool saturation → it passes on retry → CI goes green. The
mechanism is sound (the retry runs the single test fresh, without the preceding
leakers' accumulated Tasks) and is consistent with `#1063` sometimes-passing, but
the M0 CI-parity run did NOT directly exercise it (that run's single shuffle
*dodged* the ordering, so nothing hung and nothing was retried).

If a future owner wants to convert "inferred" → "demonstrated":

1. **Reproduce the hang at CI config.** Run the full suite at CI parity
   (`-retry-tests-on-failure -test-iterations 3 -test-timeouts-enabled YES
   -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 300`)
   repeatedly until a shuffle reproduces the pool-starvation hang (e.g.
   `DownloadQueueOrchestratorTests.testSchedulePendingStartsAsync_atCap`). Because
   it's order-dependent, several runs may be needed; the 120s timeout bounds each.
2. **Observe the recovery in the SAME run.** When it hangs, the log should show
   the test hit `exceeded execution time allowance` at ~120s, then a
   `Restarting after … test timeout` / retry attempt. Confirm the retried attempt
   **passes** and the overall run ends `** TEST SUCCEEDED **`. That is the direct
   proof: hung-at-120s → killed → retried-fresh → green.
3. **Record it** here + in the M0 evidence trail. If the retry does NOT recover
   (the hang re-accumulates even in the retry's context), that escalates the
   class from "retry-masked / post-3.2.0" to "CI-fatal" — in which case Deliverable
   A (the pool-responsiveness gate extension) moves up to attribute it, and the
   underlying leaker (Deliverable B) must be fixed.

This is a *demonstration*, not a fix — it confirms the operational-green
interpretation. It is explicitly NOT a 3.2.0 blocker (per the Chairman M0
decision); it is land-ready here for whenever the trail wants the inferred
property made explicit.

---

## Sequencing
Per Chairman: ship M0 (defer-flag gate + iters-3-green) first. Then this backlog, top-down: Deliverable A (pool-responsiveness probe — the durable structural win that turns silent hangs into attributed failures), then Deliverable B per victim as needed, alongside the keychain-hermetic (w-lane) and alert-hermetic (w-mutex) class fixes. All build ON the shipped `RuntimeQuiescenceAuditor` / `PalaceTestCase` substrate — one hierarchy, one auditor, N invariants.

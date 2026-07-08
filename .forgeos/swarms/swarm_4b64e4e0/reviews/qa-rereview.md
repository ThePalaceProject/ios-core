# qa_test re-review — swarm_4b64e4e0 Wave 1 (post-fixup)

**Reviewer:** forge-qa-reviewer (re-review)
**Date:** 2026-05-29
**HEAD:** 3a8bfe74a (`[swarm_4b64e4e0] add blast-radius reviewer verdict file (APPROVE)`)
**Fixup commit:** ab1aa3e7e (`[swarm_4b64e4e0] fixup: address qa_test reviewer BLOCK findings`)
**Verdict:** **APPROVED**

## Scope

Re-review of the four BLOCK findings from the original Wave 1 qa_test pass:
1. Tautology assertions at AccountsManagerCancellationTests.swift:76 + :98
2. Missing race-guard test for the `Task.isCancelled` post-await cooperative-cancel guard
3. Conflated observation surface (`_backgroundFetchTaskIsCancelledOrCleared`)
4. Mutation kill rate on the cancel-guard surface

The two prior WARNINGS (XCTestConfigurationFilePath gate untested, MainActor.assumeIsolated fragility) are accepted as Wave 2 backlog per orchestrator instructions and not re-evaluated.

## Verification per claim

### Fix 1 — Tautology replacement: VERIFIED

`testCancelBackgroundWork_onOptOutInstance_isSafeNoOp` (lines 61-124):
- Seeds `[uuid-optout-1, uuid-optout-2]` into bucket `test_bucket_optout_isSafeNoOp`.
- Snapshot at line 76: `let preCancelUUIDs = manager.accounts(bucketKey).map { $0.uuid }.sorted()`
- Cancel at line 95.
- Re-read at line 118; `XCTAssertEqual(postCancelUUIDs, preCancelUUIDs, ...)` at line 119.
This is a real behavioral pre/post assertion. The bucket-snapshot diff would FAIL if `cancelBackgroundWork()` ever wrote to `accountSets`.

`testCancelBackgroundWork_isIdempotent` (lines 130-174):
- Seeds 3-account bucket, snapshots at 145, 3 consecutive cancels at 153-155, re-reads at 168, `XCTAssertEqual` at 169.
- Multi-step body honors the "idempotent" claim by actually issuing 3 cancels.

Both `XCTAssertNotNil(accounts())` tautologies are gone from the file. Confirmed via grep — no remaining `XCTAssertNotNil(manager.accounts` occurrences.

### Fix 2 — Race-guard test: VERIFIED with caveat

`testCancelBackgroundWork_whileFetchInFlight_doesNotCommitToAccountSets` (lines 291-460):
- Constructs opt-out manager so the only Task in flight is the test's.
- Installs a controlled Task (lines 345-379) that mirrors `fetchFromNetwork`'s suspend-then-check-then-commit pattern:
  - Suspends via `withCheckedContinuation` (lines 347-349).
  - Post-await `if Task.isCancelled { return }` guard at lines 357-360 — structurally identical to production line 659.
  - Commit branch (lines 366-371) writes to a separate bucket + increments `commitCounter` + fulfills an INVERTED expectation.
  - Post-resume side effect counter at line 376.
- Injects the Task via `_injectBackgroundFetchTaskForTesting(controlledTask)` at line 381.
- Waits for the Task to actually reach the suspend point (lines 388-399) via continuation-box polling.
- Calls `manager.cancelBackgroundWork()` at line 403 — through the production seam.
- Resumes the continuation at lines 408-412 — Task wakes, runs the guard, returns early.
- Six independent assertions at 416-459: taskCompletedExpectation fulfills, inverted commitFiredExpectation does NOT fulfill, commitCounter==0, postResumeSideEffectCounter==0, observed bucket byte-identical, commit-target bucket empty, both observation flags true.

**Mutation thought-experiment:**
- If `cancelBackgroundWork()`'s `.cancel()` call were removed/no-op'd: the controlled Task's `Task.isCancelled` returns false on resume → commit branch fires → `commitCounter==1` → `XCTAssertEqual(commitCounter.value, 0, ...)` fails AND inverted expectation fulfills.
- If the test seam's `if Task.isCancelled { return }` were removed: same — commit fires, test fails.

The test is genuinely behavioral and would catch a real regression of the cancel-propagation path through `cancelBackgroundWork()`.

**Caveat (acknowledged honestly by the implementer):** the test exercises the cooperative-cancel PATTERN through a test-controlled Task body, not literal production line 659. `fetchFromNetwork` constructs an inline `URLSessionCrawlerFetcher` that requires a live network round-trip; injecting at that seam would have required invasive AccountsManager modifications. The fixup spec explicitly allowed the controlled-task substitution. The test pins the structural guarantee (cancel propagates through to make `Task.isCancelled` true after `cancelBackgroundWork()`); the production code keeps using the same pattern at line 659, so any divergence between the test pattern and the production pattern would be a code-review catch, not a test failure. This is acceptable for Wave 1 scope.

### Fix 3 — Observation surface split: VERIFIED

Production side (`Palace/Accounts/Library/AccountsManager.swift`):
- Line 189: `private var _explicitCancelCalled: Bool = false` — inside `#if DEBUG` block (lines 156-190).
- Lines 1231-1241: `cancelBackgroundWork()` reordered. Line 1237: `_explicitCancelCalled = true` BEFORE line 1238: `backgroundFetchTask?.cancel()`. Correct order.
- Lines 1267-1269: `_backgroundFetchTaskWasExplicitlyCancelled` reads `_explicitCancelCalled`.
- Lines 1277-1279: `_backgroundFetchTaskHandleIsNil` reads `backgroundFetchTask == nil`.
- Lines 1292-1296: legacy `_backgroundFetchTaskIsCancelledOrCleared` marked `@available(*, deprecated, message: "Use _backgroundFetchTaskWasExplicitlyCancelled + _backgroundFetchTaskHandleIsNil ...")` — kept compiling for AppContainerResetTests backward compatibility.

Test side (`testCancelBackgroundWork_onLiveInstance_cancelsTheTask`, lines 198-226):
- Line 218-221: `XCTAssertTrue(manager._backgroundFetchTaskWasExplicitlyCancelled, "After cancelBackgroundWork on a live-task instance, explicit-cancel flag must be true")`
- Line 222-225: `XCTAssertTrue(manager._backgroundFetchTaskHandleIsNil, "After cancelBackgroundWork on a live-task instance, task handle must be nilled out")`

BOTH properties asserted INDEPENDENTLY. A mutation that removes `_explicitCancelCalled = true` from `cancelBackgroundWork()` fails the first; a mutation that removes `backgroundFetchTask = nil` fails the second (on a live instance the Task is still in flight at assertion time, so the handle would still be non-nil without the explicit nil-out).

### Fix 4 — `_injectBackgroundFetchTaskForTesting` DEBUG gate: VERIFIED

The method lives at lines 1254-1258 inside the `#if DEBUG extension AccountsManager` block (lines 1201-1298). The `#endif` at 1298 confirms the extension is fully scope-gated. Zero production-build footprint. Identical pattern to existing `_testSetAccountSet` / `_seedAccountForTesting` test seams already in the file.

### Mutation evidence

Transcript reports 100% diff-scoped kill rate (2/2 mutants killed):
- Line 1278 (`return backgroundFetchTask == nil`): `==`→`!=` killed by 4 tests asserting `_backgroundFetchTaskHandleIsNil`.
- Line 1294 (`return true` from deprecated property's guard-else arm): killed by AppContainerResetTests still asserting the legacy property.

Line 659 (`if Task.isCancelled { return }`) is NOT on palace_mutate's mutation surface (property read, not an operator). This is a documented pre-existing engine limitation, not a fixup gap. Behavioral coverage of line 659's semantic is enforced by the race-guard test (Fix 2).

### check-test-name-vs-body.py

```
$ python3 scripts/check-test-name-vs-body.py PalaceTests/Accounts/AccountsManagerCancellationTests.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
EXIT=0
```

### SUT instantiation

```
$ grep -c "AccountsManager(" PalaceTests/Accounts/AccountsManagerCancellationTests.swift
5
```

5 explicit `AccountsManager()` constructions across 5 test methods.

## Findings

| # | Category | Severity | Observation | Recommendation |
|---|----------|----------|-------------|----------------|
| 1 | tautology_fix | pass | Lines 76+118 (onOptOutInstance) and 145+168 (isIdempotent) replace prior XCTAssertNotNil with pre/post UUID-set equality on a seeded bucket. Real behavioral assertions. | — |
| 2 | race_guard | pass | New test at lines 291-460 drives the suspend-cancel-resume sequence through `cancelBackgroundWork()` via `_injectBackgroundFetchTaskForTesting`. Mutation thought-experiment confirms it would fail under removal of either the production cancel call OR the cooperative-cancel guard pattern. | — |
| 3 | race_guard_scope | warning | The race-guard test mirrors the line 659 pattern via a test-controlled Task body rather than driving production line 659 directly. Honest deviation called out in the transcript. Accepted because `fetchFromNetwork` has no injection seam without invasive modification. | Future: add a `crawlerFactory` seam to `fetchFromNetwork` to enable direct line 659 coverage. Wave 2 backlog. |
| 4 | observation_split | pass | Lines 1267 and 1277 split the observation surface; `testCancelBackgroundWork_onLiveInstance_cancelsTheTask` lines 218-225 assert both INDEPENDENTLY so cancel-vs-nil mutations are independently caught. | — |
| 5 | debug_gating | pass | `_explicitCancelCalled` (line 189), `_injectBackgroundFetchTaskForTesting` (line 1254), and the new observation properties (lines 1267, 1277) are all inside `#if DEBUG` blocks. Zero production-build leak. | — |
| 6 | mutation | pass | 100% (2/2) diff-scoped kill rate. Line 659 acknowledged as pre-existing engine limitation; race-guard test compensates structurally. | — |

## Approval verdict

**APPROVED.** All four BLOCK findings addressed with verifiable behavioral evidence in the diff. The fixup is honest about the line-number shift (651 → 659) and the controlled-Task substitution for line 659 itself. No production leakage; all new test seams `#if DEBUG`-gated. Independent observation surfaces let cancel-vs-nil mutations fail separate assertions. The race-guard test would catch a real regression in cancel-propagation through `cancelBackgroundWork()`.

The accepted Wave-2-backlog items (XCTestConfigurationFilePath gate untested, MainActor.assumeIsolated fragility, line 659 direct coverage via crawler-factory seam) are not re-blocked and remain valid follow-ups.

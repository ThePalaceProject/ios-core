# Wave-3 Targeted De-flake — Module: Platform / OfflineQueueService (S8)

Worktree: `swarm_ad0b4c65-w3-offlinequeue-s8` (branch `swarm/swarm_ad0b4c65-w3-offlinequeue-s8`, carries S1/S2)
Scope (edited ONLY these 3 files):
- `Palace/Platform/OfflineQueueService.swift` (production — S8 seam)
- `PalaceTests/Platform/OfflineQueueServiceTests.swift` (7 conversions)
- `PalaceTests/Platform/OfflineQueueServiceExtendedTests.swift` (5 conversions)

## Seam type: INJECT-THE-BACKOFF (S11-style), **not** a Task-join. Deliberate.

The dispatch asked for `_awaitInFlightForTesting()` (retained-Task-handle
grow-until-stable join) **and** explicitly authorized the escape hatch: *"if the
retry loop is an INFINITE/scheduled backoff (not a one-shot fire-and-forget), a
Task-join would be UNBOUNDED — instead inject the backoff scheduler/interval (like
S11 did) OR report BLOCKED."* This module is squarely in that escape hatch.

### Why a Task-join is the WRONG tool here (the Wave-2 transcript mis-read the code)

The Wave-2 Platform transcript stated the retry/backoff is a *"fire-and-forget
`Task { … }`"* at `OfflineQueueService.swift:187` inside `processQueue()`. That is
incorrect on the current tree:

1. **The backoff is INLINE, not fire-and-forget.** `processQueue()` is `async`.
   The backoff is an inline `try? await Task.sleep(...)` **inside** the loop body
   (was line 169, now `await backoffSleep(delay)`). There is no `Task { }` spawn
   wrapping the retry — the sleep is directly awaited on the actor's own
   execution.
2. **`processQueue()` is directly awaited to full drain.** `enqueue`, `retry`, and
   `networkStatusChanged` all call `await processQueue()`, which loops
   `while let index = queue.firstIndex(where: { $0.state == .pending })` until every
   action is terminal (`.completed`→removed, or `.failed`). So by the time any of
   those three `await`s returns, the queue is fully settled. There is **no detached
   handle to join** — the work is already joined by the caller's own `await`.
3. **The only genuine fire-and-forget `Task {}` spawns are the `NWPathMonitor`
   callbacks** — `init` line 69 (`Task { await startNetworkMonitoring() }`) and the
   `pathUpdateHandler` (`Task { await self?.networkStatusChanged(...) }`, the actual
   line ~187 the Wave-2 transcript pointed at). **No test waits on these**, and they
   are **unjoinable-by-design**: they fire on real OS network-path changes an
   unbounded / never-guaranteed number of times (0..n), so a grow-until-stable join
   would either join nothing (not fired yet) or block indefinitely. Retaining and
   joining them would be an UNBOUNDED await — the exact regression the playbook's
   inviolable rule forbids.

A `_awaitInFlightForTesting()` join would thus join the wrong Tasks (network
monitor) and do nothing for the one test that actually incurs wall-clock backoff
(`testRetryFailedAction`, a real 2s inline `Task.sleep`). It cannot make the tests
faster or more deterministic. **Rejected on bounded-correctness grounds.**

### The bounded-correct seam: injected backoff interval

Mirrors the S11 `DownloadProgressReporter(throttleInterval: 0)` pattern (a defaulted
injection, NOT an XCTest-gated Task list — the default value *is* production
behavior, so no `_isRunningUnderXCTest` gate is needed).

Production (`OfflineQueueService.swift`):
```swift
private let backoffSleep: @Sendable (TimeInterval) async -> Void

init(
    userDefaults: UserDefaults = .standard,
    backoffSleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
) { self.userDefaults = userDefaults; self.backoffSleep = backoffSleep; ... }

// call site (was: try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)))
await backoffSleep(delay)
```
Tests construct with `backoffSleep: { _ in }` in `setUp()`.

### Bounded rationale (why every converted `await` is bounded)

No new `await` targets a raw Task handle. The converted tests await only
`service.enqueue(...)`, `service.retry(...)`, `service.networkStatusChanged(...)`,
`service.processQueue()`, `service.currentStatus()`, `service.actions(withState:)` —
all actor calls whose bound is the `processQueue()` drain loop, and that loop is now
guaranteed to terminate without any real sleep (injected no-op backoff) in a finite
number of iterations (each iteration ends an action `.completed` or `.failed`;
neither re-enters `.pending` more than `maxRetries` times). The two remaining
`fulfillment(of:[e], timeout: 2.0)` waits are KEEP (Combine publisher, main-hop) —
untouched.

### RELEASE-identical proof

- The **only** production construction is `static let shared = OfflineQueueService()`
  (line 22) — `grep -rn 'OfflineQueueService(' Palace/` returns exactly that one
  site, which supplies neither argument → uses the default `backoffSleep`.
- The default closure is `try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))`
  — byte-for-byte the removed inline statement. `await backoffSleep(delay)` with the
  default therefore executes the identical suspension. No behavioral delta in RELEASE.
- The injected list / XCTest gate approach was NOT used, so there is no gated code to
  reason about — RELEASE and DEBUG run the identical default path unless a test
  explicitly injects the no-op.

## Conversions — before → after wait counts

DELETE bucket (redundant settle-sleep on an already-awaited full drain), + tightened
two tautological `XCTAssertGreaterThanOrEqual(_, 0)` assertions to the now-deterministic
exact value, + removed one dead redundant `await service.processQueue()`.

| File | `Task.sleep` before | `Task.sleep` after | `fulfillment(of:)` (KEEP) |
|---|---|---|---|
| `OfflineQueueServiceTests.swift` | 7 | 0 | 2 (unchanged) |
| `OfflineQueueServiceExtendedTests.swift` | 5 | 0 | 0 |
| **Total** | **12** | **0** | **2** |

### OfflineQueueServiceTests.swift (7 sleeps removed)
- `testProcessQueueSuccess` — removed 100ms sleep. Assertions already exact (pending0/failed0/executed1).
- `testProcessQueueFIFOOrder` — removed 200ms sleep.
- `testRetryFailedAction` — removed 3s sleep (this was the ONE test that hit a real
  2s inline backoff: fail→retryCount1<max3→2s sleep→success). Now deterministic;
  added `failedCount == 0` alongside `pendingCount == 0`.
- `testMaxRetriesExceeded` — removed 2 sleeps + the dead redundant `processQueue()`;
  tightened `XCTAssertGreaterThanOrEqual(failed.count, 0)` (a tautology, always true)
  → `XCTAssertEqual(failed.count, 1)`.
- `testClearFailed` — removed 200ms sleep.
- `testNetworkAvailableTriggersProcessing` — removed 200ms sleep.

### OfflineQueueServiceExtendedTests.swift (5 sleeps removed)
- `testMaxRetriesReached_ActionMarkedAsFailed` — removed 3s sleep; tightened
  `>= 0` tautology → `== 1`.
- `testProcessQueue_FIFO_Order` — removed 500ms sleep.
- `testClearFailed_RemovesOnlyFailedActions` — removed 500ms sleep.
- `testRetry_MovesFailedToPending` — removed 2× 500ms sleeps.

Note: maxRetries 0/1 fail on the first attempt (`retryCount(1) >= maxRetries`) and
never enter the backoff branch, so those tests were already deterministic under the
awaited drain — the sleeps were pure redundant settle-delay (DELETE-safe regardless
of the seam). The seam is load-bearing only for `testRetryFailedAction` (maxRetries:3,
one real 2s backoff), which it makes both fast and deterministic.

## KEEP (2) — unchanged, byte-for-byte

- `OfflineQueueServiceTests.testStatusPublisherEmits` — `fulfillment(of:[e], timeout: 2.0)`
- `OfflineQueueServiceTests.testActionPublisherEmits` — `fulfillment(of:[e], timeout: 2.0)`

Both are Combine sinks on the service's own publisher `.receive(on: .main)`, fulfilled
by a `.send` that fired synchronously inside the immediately-preceding awaited
`enqueue`. Not a deadline-poll — a deterministic event + one main hop, with the
timeout as a safety net. Same KEEP class the Wave-2 transcript already assigned them.

## Off-limits compliance
- Edited only the 3 in-scope files. No other `Palace/**`, no
  `PalaceTests/XCTestCase+drainMainQueue.swift`, no other test dir.
- No unbounded `await` introduced (`grep -nE 'await [A-Za-z_]+\.value'` → none).
- No commit / no push.

## Verification commands run
```bash
# residual settle-delay in converted files → NONE
grep -nE 'Task\.sleep|usleep|Thread\.sleep|while.*Date\(\)|asyncAfter' \
  PalaceTests/Platform/OfflineQueueServiceTests.swift \
  PalaceTests/Platform/OfflineQueueServiceExtendedTests.swift        # (empty)

# KEEP publisher waits still present → 2, both in Tests
grep -nE 'fulfillment\(of:|wait\(for:|waitForExpectations' \
  PalaceTests/Platform/OfflineQueueService*Tests.swift               # 2 hits

# bare raw-handle await → NONE
grep -nE 'await [A-Za-z_]+\.value' PalaceTests/Platform/OfflineQueueService*Tests.swift  # (empty)

# production seam wired
grep -nE 'backoffSleep' Palace/Platform/OfflineQueueService.swift    # decl/param/assign/callsite

# RELEASE-identical: only .shared uses the default
grep -rnE 'OfflineQueueService\(' Palace/                            # only line 22 .shared()
```

## Build/run
CANNOT build locally (CI-gated, per constraints). Grep-verified only. Orchestrator
builds + runs the full suite. Expected: 12 wall-clock sleeps (up to ~10.7s aggregate,
dominated by the 3s + 3s + 2s-backoff cases) removed; all OfflineQueueService tests
now deterministic and near-instant.

## BLOCKED findings
None. Delivered via the authorized inject-the-scheduler path rather than the
Task-join (which would have been unbounded / a no-op here — see rationale above).
```

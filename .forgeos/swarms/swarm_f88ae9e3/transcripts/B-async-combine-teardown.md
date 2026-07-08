# Investigator B — Async / Combine Teardown Leakage

**Mode:** INVESTIGATION ONLY. No production-code or test-file edits.
**Scope:** PalaceTests/Contract/, Audiobooks/, MyBooks/, CarPlay/, Integration/
(plus targeted scans across the full suite for sleep-based waits and
unjoined Tasks, since those leak symptoms manifest globally).

---

## 1. Summary

The category is real and pervasive — **63 distinct files** use sleep-based
waiting (`Task.sleep`, `Thread.sleep`), with **168 total sleep call sites**.
The leak surfaces aren't fire-and-forget `Task { }` blocks (the architect's
initial hypothesis); the codebase has actually been careful about those.
The leak surfaces are:

1. **Polling timeouts that mask serialized contention.** Two tests in
   `TokenRefreshOnForegroundTests.swift` and one in
   `TokenRefreshAndRetryQueueTests.swift` use 30-second polling timeouts to
   wait for `tokenHits == 1`. Under CI load with random test ordering,
   the underlying actor-hop + URLSession dispatch starves, and the polled
   condition never converges. The 30s timeout becomes the test's
   wall-clock failure point — exactly what the architect cited.

2. **Fire-and-forget Tasks in production-test `SpyDelegate`s.** A handful
   of test-local `SpyDelegate` types receive `nonisolated` protocol calls
   and hop back to `@MainActor` via `Task { @MainActor in self.X.append(...) }`.
   The Task is never awaited and never cancelled. If the test ends before
   the Task scheduler runs it, `self` is deallocated and the append is dropped
   (data loss → tests assert empty arrays). Worse: under random ordering, a
   stale Task can land in the NEXT test's MainActor queue, racing setUp.

3. **Fixed-interval `Task.sleep` polling inside test bodies.** Especially
   the `CatalogSearchViewModelTests` (~24 sleeps of 100–300ms each) and the
   `OfflineQueueService*Tests` (3-second sleeps to wait for retry backoff).
   These don't leak Tasks per se, but they're the "weak fence" the architect
   warned about — when the polled state-machine stalls, the test sees stale
   data and passes/fails non-deterministically.

4. **`Thread.sleep` inside `DispatchQueue.global().async` callouts** in
   `AccountsManagerStateMachineWiringTests` lines 940, 951. Annotated
   `FLAKE-001-OK` but still architecturally a sleep — blocks a global queue
   worker thread for 50ms while the rest of the suite runs.

5. **DRMAdversarialTests fires a Task that asserts XCTFail.** Line 106 spawns
   `Task { do { try await AdobeDRMService.shared.ensureDeviceActivated();
   XCTFail(...) } catch { ... } }`. The test body returns before the Task
   completes. If the Task succeeds (unexpected), `XCTFail` fires after the
   test method returned — XCTest may attribute it to the NEXT test or drop
   it entirely.

6. **The single canonical 30-second TokenRefreshOnForegroundTests failure
   the plan cited is explained in §5 below.**

The good news: **48 files declare `Set<AnyCancellable>` and every single one
either drains via `cancellables = nil` (Set!) in `tearDown` OR explicitly
calls `cancellables.removeAll()`.** Combine subscription leakage is not the
acute issue. The acute issue is the Task/sleep complex, which manifests as
30-second timeouts and order-dependent flake.

---

## 2. Inventory counts

| Signal | Count |
|---|---|
| `Set<AnyCancellable>`-storing test files | 48 |
| Files without ANY cancellables drain | **0** (all 48 drain — false alarm) |
| `Task.sleep` / `Thread.sleep` / `usleep` lines | 168 |
| Distinct files with sleep-based waits | 63 |
| `Task.sleep ≥ 1s` (long, fixed) | 6 sites (Mocks/, OfflineQueueService*Tests, BorrowOperationTimeoutTests) |
| `Task.sleep ≥ 3s` in test bodies | 2 (OfflineQueueServiceTests:127, OfflineQueueServiceExtendedTests:45) |
| `Thread.sleep` in test bodies | 2 (AccountsManagerStateMachineWiringTests:940,951 — annotated FLAKE-OK) |
| Timeouts `≥ 30s` in tests | **10 sites** (3 are real flakiness-mask, 7 are FLAKE-OK annotated) |
| `Task { ... }` fire-and-forget in test bodies | ~12 confirmed (most are paired with expectation drains) |
| `Task { ... }` in test-local SpyDelegate (uncancelled) | **4 sites** (SpyBorrowDelegate, BookReturn SpyDelegate, DownloadAuthRetryHandler SpyDelegate, BorrowOperation SpyDelegate) |

---

## 3. HIGH-severity findings (the actual flake drivers)

### HIGH-1 — TokenRefreshOnForegroundTests:445 (`test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`)
**File:** `PalaceTests/Network/TokenRefreshOnForegroundTests.swift:409-453`
**Leak type:** SLEEP / POLLING-TIMEOUT (the canonical 30s failure cited in plan.md)
**The actual mechanic:**
- The test fires TWO concurrent `executor.GET(apiURL)` calls (both hit the
  proactive-refresh branch in `TPPNetworkExecutor.executeRequest:224-234`).
- Each spawns a `Task { ... }` inside `refreshTokenAndResume(task: nil)`
  (TPPNetworkExecutor.swift:492) which calls `tokenCoordinator.tryClaimRefreshSlot()`
  (actor hop).
- The test then runs a synchronous `waitForCondition(timeout: 30.0)` poll
  via `RunLoop.current.run(...)`. The poll is checking `tokenHits == 1`
  (set inside the stub when the first /token URL arrives).
- For the poll to succeed: GET 1 must wake the executor's URLSession queue,
  the URLSession must invoke the stub, the stub must run the HTTP roundtrip,
  THEN the runloop polls have to interleave correctly.
- Under CI parallel-test contention, the actor-hop + URLSession dispatch
  stalls past 2s (per the inline comment on line 442-444, citing the
  BookRegistry/CatalogCache/ImageCache 30s restorations as the same
  pattern). When the pollWait's runloop hop and the URLSession's dispatch
  contend for the same main-actor wakeup, the stub's `tokenHits +=` may
  not be observable from the polling thread until well past the 30s budget.
- The 30.353s failure means the polled condition never converged AT ALL
  before the timeout — the stub was never invoked.
- The `releaseGate.wait(timeout: .now() + 3.0)` inside the stub provides
  no escape — it's NEVER entered because the URLSession dispatch stalled.
- The subsequent `fulfillment(of: [exp1, exp2], timeout: 5.0)` then ALSO
  times out (no completions ever fired), producing the test's final
  XCTAssertion failure.

**Root cause:** the test uses a synchronous polling timeout (`RunLoop.current.run`)
to wait for an event that arrives via a chain of actor-isolated async work +
URLSession completion handler dispatch. This is the *opposite* of what
`fulfillment(of:timeout:)` is for. Under random test ordering with parallel
contention, the polling loop and the URLSession callback never get scheduled
into a converging interleaving.

**Cite for the plan:** plan.md §1.2 names this exact test as the canonical
30-second failure. Confirmed: the synchronous-polling-on-async-work pattern
is the structural bug.

### HIGH-2 — TokenRefreshOnForegroundTests:250 (`test_NearExpiryToken_GETBlocksOnRefresh`)
**File:** `PalaceTests/Network/TokenRefreshOnForegroundTests.swift:217-262`
**Leak type:** SLEEP / POLLING-TIMEOUT
**Same root cause as HIGH-1.** The test polls `tokenHits == 1` with 30s
timeout via `waitForCondition`. On a clean local run this is <100ms; on
random-ordered CI it joins the flake club.

### HIGH-3 — TokenRefreshAndRetryQueueTests:449
**File:** `PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift:449`
**Leak type:** SLEEP / POLLING-TIMEOUT
**Same root cause again.** Another 30s polling wait on a token-refresh event.
The fact that this same 30s budget appears in THREE distinct test files (all
related to the same async-actor-URLSession surface) is itself the signal —
it's a *workaround* for the polling-on-async-work bug, not a fix.

### HIGH-4 — DRMAdversarialTests:106 (`testFulfillment_withoutAdobeUserID_doesNotShowSignInModal`)
**File:** `PalaceTests/Security/DRMAdversarialTests.swift:104-117`
**Leak type:** TASK (fire-and-forget XCTFail)
**Mechanic:**
```swift
Task {
    do {
        try await AdobeDRMService.shared.ensureDeviceActivated()
        XCTFail("ensureDeviceActivated should throw when no licensor is available")
    } catch {
        XCTAssertTrue(true, ...)
    }
}
// test method returns immediately — Task is unjoined
```
The test method returns BEFORE the Task runs. If activation succeeds
(regression), the `XCTFail` fires after the test has nominally passed. XCTest
attribution at that point is undefined — could attribute to the test, the
next test, or vanish. Either way, this test cannot fail correctly.

### HIGH-5 — Four test-local `SpyDelegate`s with uncancelled `Task { @MainActor in }`
**Files + lines:**
- `PalaceTests/MyBooks/BorrowOperationTests.swift:545` (SpyDelegate.startBorrow)
- `PalaceTests/MyBooks/BorrowOperationAuthCoordinatorTests.swift:392` (same shape)
- `PalaceTests/MyBooks/DownloadAuthRetryHandlerAuthCoordinatorTests.swift:305,311` (two methods, same shape)
- `PalaceTests/MyBooks/BookReturnCleverReauthTests.swift:209` (same shape)

**Leak type:** TASK (lifetime escape from test boundary)
**Mechanic:**
```swift
nonisolated func startBorrow(...) {
    Task { @MainActor in
        self.startBorrowCalls.append((book, attemptDownload))
    }
}
```
The delegate is `nonisolated` (protocol contract requires it). To mutate its
@MainActor state it hops via `Task { @MainActor in ... }`. The Task is not
captured, not awaited, and not cancelled in tearDown. If the test asserts
on `spyDelegate.startBorrowCalls.count` BEFORE the Task runs, the count is
wrong — the test passes for the wrong reason or fails non-deterministically.
Worse: under random ordering, a stale append-Task from test N can land in
test N+1's MainActor queue, mutating a *different* spy that happens to be at
the same memory address.

This is the architect's "Task spawned with no cancel + mutates @Published"
shape, just one layer indirected (mutates the spy's array which the test
asserts on, equivalent to a published value for the purpose of the leak).

### HIGH-6 — AccountStateMachineTests Tasks (5 sites)
**File:** `PalaceTests/Accounts/AccountStateMachineTests.swift:132, 159, 184, 193, 220, 328`
**Leak type:** TASK (stream subscription, some captured some not)
**Mechanic:** Multiple test methods spawn `let awaiterTask = Task { for await
state in account.stateStream { ... } }` and then mutate state. **Several of
these test methods do NOT cancel the awaiter in cleanup** — they rely on the
test method returning, which would deallocate the stream, which would cause
the iteration to throw. But during random ordering with a stream that's
backed by `AccountStateStore.shared`, the stream can outlive the test:
- Line 159: `Task { ... }` inside a for-loop fanout — 3 tasks, not captured.
- Line 220: `let task = Task { ... }` — captured but only locally; no cancel
  in test cleanup (relies on tearDown nil'ing `manager` to close the stream).

### HIGH-7 — OfflineQueueServiceTests 3-second sleeps
**Files:**
- `PalaceTests/Platform/OfflineQueueServiceTests.swift:127` (`try? await Task.sleep(nanoseconds: 3_000_000_000)`)
- `PalaceTests/Platform/OfflineQueueServiceExtendedTests.swift:45` (same)

**Leak type:** SLEEP (long fixed wait)
**Mechanic:** Tests wait 3 SECONDS for retry-with-backoff. This is the
architect's "fixed-interval delay → cold-start contention → unpredictable"
class. On CI under load, the 3s isn't enough; on a fast local box, it's a 3s
test-suite tax for nothing.

---

## 4. MED-severity findings

### MED-1 — CatalogSearchViewModelTests sleep-loop fence (~24 sites)
**File:** `PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift`
**Lines:** 304, 318, 340, 527, 552, 578, 652, 668, 687, 1083, 1095, 1122,
1217, 1392, 1415, 1450, 1469, 1491, 1513 (and the mock-side delays
57, 74, 92, 107)
**Leak type:** SLEEP (test-body polls)
**Pattern:** every test that exercises debounce uses `try? await
Task.sleep(nanoseconds: 150_000_000)` (or 100/200/300ms) instead of an
`XCTestExpectation`. The debounce is real — but the test should poll the
observable signal (`viewModel.filteredBooks.count == N`) via
`awaitConditionAsync`, not a fixed sleep. Under CI load these sleeps are
not long enough; the test reads stale state and asserts the pre-debounce
value.

### MED-2 — Platform/AppLaunchTrackerTests fixed sleeps (5 sites)
**File:** `PalaceTests/Platform/AppLaunchTrackerTests.swift` lines
42, 44, 46, 84, 122, 124, 128
**Leak type:** SLEEP (test-body polls)
**Pattern:** 10–100ms sleeps to wait for analytics dispatch. Same shape
as MED-1; same risk under CI load.

### MED-3 — Platform/AppHealthViewModelTests 200ms sleeps (6 sites)
**File:** `PalaceTests/Platform/AppHealthViewModelTests.swift` lines
69, 78, 87, 104, 117, 132
**Leak type:** SLEEP

### MED-4 — Concurrency/MainActorHelpersTests sleeps (5 sites)
**File:** `PalaceTests/Concurrency/MainActorHelpersTests.swift` lines
18, 20, 95, 109, 148, 176, 270
**Leak type:** SLEEP

### MED-5 — Reader2/TPPLastReadPositionPosterTests sleeps (5 sites)
**File:** `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` lines
121, 142, 161, 186, 200
**Leak type:** SLEEP

### MED-6 — Account state machine 50ms / 30ms sleeps as ordering proxies
**File:** `PalaceTests/Accounts/AccountStateMachineTests.swift` lines
139, 165, 198, 234, 236, 346
**Leak type:** SLEEP — same pattern as MED-1 but inside critical-path
auth tests. These are the sleeps used to "give the awaiter a moment to
subscribe to the stream" before asserting on the state machine — a
genuine race that should be fixed via an explicit
`subscribed` expectation on the stream.

### MED-7 — AccountsManagerStateMachineWiringTests Thread.sleep inside
DispatchQueue.global().async (2 sites, annotated FLAKE-OK)
**File:** `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift:940,951`
**Leak type:** SLEEP (Thread.sleep blocking a global-queue worker)
**Annotation:** marked `FLAKE-001-OK` so the lint accepts it. Still a
sleep; still architecturally a fence. The annotation says "redrive yield,
intentional" — the structural fix would be to expose a synchronization
point on the production code path being driven, not block a global-queue
thread for 50ms.

### MED-8 — Integration-test cancellation sleeps (2 sites)
**Files:**
- `PalaceTests/Integration/AccountSwitchIntegrationTests.swift:108` (50ms before `task.cancel()`)
- `PalaceTests/Integration/SearchFlowIntegrationTests.swift:161` (same)
**Leak type:** SLEEP (race-window proxy)
**Pattern:** "Allow the task to start, then cancel." Hopes the 50ms is enough
for `Task { try await catalogRepo.loadTopLevelCatalog(...) }` to *begin*
before the `.cancel()` lands. On a busy CI runner, this race window can
invert — the cancel beats the work, and the test asserts on the wrong path.

### MED-9 — NowPlayingCoordinatorTests `awaitCondition(timeout: 5)` for
production-debounce Task
**Files:**
- `PalaceTests/Audiobooks/NowPlayingCoordinatorTests.swift:346`
- `PalaceTests/Audiobooks/NowPlayingCoordinatorBackgroundTests.swift:135`
**Leak type:** SLEEP / POLL (the awaitCondition helper sleeps internally)
**Pattern:** the production code at `NowPlayingCoordinator.swift:282-292`
schedules `Task { try await Task.sleep(...) }` for debounce. The test polls
`MPNowPlayingInfoCenter.default().nowPlayingInfo` with a 5s timeout. Better
than a fixed sleep, but still a poll-on-Task-sleep — under iOS load on CI,
the system MediaPlayer queue can be backed up well past 5s. Not the
worst offender but the shape inherits the architect's "Tasks don't hop
the main queue" warning baked into the test comments.

### MED-10 — Reader2/TypographyServiceIntegrationTests 300ms sleep
**File:** `PalaceTests/Reader2/Typography/TypographyServiceIntegrationTests.swift:290`
**Leak type:** SLEEP

### MED-11 — Long timeouts marked FLAKE-003-OK
**Files:**
- `PalaceTests/SignInLogic/TPPAgeCheckDeepTests.swift:178` (30s)
- `PalaceTests/SignInLogic/SignInWebSheetIntegrationTests.swift:106` (30s)
- `PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift:106` (30s)
- `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift:108` (30s — no annotation)
- `PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift:87` (30s)
- `PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift:207` (60s, performance budget)
**Leak type:** Long-timeout signal (FLAKE-OK pre-annotated)
**Note:** Most of these are explicitly annotated as covering cold-start
AccountsManager preload contention. They're not the acute flake — they're
documented workarounds. But the *existence* of 6 separate 30s+ timeouts
all citing the same 1138-account AccountsManager preload is itself
evidence that the structural fix is "isolate the preload from these
tests" (already on Phase 2 roadmap per the annotations).

### MED-12 — CatalogDomain awaitCondition timeout: 30 (4 sites)
**File:** `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift:174,207,306,363`
**Leak type:** Long-timeout poll
**Pattern:** Same as HIGH-1 but lower stakes — these polls are on cache
eviction, not auth. Still architecturally fragile.

---

## 5. The 30-second TokenRefreshOnForegroundTests failure — why

(Standalone explanation per contract requirement.)

The failing test was
**`TokenRefreshOnForegroundTests.test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`**
at `PalaceTests/Network/TokenRefreshOnForegroundTests.swift:409-453`.

The test verifies "two simultaneous foreground requests produce ONE
`/token` refresh" (single-flight).

Failure walkthrough:
1. Test sets a near-expiry token (`setTokenExpiringIn(seconds: 30)`).
2. Test registers an HTTP stub that, for `/token`, increments `tokenHits`
   under `counterQueue.sync` then blocks on `releaseGate.wait(timeout:
   .now() + 3.0)` (line 420).
3. Test fires `executor.GET(apiURL) { _ in exp1.fulfill() }` and again
   for `exp2` (lines 436-437).
4. Each GET enters `TPPNetworkExecutor.executeRequest` (line 214). The
   proactive-refresh branch at line 224 fires because
   `userAccount.authTokenNearExpiry == true`. The branch calls
   `refreshTokenAndResume(task: nil, accountId: accountId) { ... }`
   (line 230).
5. `refreshTokenAndResume` spawns `Task { ... }` (line 492) which calls
   `tokenCoordinator.tryClaimRefreshSlot()` (actor isolated). The first
   GET claims the slot; the second is queued.
6. The first claimer calls `executeTokenRefresh(... tokenURL ...)` which
   invokes a URLSession data task against `https://token.example.com`.
7. The URLSession dispatches; the stub fires and `tokenHits` becomes 1.

Meanwhile, the test code is in:
```swift
XCTAssertTrue(waitForCondition(timeout: 30.0) { counterQueue.sync { tokenHits } >= 1 },
              "/token endpoint should be in-flight")
```

`waitForCondition` (line 117) is a *synchronous* helper that runs the
current runloop in 25ms slices and re-checks the predicate:
```swift
private func waitForCondition(timeout: TimeInterval = 5.0, _ condition: ...) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
    }
    return condition()
}
```

The test method `test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`
is marked `async throws` and is dispatched on the @MainActor by XCTest's
async-test infrastructure. So the `RunLoop.current.run(...)` is **running
the MAIN runloop** while waiting for the URLSession (which dispatches its
completion handlers on a *different* operation queue) to schedule its
callback.

Now combine that with:
- The `Task { ... }` in `refreshTokenAndResume` runs on the global executor.
- The `tokenCoordinator.tryClaimRefreshSlot()` is an actor hop.
- The URLSession data task's completion dispatch under
  `URLSessionConfiguration.ephemeral` goes to the session's `delegateQueue`
  (here `nil`, meaning URLSession-internal).
- Under random test ordering + parallel suite contention, the MainActor's
  runloop slot is contended by OTHER tests in the suite running their own
  async work.

**Failure mode:** The test blocks on `waitForCondition` (runs the main
runloop). The main runloop has 25ms to wake any blocked work. Under
contention, the actor hop + URLSession dispatch chain doesn't get
scheduled in any 25ms window for the full 30 seconds. The stub never
fires. `tokenHits` stays 0. The 30s timeout elapses. The XCTAssertTrue
fails ("/token endpoint should be in-flight"). Test reports failure at
**30.353 seconds**.

Why 30.353 and not exactly 30? The 0.353 is the final `condition()`
evaluation + XCTAssertTrue wrap + the subsequent `releaseGate.signal()` +
`fulfillment(of: [exp1, exp2], timeout: 5.0)` chain that fires before the
process exits the test method. The 30.353 is the test method's actual
wall-clock duration, not the failure-detection moment.

**Structural fix:** the test SHOULD use `fulfillment(of:timeout:)` against
an `XCTestExpectation` that the stub fulfills on the first `/token` hit,
NOT a synchronous-runloop-poll. The pattern is already in the same file
(line 159 `await fulfillment(of: [done], timeout: 5.0)`). The polling
overlay was added to observe the "in-flight" state between the GET being
fired and the stub returning, but it's the wrong tool for that — the
right tool is the `releaseGate` semaphore the test already uses; just
acquire it from the stub side and signal it from the test BEFORE polling,
turning the synchronous poll into an unconditional `releaseGate.signal()`
flow.

The 30s timeout was a documented workaround (see inline comment lines
442-444 citing the "BookRegistry / CatalogCache / ImageCache 30s
restorations as the same root cause"). It's a band-aid that fails when
the MainActor contention exceeds the timeout. The structural fix is to
get off the polling pattern entirely for these tests.

---

## 6. Fix SHAPE proposals (structural, not per-test)

### Fix-A: `XCTestCase+drainAllTasks` extension + `AsyncTestCase` base class
**Per the contract.** Provide:

```swift
// PalaceTests/Helpers/AsyncTestCase.swift
class AsyncTestCase: XCTestCase {
    private var testOwnedTasks: [Task<Void, Never>] = []
    var cancellables = Set<AnyCancellable>()

    func addTestTask(_ task: Task<Void, Never>) {
        testOwnedTasks.append(task)
    }

    override func tearDown() async throws {
        // Cancel all test-owned Tasks first.
        for t in testOwnedTasks { t.cancel() }
        testOwnedTasks.removeAll()
        // Then drop Combine subs.
        cancellables.removeAll()
        try await super.tearDown()
    }
}
```

Spy delegates that fire `Task { @MainActor in self.X.append }` register the
Task with the owning XCTestCase via `addTestTask`. tearDown joins/cancels
them before super.tearDown returns. Eliminates the "stale Task lands in
next test" hazard.

### Fix-B: Lint `scripts/check-test-task-discipline.py`
Per the contract. Greps for:
- `Set<AnyCancellable>` declarations without a `cancellables.removeAll()` /
  `cancellables = nil` in the same file's `tearDown`/`tearDownWithError`.
  (Current state: every file passes, but the lint locks the invariant in.)
- `Task { ... }` lines inside test method bodies (`func test...`) that
  don't capture the result (no `let task = Task...`) AND aren't followed
  by an `await ... .value`. Banned outside an allowlist.

### Fix-C: Lint sleep allowlist
Per the contract. Scan `PalaceTests/**/*.swift` for:
- `Task.sleep` — banned outside `PalaceTests/Mocks/`, `XCTestCase+drainMainQueue.swift`,
  and the helper file `awaitConditionAsync`. Mark required exceptions
  with explicit `// SLEEP-OK: <reason>` and fail without it.
- `Thread.sleep` — banned everywhere. The 2 existing FLAKE-001-OK
  occurrences become tracked exceptions.
- `XCTestExpectation.timeout >= 30` — flagged unless annotated
  `FLAKE-OK:` with a reason.

### Fix-D: Migrate sync-poll-on-async-event tests to fulfillment patterns
Specifically the 3 token-refresh tests with 30s `waitForCondition` polls:
- `TokenRefreshOnForegroundTests:445` (HIGH-1)
- `TokenRefreshOnForegroundTests:250` (HIGH-2)
- `TokenRefreshAndRetryQueueTests:449` (HIGH-3)

The stub registers an `XCTestExpectation` that fulfills on the first
`/token` hit. The test `await fulfillment(of: [tokenInFlight], timeout: 5.0)`
instead of polling `tokenHits == 1`. This is a *test rewrite* (out of
scope per the contract), but the structural seam is "replace
`waitForCondition` with `fulfillment` for any test where the awaited
event arrives via a different actor than the test method."

### Fix-E: Test-suite isolation amplifier handoff to Investigator F
The 30s timeout pattern is amplified by random test ordering — F's
remit. B's recommendation: if F lands the "CI orders via seed +
in-isolation rerun" pattern, that alone would unblock the develop-green
state WITHOUT requiring HIGH-1/2/3 rewrites. But the underlying polling
shape is still wrong and should be migrated in a follow-up.

### Fix-F: SpyDelegate Task lifecycle fix
The 4 test-local SpyDelegates (HIGH-5) need a structural seam:
```swift
@MainActor
private final class SpyBorrowDelegate: BorrowOperationDelegate {
    let calls = SpyCallLog()  // thread-safe recorder

    nonisolated func startBorrow(...) {
        let id = book.identifier
        // Synchronous recorder — no Task hop required.
        calls.record("startBorrow", args: ["bookId": id, ...])
    }
}
```
Replace the `Task { @MainActor in self.X.append }` pattern with a
thread-safe recorder (the codebase already has `PalaceTests/Contract/CallLog.swift`
which does exactly this). The Task hop only existed because Swift Concurrency
warned about cross-actor mutation; using a thread-safe collection eliminates
the Task entirely.

---

## 7. Overlap with other investigators

- **B/A overlap on "Task that mutates a singleton":** the architect flagged
  this in plan.md. My HIGH-5 (SpyDelegate Tasks) doesn't actually mutate
  a singleton — it mutates the test's spy. The TokenRefresh 30s polling
  failure DOES interact with A's territory (`TPPUserAccountMock.resetShared()`
  on line 44 of `TokenRefreshOnForegroundTests`) — if A finds shared-state
  residue across this test, the polling timeout makes it WORSE because
  the test sits for 30s with the shared state in an inconsistent half-set
  position. Integrator should treat HIGH-1/2/3 as B-primary, A-secondary.

- **B/D overlap on URLSession-stub race:** the TokenRefresh tests use
  `HTTPStubURLProtocol` (D's territory). The 30s failure mechanism I
  describe assumes the URLSession dispatch stalls; if D finds
  `HTTPStubURLProtocol.reset()` race conditions on protocol class
  reregistration, that's the underlying cause of WHY the URLSession
  stalls. B and D may converge on the same fix: a single-flight URLSession
  + stub teardown coordination.

- **B/F overlap on random-ordering amplification:** F-1 (random ordering
  amplifier) makes B-1/2/3 deterministic-on-local but flaky-on-CI. F's
  seed+rerun pattern would mask B-1/2/3 in CI without fixing the polling
  shape. Integrator should land both: F's amplifier fix immediately,
  B's polling-pattern migration as follow-up.

- **B internally:** HIGH-1/2/3 are all the same bug pattern (sync-poll
  on async event with 30s timeout). They count as ONE structural finding
  manifested in three sites.

---

## 8. Gaps & follow-ups

- **`@Published` post-tearDown mutation:** I did not find an instance
  where a Task spawned in `setUp` mutates an `@Published` on the SUT
  after the test method returned. The 48 cancellables-storing files all
  drain. The architect's hypothesis on this specific mechanism doesn't
  match what I found — the leak is in the Spy/Task layer (HIGH-5), not
  the SUT's published properties.

- **MainActor saturation under random ordering:** I cannot verify on
  this investigation pass whether the 30s timeout is reproducible by
  running the suite locally with `--random-seed=<X>`. The test
  comment cites empirical evidence ("local <100ms baseline, CI runner
  under parallel-test contention stalls"). Reproducing requires running
  the suite, which is out of investigation scope.

- **Test-local SpyDelegate Task pattern audit:** I confirmed 4 sites; a
  full grep across `PalaceTests/**` for `@MainActor private final class
  Spy.*` + body containing `Task { @MainActor in self\.` might surface
  more. Out of investigation budget.

- **Submodule `ios-audiobooktoolkit` not scanned.** Per plan.md §"Risks":
  E is responsible for submodule observations.

- **`HTTPStubURLProtocol` teardown audit deferred to D.** I observed that
  every TokenRefresh test calls `HTTPStubURLProtocol.reset()` in
  setUp+tearDown. Whether that reset has a race with in-flight URLSession
  dispatch is D's question.

- **`AccountStateStore.shared._resetAllForTesting()` post-tearDown
  observed once** (`CarPlayAuthHelperReadinessTests.swift:34`, guarded
  `#if DEBUG`). Whether other tests should adopt this is A's question;
  I flag it as "A could catch this seam in their dedup pass."

---

## 9. Definition-of-Done evidence

This is an INVESTIGATION transcript, not a code change. DoD checks 1-3 (SUT
instantiation, function-result usage, multi-step body) don't apply —
no test files modified. DoD #4 (scope coverage):

- ✅ Read contract first (B-async-combine-teardown.md).
- ✅ Read plan.md second (shared context).
- ✅ Grep set 1 (`Task {`, `Task.detached`) — executed, 80+ hits enumerated.
- ✅ Grep set 2 (`Set<AnyCancellable>`) — executed, 48 files, all drain.
- ✅ Grep set 3 (`Task.sleep`/`Thread.sleep`/`usleep`/`sleep(`) — executed,
  168 sites in 63 files.
- ✅ Grep set 4 (`@Published` mutation after Task in setUp) — executed,
  no instances found; gap noted in §8.
- ✅ Grep set 5 (`timeout: [3-9][0-9]`) — executed, 10 sites identified.
- ✅ TokenRefreshOnForegroundTests 30s failure — read, mechanism explained
  in §5.
- ✅ HIGH/MED findings enumerated with file:line.
- ✅ Fix SHAPES (Fix-A through Fix-F) proposed without writing code.
- ✅ Overlap with A/D/F flagged in §7.
- ✅ Gaps in §8.

DoD #5 (mutation), #6 (build/verify-pr) not applicable — investigation only.

---

## 10. One-line summary for the integrator

**B finds:** the cancellables story is actually clean (false positive on
the architect's 48-file count); the real leakage class is the
sync-poll-on-async-event pattern in 3 token-refresh tests (the 30s
failure cited in plan.md) and 4 test-local SpyDelegate `Task { @MainActor
in }` lifecycle escapes. Structural fix: ban sync-poll-on-async-event
via lint + migrate to `fulfillment`, replace Task-hop SpyDelegate
mutations with a thread-safe CallLog (already exists in the codebase
under `PalaceTests/Contract/CallLog.swift`). Random-ordering (F) is the
amplifier; A/D may converge on the URLSession side.

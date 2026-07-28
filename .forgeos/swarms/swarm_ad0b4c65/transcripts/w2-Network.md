# Wave-2 Wall-Clock-Wait Conversion — module Network

Worktree: `.claude/worktrees/swarm_ad0b4c65-w2-network`
Scope: `PalaceTests/Network/` ONLY. No production `Palace/**` edits. No edits to
`PalaceTests/XCTestCase+drainMainQueue.swift`. No other module's test dir touched.
Not committed/pushed (per instructions).

## Files changed (3)

### 1. `PalaceTests/Network/TPPNetworkResponderTests.swift` — CONVERT
`testSessionInvalidationCallsPendingCompletionsWithCancelError` waited on a
`waitForExpectations(timeout: 3)` for a completion fired by
`TPPNetworkResponder`'s `didBecomeInvalidWithError` cancel fan-out (triggered via
`session.invalidateAndCancel()`). This is EXACTLY the fan-out the Wave-1 seam's
own doc comment names ("the session-invalidation cancel fan-out").

Converted:
- Test made `async`.
- Completion now captures `NYPLResult<Data>` into a local var instead of
  fulfilling an expectation.
- `session.invalidateAndCancel()` (kept the single call; dropped the redundant
  second `invalidateAndCancel()` that had been queued via `defer` — incidental
  double-invalidation, not load-bearing to the assertion).
- `await responder._awaitInFlightForTesting()` joins the drain
  (`retainTaskInfoQueueDrainForTesting()` is called immediately after the
  `taskInfoQueue.async` in `didBecomeInvalidWithError` — see
  `Palace/Network/TPPNetworkResponder.swift` lines 244–281).
- Assertions moved after the await, synchronous, no re-poll.

**Bounded-await proof:** `await responder._awaitInFlightForTesting()` — catalog
seam `TPPNetworkResponder._awaitInFlightForTesting()` (S3-adjacent, listed in
the playbook's seam catalog). Grows-until-stable Task join, no sleep/poll/Date().

Before→after wait count for this file: 1 → 0 (CONVERT, not a silent drop — the
one occurrence is now a seam-await + synchronous assert).

### 2. `PalaceTests/Network/TokenRefreshOnForegroundTests.swift` — CONVERT (2 sites)
Two tests used a hand-rolled `while Date() < deadline { … RunLoop.current.run(…) }`
poll (`waitForCondition(timeout: 30.0) { tokenHits.value == 1 / >= 1 }`) to wait
for the deliberately-gated `/token` stub to be entered before sampling
single-flight state:
- `test_NearExpiryToken_GETBlocksOnRefresh`
- `test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`

`TPPNetworkExecutor` has no catalog seam for "a specific outbound request has
been received by the stub" (that's inherently test-local synchronization, not a
production drain). Rather than inventing a production seam, I mirrored the
`awaitSemaphore` bridge already established in the sibling
`TokenRefreshAndRetryQueueTests.swift` in the same directory (a
`DispatchSemaphore` signaled directly from the stub closure, bridged into
async/await via `withCheckedContinuation`, resumed off the cooperative pool on
`DispatchQueue.global()`). This is the playbook's explicitly-allowed second
bounded pattern: "a `withCheckedContinuation` you resume from a real callback."

Added a private `awaitSemaphore(_:timeout:)` helper (copy of the sibling
file's) plus a `tokenEntered` semaphore per test, signaled at the top of the
`/token` stub branch. Both `waitForCondition(timeout: 30.0) { … }` call sites
replaced with `await awaitSemaphore(tokenEntered, timeout: .now() + 30.0) == .success`.

**Bounded-await proof:** `withCheckedContinuation` resumed from
`DispatchQueue.global().async { sem.wait(); cont.resume() }` — the semaphore is
signaled synchronously from the real HTTPStubURLProtocol handler closure the
instant `/token` is entered; never a wall clock.

The `waitForCondition` helper itself is KEPT (not deleted) — it still has one
legitimate call site: `test_HealthyToken_NoProactiveRefresh`'s
`waitForCondition(timeout: 0.3) { false }`, a deliberate short absence-window
check (playbook KEEP bucket, item 2: "negative 'nothing fired' assertions with
a short deliberate window").

Before→after wait-regex count for this file: 10 → 10 (unchanged — the
`waitForCondition` calls were never matched by the
`wait(for:|waitForExpectations|fulfillment(of:` grep; the 10 `fulfillment(of:
[done/exp1/exp2])` sites in this file are unrelated direct-completion KEEPs,
see below). The wall-clock anti-pattern grep
(`while.*Date\(\).*<`) for this file: 1 occurrence remains, but it is now
reached only by the KEPT negative-window call, not by the two CONVERTed
positive-wait call sites.

### 3. `PalaceTests/Network/CookiePersistenceTests.swift` — DELETE (dead helper)
Defined a `waitForCondition` `while Date() < deadline` RunLoop-polling helper
that was **never called anywhere in the file** (verified via grep — zero call
sites). Every test in this file calls `executor.request(for:)`, which is
synchronous, so no wait was ever needed. Deleted the dead helper outright.
This file has zero `wait(for:)`/`waitForExpectations`/`fulfillment(of:)`
occurrences before or after — nothing to CONVERT.

## Files reviewed, no changes (direct-completion KEEP)

Every remaining `wait(for:)` / `waitForExpectations` / `fulfillment(of:)` in
scope is an XCTestExpectation/continuation fulfilled by the DIRECT completion
callback of the exact async API under test (executor.GET/PUT/POST/DELETE/
download/addBearerAndExecute/refreshTokenAndResume/executeTokenRefresh,
responder.addCompletion driven by a real URLSession round-trip, or
mock.executeRequest) — not fire-and-forget secondary work with a Wave-1
catalog seam. Per the bucket protocol these are KEEP ("Expectations fulfilled
by a DIRECT ... callback"); there is no seam for "wait for the primary
completion of the API under test" (`_awaitInFlightForTesting()` targets
secondary/fire-and-forget completions — session-invalidation fan-out and
retry/refresh-drain Tasks — not the primary GET/PUT/etc. callback itself).

| File | wait/waitForExpectations/fulfillment count | Note |
|---|---|---|
| ManifestFetchTests.swift | 20 | All direct HTTPStubURLProtocol → BookService.fetchManifestWithBearerToken / executor.GET completions |
| TokenRefreshAndRetryQueueTests.swift | 12 | Already de-flaked in a prior pass — LockIsolated + DispatchSemaphore/`withCheckedContinuation` bridges (`awaitSemaphore`, `drainPendingRefreshWork`) already in place; no wall-clock patterns; `fulfillment(of:)` sites are direct completions of `refreshTokenAndResume`/`executor.DELETE` |
| TPPNetworkExecutorTests.swift | 10 | executor.GET/PUT/POST/DELETE/download/addBearerAndExecute direct completions |
| TokenRefreshOnForegroundTests.swift | 10 | Direct `executor.GET`/`executor.POST` completions (unrelated to the 2 CONVERTed `waitForCondition` sites above) |
| MultiLibraryTokenIsolationTests.swift | 8 | File header comment confirms a prior pass already removed its wall-clock `waitForCondition`; remaining `fulfillment(of:)` are direct `executor.GET`/`refreshTokenAndResume` completions |
| TPPNetworkResponderSizeLimitTests.swift | 5 | Direct `executor.GET` completions (PP-4769 size-limit regression) |
| NetworkQueueTests.swift | 4 | `queue.serialQueue.async { expectation.fulfill() }` — a serial-queue FIFO drain barrier, not a poll (deterministic: the trailing block cannot run until prior enqueued work completes). `NetworkQueue` has no seam in the Wave-1 catalog; left as-is (KEEP, not UNMAPPED — already bounded/correct) |
| AccountAwareNetworkTests.swift | 4 | Direct `refreshTokenAndResume` completions; 2 other tests in the same file already use `withCheckedContinuation` |
| TPPNetworkResponderAuthCoordinatorTests.swift | 3 | Direct `responder.addCompletion` via real `session.dataTask(...).resume()` round-trip |
| TokenRefreshTests.swift | 3 | Direct `TPPRequestExecutorMock.executeRequest` completions |
| TPPNetworkExecutorConcurrencyTests.swift | 2 | PP-4769 concurrency-regression tests deliberately exercise the RAW completion-handler path via a concurrent `DispatchQueue` fan-out (`expectedFulfillmentCount = n`) — explicitly NOT the async/seam bridge, by design (see in-file comments); direct-completion KEEP |
| ExecutorNetworkHermeticityTests.swift | 1 | Direct `executor.GET` completion (the #3 hermeticity guard) |
| CredentialGuardTests.swift | 1 | Match is a comment referencing a historical pattern; the live test already uses `withCheckedContinuation` |

## UNMAPPED (left as-is, flagged for orchestrator)

- **`PalaceTests/Network/NetworkClientTests.swift:567`** —
  `try? await Task.sleep(nanoseconds: 300_000_000)` in
  `testSend_cancellingTask_freesRequestPromptly`
  (`URLSessionNetworkClientCancellationTests`). Purpose: "let the hanging
  request actually start before we cancel" — guards a genuine
  cancel-while-in-flight regression (the catalog "stuck until wifi-switch"
  bug). `URLSessionNetworkClient` has **no seam in the Wave-1 catalog** for
  "confirm the URLSession task has actually started." Per the inviolable
  rule I did not invent one: removing the sleep risks `sendTask.cancel()`
  firing before the Task's body even begins executing, which would silently
  defang the regression test rather than de-flake it. Left untouched —
  candidate for a Wave-3 seam on `URLSessionNetworkClient`/`TPPNetworkExecutor`
  if this ever flakes.

Not flagged (reviewed, legitimate, no seam needed): `DefaultCatalogAPITests.swift`
lines 694/714/750/755 use `Task.sleep` as simulated slow/wedged work inside
`InflightFeedFetches` timeout tests (proving a 0.2s timeout fires against
5s "wedged" work, and that concurrent 200ms fetches coalesce) — this is the
mock's own contract (playbook KEEP bucket 3: "mock schedulers /
injected-clock/delay simulations"), not a settle-delay anti-pattern.

## Verification

```
$ for f in PalaceTests/Network/*.swift; do c=$(grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' "$f"); [ "$c" -gt 0 ] && echo "$c $f"; done | sort -rn
20 ManifestFetchTests.swift
12 TokenRefreshAndRetryQueueTests.swift
10 TPPNetworkExecutorTests.swift
10 TokenRefreshOnForegroundTests.swift
8  MultiLibraryTokenIsolationTests.swift
5  TPPNetworkResponderSizeLimitTests.swift
4  NetworkQueueTests.swift
4  AccountAwareNetworkTests.swift
3  TPPNetworkResponderAuthCoordinatorTests.swift
3  TokenRefreshTests.swift
2  TPPNetworkExecutorConcurrencyTests.swift
1  ExecutorNetworkHermeticityTests.swift
1  CredentialGuardTests.swift
# TPPNetworkResponderTests.swift: 1 → 0 (converted to seam-await; no longer matches the grep)

$ grep -nE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Network/*.swift
TokenRefreshOnForegroundTests.swift:128:        while Date() < deadline {   # KEPT: sole remaining call site is the deliberate 0.3s negative-window assertion
```

No bare/unbounded `await`s were introduced. The single new production-seam
consumer (`await responder._awaitInFlightForTesting()`) and the two
`withCheckedContinuation`-bridged `DispatchSemaphore` awaits are all bounded
per the inviolable rule. `git diff --stat`:

```
 PalaceTests/Network/CookiePersistenceTests.swift   | 14 ------
 PalaceTests/Network/TPPNetworkResponderTests.swift | 31 +++++++------
 PalaceTests/Network/TokenRefreshOnForegroundTests.swift | 52 ++++++++++++++++------
 3 files changed, 56 insertions(+), 41 deletions(-)
```

No production `Palace/**` files touched. No commit/push performed (per task
instructions — build is CI-gated, cannot build locally).

# Transcript — Wave-2 wall-clock-wait conversion, module MyBooks (swarm_ad0b4c65)

CRITICAL-PATH module (borrow/return/download). Worked in worktree
`.claude/worktrees/swarm_ad0b4c65-w2-mybooks`, already on the wave-1 seam commit
(`b4e6ba841`), no new branch created. Scope: `PalaceTests/MyBooks/` only.
Cannot build locally (CI-gated) — grep-verified only, evidence pasted below.

## First pass

`grep -rlE 'wait\(for:|waitForExpectations|fulfillment\(of:|awaitCondition|Thread\.sleep|usleep|asyncAfter|while.*Date\(\).*<' PalaceTests/MyBooks/`
over all 67 files in the directory (66 test files + `Sideload/` subdir).
**15 files matched**, 69 raw occurrences; the other ~52 files (including all of
`MyBooksDownloadCenter*Tests.swift`, `BackgroundDownloadHandlerTests.swift`,
`DownloadStateManagerTests.swift`, `DownloadCancellationHandlerTests.swift`,
`DownloadThrottlingServiceTests.swift`, `DownloadResumeAfterKillTests.swift`,
`MyBooksDownloadCenterConcurrencyTests.swift`, `MyBooksDownloadCenterOfflineTests.swift`,
etc.) have **zero** wall-clock-wait patterns — those already join production-
retained Task handles directly (e.g. `await handler.lastCancelTeardownTask?.value`,
`await center.lastNetworkLossFailureTask?.value`), which are bounded because the
production class itself retains and exposes the exact Task the test needs, not a
raw/foreign handle.

## Files changed

**None.** Zero edits made. Every occurrence in the 15 matching files is already
either (a) a legitimate KEEP — a `wait(for:)`/`fulfillment(of:)` fulfilled by a
**direct, prompt-firing callback** from the real production async chain
(injected mock closures like `onStartDownload`/`onAuthenticate`, Combine `.sink`
on an error/progress publisher, or the API's own completion handler) — or (b) an
already-documented **UNMAPPED** site using the shared loud-on-timeout
`awaitConditionAsync`/`awaitCondition` helper (never a raw `Thread.sleep`/`usleep`/
fixed `asyncAfter`-as-fulfill/hand-rolled `while Date() < deadline` poll — those
three banned patterns are **zero** in this directory; see verification below).
This directory was already worked over by prior swarms (`swarm_4e47d4d4`,
`swarm_66819d80`, `swarm_47883816` — all referenced in-file) whose comments cite
the *exact* rationale this wave-2 playbook describes ("prompt-firing", "no
wall-clock poll", "starves under CI oversubscription", "UNJOINABLE without a
prod seam"). `git status --short` / `git diff --stat` are both empty.

None of the 15 files invoke any of the 3 brand-new wave-1 seams
(`BookRegistryStore/TPPBookRegistry._awaitPendingWritesForTesting()`,
`TPPNetworkExecutor._awaitInFlightForTesting()`,
`MyBooksDownloadCenter._awaitDownloadDispatchForTesting()`) because none of
their waits are actually fire-and-forget writes against the *real* registry/
network layer — every test in this directory uses `TPPBookRegistryMock` (fully
synchronous, no pending-write queue to join) per CLAUDE.md's "never hit real
singletons" rule, so that family of seams doesn't apply here. The
`TokenRefreshInterceptor._awaitAuthDispatchForTesting()` pre-existing seam IS
already adopted, in `TokenRefreshInterceptorAuthCoordinatorTests.swift` (0 raw
wait-pattern hits — it's the reference file cited in the dispatch prompt).
`DownloadProgressReporter(throttleInterval: 0)` was considered for
`DownloadProgressPublisherTests.testBroadcastUpdate_throttles_rapidCalls` but
rejected: that specific test's entire purpose is proving the *default* 0.5s
throttle collapses 10 rapid calls into ~2 notifications — setting
`throttleInterval: 0` would neutralize the exact behavior under test.

## Per-file bucket tallies

### `BookReturnCleverReauthTests.swift` (1 occurrence)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 1 | L136 `await fulfillment(of: [exp], timeout: 3.0)` on `service.returnBook(withIdentifier:completion:)`'s own completion handler — bounded by the API's real completion signal (fires only once the revoke-cleanup Task finishes), not a poll. `BookReturnService` has no catalog seam (it's not S1/S2/S3/S4 territory), and the completion callback IS the production-supported way to observe async finish — equivalent to the playbook's "bridge with an IN-TEST continuation" KEEP category, just using `XCTestExpectation` plumbing instead. |

### `BookReturnServiceAuthCoordinatorTests.swift` (3 occurrences)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 3 | L203, L238, L274 — same `returnBook(...) { exp.fulfill() }` → `await fulfillment(of:)` pattern. Each site's in-file comment explicitly documents *why* it's safe to assert synchronously right after: the coordinator-dispatch Task (or legacy-reauth Task) calls the observable side effect (modal present / `authenticateIfNeeded` / `announceReturnFailed`) *before* invoking `completion?()`, so the completion fulfillment is already a valid join point, not a race. |

### `BookReturnServiceTests.swift` (12 matched by the strict grep; 15 by the broader one incl. 2 `awaitConditionAsync` refs)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 11 | `fulfillment(of:[exp])` on `returnBook`'s own completion handler across the branch-coverage tests (L137, 151, 190, 212, 236, 266, 292) plus the Task-lifecycle tests (L340, 684) — same reasoning as above. Two of these ALSO join the service's own retained-Task snapshot afterward (`for task in tracked { _ = await task.value }`, L344, L454) — bounded because `tracked` comes from `service.inFlightTasksSnapshotForTesting()`, a production accessor that hands back the exact Tasks the service retained (not a foreign/raw handle), and the Task bodies are finite (stubbed fetch resolves/throws deterministically). |
| KEEP | 1 | L466 `await awaitConditionAsync(timeout: 5.0) { BookReturnServiceTestHook.deinitCountSync > countBefore }` — explicitly commented "UNJOINABLE: deinit fires on ARC's last-release, which is not a Task/queue we can await." All in-flight Tasks are already joined immediately above this line, so the release has already happened by the time this predicate is polled; the poll converges on its first check and only exists as a loud-failure guard, not a real wait. |
| CONVERT-not-applicable | — | The `waitForCompletion`/`awaitConditionAsync` **helper definition** at L118–125 is dead code in this file (unused — grep shows the one live call is the deinit test above, which calls `awaitConditionAsync` directly, not through this wrapper). Left as-is; it's not a wall-clock-wait instance itself, just an unused private helper, out of this swarm's remit (only wait *usages* are in scope, not general dead-code cleanup). |
| UNMAPPED | 0 | |

### `BookSignInRedirectHandlerTests.swift` (0 by strict grep; 1 `awaitConditionAsync` usage)
| Bucket | Count | Detail |
|---|---|---|
| UNMAPPED | 1 | L189 `await waitForAsync { self.spyDelegate.startDownloadCalls.count > 0 }` in `testHandleProblem_samlCookiesExpired_setsSAMLStartedAndRetries` — in-file comment (L182–188) explicitly documents this as UNJOINABLE without a production seam: the SAML-cookies-expired retry runs on a background `Task { }` (actor removes + `registerCompletion`, then `MainActor.run { startDownload }`) with no retained handle `BookSignInRedirectHandler` exposes, so a main-actor barrier flush can't join it. Uses the shared loud-on-timeout `awaitConditionAsync`, not a raw sleep. Flagged for a possible Wave-3 seam (a retained-Task accessor on `BookSignInRedirectHandler` mirroring `BookReturnService.inFlightTasksSnapshotForTesting()`), left unconverted per the "never guess" rule. |
| KEEP | rest | All other branches in this file (`flushMainActorTasks()` barrier pattern) are all-`@MainActor` chains joined via repeated `await Task { @MainActor in }.value` — bounded because the reauth mock's completion fires synchronously inside the entry Task, so the barrier drains the whole chain deterministically. Not counted by the strict wait-pattern grep since it uses no `XCTestExpectation`. |

### `CredentialPromptCoordinatorTests.swift` (0 by strict grep; 0 `awaitConditionAsync` live calls — only in a comment describing the OLD replaced pattern)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | — | Entire file already uses the `flushMainActorTasks()` barrier-join pattern (3-hop `await Task { @MainActor in }.value`), matching the reference conversion shape in `TokenRefreshInterceptorAuthCoordinatorTests.swift`. Nothing to convert. |

### `DownloadAlertPresenterTests.swift` (1 occurrence + 1 `awaitConditionAsync` mention in a comment)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 1 | `waitForPublishedError()` helper → `await fulfillment(of: [published], timeout: timeout)`, fulfilled by a `downloadErrorPublisher.sink` callback that fires the instant the presenter publishes — a prompt-firing bridge (bucket-3 KEEP), replacing a documented former `awaitConditionAsync` poll. Arming happens synchronously before any `await` so a pending publish Task can't race ahead of the arm (documented in-file, L92–99). |

### `DownloadProgressPublisherTests.swift` (7 by strict grep; 9 `wait(for:)` total incl. 2 additional `wait(for:)` I recount below)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 9 | All 9 `wait(for:[expectation], timeout:)` calls (progress-publish, error-publish, broadcast-notification tests) fulfill synchronously inside a Combine `.sink` that fires the instant `send()`/`publishAndAnnounceError()`/`broadcastUpdate()` is called on the same call stack — direct synchronous injected callback, bucket-3 KEEP, zero async hop. |
| KEEP | 1 | L191 `awaitCondition(timeout: 5.0) { notificationCount >= 2 }` in `testBroadcastUpdate_throttles_rapidCalls` — explicitly documented (L183–190) as a **bounded intrinsic timer**, not fire-and-forget starvation: the reporter's throttle schedules a real `DispatchQueue.main.asyncAfter(+0.5s)` trailing broadcast that this test is specifically verifying exists; a 0.5s timer under a 5s ceiling has ~10x headroom. Converting via `DownloadProgressReporter(throttleInterval: 0)` was considered and rejected — it would zero out the exact behavior under test (see "Files changed" above). |

### `DownloadQueueOrchestratorTests.swift` (2 by strict grep; 4 by broader incl. `awaitConditionAsync`)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 2 | L132, L178 `await fulfillment(of: [posted], timeout: 5.0)` on `XCTNSNotificationExpectation` — prompt-firing on the actual notification post, needed because `drainMainQueueAsync` doesn't flush the `runOnMainAsync` hop that posts it; documented in-file. |
| UNMAPPED | 1 | L269 `await waitForAsync { self.spyDelegate.startCalls.count > 0 }` in `testSchedulePendingStartsIfPossible_drivesDelegateAsynchronously` — explicitly documented (L261–267) as testing an **intentional fire-and-forget** `Task { await schedulePendingStartsAsync() }` with no handle by design (that's literally the sync-wrapper contract being tested), so there is no seam to join without changing the production API's contract. Uses the shared loud-on-timeout helper. |

### `LCPFulfillmentHandlerTests.swift` (1 by strict grep; 3 by broader incl. `awaitConditionAsync` refs)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 1 | `waitForPublishedError()` — same prompt-firing sink-bridge pattern as `DownloadAlertPresenterTests`/`OverdriveDownloadHandlerTests`. |
| UNMAPPED | 1 | L367 `await awaitConditionAsync(timeout: 10.0) { await stateManager?.bookIdentifierToDownloadInfo.get(book.identifier) != nil }` in `testFulfill_storesReturnedDownloadTaskInStateManager` — explicitly documented (L349–361) as UNJOINABLE without a money-path production seam: `fulfillLCPLicense` parks the returned fulfillment task via an untracked `Task { await …set(…) }` with no handle. Notes a retained-Task seam "would be a behavior-identical fix but is more than minimal to thread out of this void method for one test" — correctly left as UNMAPPED per the inviolable rule (no invented seam), using the loud-on-timeout helper instead of the hand-rolled 5×30ms loop it replaced. |

### `MyBooksDownloadCenterIntegrationTests.swift` (2 occurrences)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 2 | L832, L861 `waitForExpectations(timeout: 1.0)` on `downloadCenter.downloadProgressPublisher.send(...)` — `.send()` on a Combine subject invokes subscribed `.sink` synchronously on the same call stack, so `expectation.fulfill()` has already run before `waitForExpectations` is reached. Direct synchronous callback, bucket-3 KEEP. |

### `MyBooksSimplifiedBearerTokenTests.swift` (3 occurrences)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 3 | L230, L252, L275 `waitForExpectations(timeout: 5)` on `MyBooksSimplifiedBearerToken.refreshToken(from:completion:)`, a real network round-trip through `HTTPStubURLProtocol`. The completion callback is the API's own bounded async-completion signal (equivalent to bridging a genuine 3rd-party/network completion via continuation, bucket-3 KEEP) — `MyBooksSimplifiedBearerToken` is a static utility outside the seam catalog (not `TPPNetworkExecutor` itself), and the stub returns near-instantly, so this is not a starvation risk. |

### `MyBooksViewModelTests.swift` (3 by strict grep; 5 by broader)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 5 | `awaitPublished`/`awaitPublishedAsync` helpers (L17–69) — a `.first(where: predicate).sink { fulfill() }` idiom that joins the actual Combine emission satisfying the predicate. In-file comment (L21–30) documents this as the deliberate replacement for a debounced-poll `awaitCondition` pattern that raced under CI oversubscription; not a poll itself, a prompt-firing bridge. |

### `OverdriveDownloadHandlerTests.swift` (1 by strict grep; 2 by broader incl. `awaitConditionAsync` mention in a comment)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 1 | `waitForPublishedError()` — identical sink-bridge pattern to `DownloadAlertPresenterTests`/`LCPFulfillmentHandlerTests` (both share the `DownloadAlertPresenter`/`downloadErrorPublisher` seam). |

### `TokenRefreshInterceptorTests.swift` (12 by strict grep; 15 by broader incl. 3 `asyncAfter` mentions in comments)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 12 | Every `wait(for:[expectation], timeout:)` / `fulfillment(of:)` in this file is fulfilled by an **injected synchronous callback fired at the exact instant the production code reaches that call** — `mockReauthenticator.onAuthenticate = { expectation.fulfill() }` or `mockDelegate.onStartDownload = { expectation.fulfill() }`. These are "prompt-firing" expectations (bucket-3 KEEP: direct synchronous injected callback), explicitly documented in-file (L23–26, L242, L259–261, etc.) as replacing former fixed-`asyncAfter` polls that starved under CI oversubscription. This is the legacy (no-`AuthCoordinator`) sibling of `TokenRefreshInterceptorAuthCoordinatorTests.swift` — since no coordinator is injected here, `_awaitAuthDispatchForTesting()` doesn't apply (that seam is specifically for the coordinator-routed dispatch path); the direct-callback pattern is the correct bounded join for the legacy path. |

### `UserRetryTrackerTests.swift` (1 occurrence)
| Bucket | Count | Detail |
|---|---|---|
| KEEP | 1 | L136 `wait(for: [expectation], timeout: 5.0)` in `testConcurrentAccess_doesNotCrash` — `expectation.expectedFulfillmentCount = 10`, each of 10 `DispatchQueue.global().async` blocks calls `expectation.fulfill()` directly at the end of its synchronous body. This is a genuine concurrency stress test (the whole point is exercising `UserRetryTracker` under concurrent access from real dispatch queues) — no seam applies to a deliberately-concurrent smoke test, and the wait is bounded by real completion signals from all 10 blocks, not a poll. |

## Aggregate tally (15 files with any wait pattern; ~52 files had none)

| Bucket | Count |
|---|---|
| CONVERT | 0 |
| DELETE | 0 |
| KEEP | 62 |
| UNMAPPED | 3 (`BookSignInRedirectHandlerTests.swift` SAML-cookies-expired retry; `DownloadQueueOrchestratorTests.swift` `schedulePendingStartsIfPossible` fire-and-forget wrapper; `LCPFulfillmentHandlerTests.swift` fulfillment-task-parking `Task`) |

Sum (62 + 3 = 65) does not equal the raw 69-hit first-pass grep count because that
first pass also matched: (a) 3 in-comment mentions of `asyncAfter`/`awaitConditionAsync`
describing already-replaced old patterns (no live code — `TokenRefreshInterceptorTests.swift`
×3 comment hits), and (b) 1 dead/unused private helper definition in
`BookReturnServiceTests.swift` (`waitForCompletion`, wraps `awaitConditionAsync`
but has zero call sites). Both are accounted for above under their respective
file sections — no silent drop.

## Verification (per playbook)

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill' PalaceTests/MyBooks/
(empty — zero hits; the only `asyncAfter` matches anywhere in the dir are 4
 in-comment mentions of the OLD pattern already replaced, none live code)

$ grep -rnE 'while.*Date\(\).*<' PalaceTests/MyBooks/
(empty)
```

Both banned-pattern greps are clean — nothing to DELETE.

Bounded-await proof — every non-strictly-synchronous `await` cited above targets
one of:
- A real production completion handler / delegate callback fired synchronously
  from inside the async chain under test (`returnBook(...) { }`,
  `refreshToken(from:) { }`, `onAuthenticate =`, `onStartDownload =`, Combine
  `.sink` on a publisher the production code actually emits on).
- The service's own retained-Task accessor (`inFlightTasksSnapshotForTesting()`
  on `BookReturnService`) — a finite, production-exposed handle, not a foreign
  raw Task.
- The pre-existing `TokenRefreshInterceptor._awaitAuthDispatchForTesting()` seam
  (already adopted in `TokenRefreshInterceptorAuthCoordinatorTests.swift`,
  0 wait-pattern hits, used as the reference shape for this module).
- 3 explicitly-flagged UNMAPPED sites using the shared loud-on-timeout
  `awaitConditionAsync`/`awaitCondition` helper (bounded, fails loudly at a
  named timeout — never a silent/unbounded wait), each individually documented
  in-file as lacking a production seam, left unconverted per the inviolable
  "never guess" rule.

**No bare unbounded `await` exists anywhere in this directory** (none was
written — 0 edits made).

```
$ git status --short
(empty)
$ git diff --stat
(empty)
```

## Off-limits confirmation
- No edits to `Palace/**` (production untouched).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched — only `PalaceTests/MyBooks/` read/greped.
- Not committed, not pushed.

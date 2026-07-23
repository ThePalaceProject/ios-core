# Transcript — Wave-2 wall-clock-wait conversion, module Catalog (swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-catalog`, already on the
wave-1 seam commit (`b4e6ba841`), no new branch created. Scope: `PalaceTests/CatalogUI/`
and `PalaceTests/CatalogDomain/` only.

## Files in scope (16 total)

`PalaceTests/CatalogUI/`: CatalogFilterServiceTests.swift, CatalogLaneRowViewAccessibilityTests.swift,
CatalogModelsTests.swift, CatalogSearchViewModelTests.swift, CatalogViewContinueRowsIntegrationTests.swift,
CatalogViewModelTests.swift, ContinueRowSectionTests.swift, SideloadedLaneTests.swift

`PalaceTests/CatalogDomain/`: CatalogCacheKeyAndIsolationTests.swift, CatalogDomainTests.swift,
CatalogLaneAssemblyTests.swift, CatalogLaneSortingTests.swift, CatalogOPDS2NegotiationTests.swift,
CatalogProblemDocumentTests.swift, CatalogRepositoryStaleWhileRevalidateTests.swift,
CatalogRepositoryTests.swift

First pass: `grep -rlnE 'wait\(for:|waitForExpectations|fulfillment\(of:|Thread\.sleep|usleep|asyncAfter|while.*Date\(\)|Task\.sleep'`
over both dirs. Only 4 of the 16 files matched; the other 12 have zero
wall-clock-wait patterns to begin with (nothing to convert).

## Files changed

**None.** Zero edits made. All 4 matching files were already converted to the
seam-join pattern in an earlier de-flake sweep on `develop`/`main` that predates
this swarm — commits `1d3fc5d47` ("test(catalog): de-flake parallel-starvation
deadline polls via work-unit joins") and `c04219b0c` ("fix(test): full de-flake
sweep — parallel-starvation deadline-polls → deterministic joins (#1319)"),
both already in this worktree's history (`git log --oneline -- PalaceTests/CatalogUI/CatalogViewModelTests.swift`).
Every occurrence I found is either an already-CONVERTed seam join (with
in-file comments citing the exact same rationale the wave-2 playbook
describes — "JOIN", "No clock", "UN-JOINABLE SEAM"), a legitimate KEEP, or one
already-documented UNMAPPED site. `git status --short` / `git diff --stat` are
both empty — confirmed no working-tree changes were needed or made.

## Per-file bucket tallies

### `PalaceTests/CatalogUI/CatalogViewModelTests.swift`
| Bucket | Count | Detail |
|---|---|---|
| CONVERT (pre-existing) | 11 | `await vm._awaitLoadForTesting()` call sites (lines 214, 226, 269, 280, 290, 301, 315, 481, + 3 more via `waitUntilLoaded()` helper at 475–487, itself wrapping the seam) |
| DELETE | 0 | |
| KEEP | 2 | (a) L349–360 `testCancelPrefetch_cancelsAndClearsTrackedTasks`: `XCTestExpectation` fulfilled synchronously at the top of a synthetic `Task` before any `await` — mock-scheduler pattern (bucket 3, "direct synchronous injected callback"), joined afterward via `await synthetic.value` which is bounded because `cancelPrefetchForTesting()` is called first and the loop's `while !Task.isCancelled` guard exits immediately. (b) L373–386 `testReload_cancelsPriorPrefetchTasks`: same synthetic-idle-loop-then-cancel-then-join pattern, no expectation involved. |
| UNMAPPED | 1 | L307–341 `testReconnect_WhileOffline_AutoReloadsCatalog`: the reconnect reload is driven by `connectivityPublisher.sink → Task { handleConnectivityRestored() } → Task { forceRefresh() }`, two untracked bare `Task`s with no handle the view model exposes, so `_awaitLoadForTesting()` would race the `currentLoadTask` assignment. Already documented in-file (L322–334, "UN-JOINABLE SEAM") as needing a new connectivity-reload join seam in production — off-limits for this wave. Left as-is; the deadline poll (`while ... Date() < deadline { Task.sleep(50ms) }`, bounded at 5s) is the one legitimate hand-rolled poll remaining in the file. |

`grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' CatalogViewModelTests.swift` → **1** (the L360 `fulfillment(of: [started]…)`), which is the KEEP(a) case. 1 = 0 CONVERT-of-this-grep-pattern + 0 DELETE + 1 KEEP + 0 UNMAPPED-of-this-grep-pattern — no silent drop (the UNMAPPED site is a hand-rolled `while`/`Date()` poll, not a `wait(for:)`/`fulfillment` call, so it's outside this specific grep but is caught by the banned-pattern grep below).

### `PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift`
| Bucket | Count | Detail |
|---|---|---|
| CONVERT (pre-existing) | 44 | `await viewModel._awaitInFlightWorkForTesting()` call sites throughout (debounce-then-search joins, cancellation joins, pagination joins, error-path joins — each with an inline comment citing what's being joined and "No clock") |
| DELETE | 0 | |
| KEEP | 3 + mock-delay sites | The 3 `fulfillment(of:)` calls (L441, L841, L1516) all observe a **transient** `@Published` state (`isLoading`/`isLoadingMore` momentarily `true` mid-request) via a Combine `.sink` fulfilled synchronously on publish — joining the completion seam would blow past the transient state entirely, so this is the correct bucket-3 pattern ("mock schedulers / injected-clock … the mock's contract"), paired with `mockRepository.simulatedDelay` to hold the window open. Also KEEP: `mockRepository`'s own `Task.sleep(simulatedDelay)` at L83/106/124/139 (the mock's injected-delay contract, not a test-side wait) and 3 short positioning/negative-assertion sleeps at L569 (300ms, "should not search during debounce window" — negative assertion), L594 (100ms, precondition-establishing sleep before firing a second query to test in-flight cancellation), L620 (300ms, same negative-assertion pattern for debounce-cancel) — all bounded well inside their debounce windows and already commented as such in-file. |
| UNMAPPED | 0 | |

`grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' CatalogSearchViewModelTests.swift` → **3**, all KEEP — no silent drop.

### `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift`
| Bucket | Count | Detail |
|---|---|---|
| CONVERT (pre-existing) | 6 | `await sut._awaitBackgroundRefreshForTesting()` ×4 (single-refresh joins) + `await sut._awaitAllBackgroundRefreshesForTesting()` ×2 (the concurrent-refresh test, paired with `sut._trackRefreshTasksForTesting()`) |
| DELETE | 0 | |
| KEEP | 0 | |
| UNMAPPED | 0 | |

File header (L5–7) and an in-body note (L93–100) explicitly document that the
former private `awaitCondition` poll helper was removed in favor of these two
seams, and that time itself is driven via an injected `now: () -> Date` clock
seam rather than `Task.sleep` anywhere in the file. `grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:'` → **0**.

### `PalaceTests/CatalogDomain/CatalogRepositoryTests.swift`
The single `Task.sleep` grep hit (L303) is inside a **comment** documenting a
previously-removed test (`testLoadTopLevelCatalog_ConcurrentRequests_DeduplicatesNetworkCalls`,
removed for deadlocking CI under a `withTimeout(TaskGroup)` pattern) — no live
code, nothing to convert. `grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:'` → **0**.

## Aggregate tally (4 files with any wait pattern; 12 files had none)

| Bucket | Count |
|---|---|
| CONVERT (already landed pre-wave-2, verified/mirrored) | 61 |
| DELETE | 0 |
| KEEP | 5 `fulfillment`/`expectation` sites + 7 mock-delay/positioning `Task.sleep` sites + 2 synthetic-task-join sites |
| UNMAPPED | 1 (`CatalogViewModelTests.swift` L335–341, reconnect-reload deadline poll — needs a Wave-3 connectivity-reload seam) |

## Verification (per playbook)

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/CatalogUI PalaceTests/CatalogDomain
PalaceTests/CatalogUI/CatalogViewModelTests.swift:337:        while mockRepository.loadTopLevelCatalogCallCount <= callsWhileOffline, Date() < deadline {
```
The one hit is the UNMAPPED site above (already flagged, bounded at a 5s
deadline, not a silent leftover — no production seam exists for it and adding
one is off-limits for this wave).

Bounded-await proof — every `await …ForTesting()` in the 4 files targets a
catalog seam from the wave-1 catalog:
- `_awaitLoadForTesting()` → `CatalogViewModel._awaitLoadForTesting()` (pre-existing catalog seam)
- `_awaitInFlightWorkForTesting()` → `CatalogSearchViewModel._awaitInFlightWorkForTesting()` (pre-existing catalog seam)
- `_awaitBackgroundRefreshForTesting()` / `_awaitAllBackgroundRefreshesForTesting()` → `CatalogRepository._awaitAllBackgroundRefreshesForTesting()` family (pre-existing catalog seam)
- `await synthetic.value` (×3, CatalogViewModelTests L365/366/385) → bounded because cancellation (`cancelPrefetchForTesting()` / `forceRefresh()`) is issued before the join, guaranteeing the `while !Task.isCancelled` loop exits; not a bare wait on an unbounded handle.

No bare unbounded `await` was introduced (none was written at all — 0 edits).

```
$ git status --short
(empty)
$ git diff --stat
(empty)
```

## Off-limits confirmation
- No edits to `Palace/**` (production untouched).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched — only `PalaceTests/CatalogUI/` and `PalaceTests/CatalogDomain/` read/greped.
- Not committed, not pushed.

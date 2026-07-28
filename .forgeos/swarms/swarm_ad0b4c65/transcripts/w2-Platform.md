# Wave-2 Wall-Clock-Wait Conversion — Module: Platform

Worktree: `swarm_ad0b4c65-w2-platform`
Scope: `PalaceTests/Platform/` only (15 files)

## Result: no code changes required

`git status --porcelain PalaceTests/Platform/` is empty. Every wait occurrence
in scope resolved to **KEEP** or **UNMAPPED** — none map to a CONVERT (the one
in-catalog seam covering this directory, `AppHealthViewModel.awaitLoadForTesting()`,
was **already fully adopted by a prior de-flake sweep** — commit `c04219b0c`,
predating this swarm), and none are bare settle-delay DELETE candidates.

## Scan methodology

1. `ls PalaceTests/Platform/` — 15 files.
2. Broad grep for every wait-shaped construct across the directory:
   `wait(for:|waitForExpectations|fulfillment(of:|Thread.sleep|usleep|asyncAfter|
   Task.sleep|while.*Date()|awaitCondition` — 9 of 15 files matched (40 raw hits).
   The other 6 (`AccessibilityPreferencesTests`, `CrossFormatMappingTests`,
   `OfflineActionTests`, `OfflineQueueCoordinatorTests`, `PerformanceReportTests`,
   `ReadingPositionTests`) contain **zero** wall-clock-wait constructs — no
   action needed, not mentioned further.
3. Confirmed the DELETE-bucket patterns (`Thread\.sleep|usleep|asyncAfter.*fulfill|
   while.*Date\(\).*<`) are absent directory-wide (`grep -rnE` → exit 1, no output).
4. Checked every class touched by a wait for an existing `*ForTesting()` seam:
   `grep -n "ForTesting" Palace/Platform/*.swift Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/*.swift`
   → only `AppHealthViewModel.awaitLoadForTesting()` exists. Confirmed via
   `git log --oneline -- PalaceTests/Platform/AppHealthViewModelTests.swift` that
   this file was already converted in `c04219b0c` ("full de-flake sweep") —
   all 5 `loadData()` tests already call `await viewModel.awaitLoadForTesting()`
   with no residual `Task.sleep`/expectation wait around that path.
5. Per the dispatch note, confirmed `OfflineQueueService`, `AppLaunchTracker`,
   `PositionSyncService` have **no** `*ForTesting()` seam in production
   (grep above) — matches the orchestrator's statement that these are
   not-yet-built Wave-2 candidates. Did not add one (production is off-limits).
6. For `AppLaunchTracker`, found it already carries a **different**,
   pre-existing seam not listed in the Wave-2 catalog table:
   `awaitPendingMetricsReport()` (added same commit, `c04219b0c`), used
   correctly in `AppLaunchTrackerTests.swift` and `AppLaunchTrackerExtendedTests.swift`
   at the one place a fire-and-forget task actually needs joining (the
   `.catalogLoaded` → `reportLaunchMetrics()` detached task). No further
   conversion needed there either — already done pre-swarm.

## Why the remaining `Task.sleep` calls are KEEP, not CONVERT/DELETE

Read `AppLaunchTracker.swift`, `PositionSyncService.swift` call sites, and
`PerformanceMonitor` usage in context. The remaining `Task.sleep(nanoseconds:)`
calls in `AppLaunchTrackerTests`, `AppLaunchTrackerExtendedTests`,
`AppLaunchTrackerWiringTests`, `PositionSyncServiceTests`, and
`PerformanceMonitorTests` are **not** waits on a fire-and-forget async
operation's completion — they exist to put real, measurable wall-clock
distance between two directly-awaited synchronous-actor calls so a later
assertion on an actual elapsed `TimeInterval` (`timeBetween`, `timeToInteractive`,
`timeToFirstFrame`, `metric.duration`) or timestamp ordering
(`latestPositionAnyFormat`) is non-zero/well-ordered:

- `recordMilestone(_:)` (actor method) and `recordPosition(_:)` (actor method)
  complete fully before the `await` returns — there is no detached task left
  running afterward for the *milestone-spacing* sleeps to wait on (the one
  actual fire-and-forget op, `reportLaunchMetrics()`, already has its own seam
  and is already joined via `awaitPendingMetricsReport()` in the two files that
  assert on it).
- Removing these sleeps doesn't remove a race, it makes the assertion
  (`XCTAssertGreaterThan(tti ?? 0, 0.02)`, `XCTAssertGreaterThan(secondTimestamp, firstTimestamp)`)
  mathematically unable to pass — this is the opposite of the flake pattern
  the playbook targets (a too-short deadline racing an async op); a `>` floor
  after `Task.sleep` can only be pushed further true by CI slowness, never
  false, so there's no oversubscription-flake exposure to fix.
- No seam could sensibly replace these even if one existed — there is nothing
  to "join," since nothing is pending; the elapsed time itself is the value
  under test. Converting would require injecting a fake/controllable clock
  into `AppLaunchTracker`/`PositionSyncService`/`PerformanceMonitor`, which is
  a production change and out of scope (`AppLaunchTracker`/`PositionSyncService`
  are explicitly the not-yet-seamed classes per the dispatch note; `PerformanceMonitor`
  isn't in the catalog at all).

These fall under the same "intrinsically time-based" KEEP rationale as the
playbook's negative-assertion example, just for a positive-duration assertion
instead of an absence assertion.

## Why the `fulfillment(of:...)` Combine-publisher waits are KEEP

`PerformanceMonitorTests.testMetricPublisherEmits`,
`AccessibilityServiceTests.testPreferencesPublisher`,
`PositionSyncServiceTests.testPositionRecordedEventPublished` /
`testSyncAvailableEventPublished`, `OfflineQueueServiceTests.testStatusPublisherEmits` /
`testActionPublisherEmits`, and `AppHealthViewModelTests.testOfflineQueueStatusUpdates`
all follow one shape: an injected Combine sink on the class's own publisher,
`.receive(on: DispatchQueue.main)`, fulfilled the instant the publisher's
`.send()` — which already happened synchronously inside the immediately-preceding
`await service.foo(...)` actor call — gets its one main-queue hop. This is not a
wall-clock deadline poll (nothing is racing a fixed budget against unknown
completion time); it's a real event fired deterministically off a call that has
already returned. `AppHealthViewModelTests.testOfflineQueueStatusUpdates` (line
154) is the pre-existing example of this exact shape already accepted in this
same file by the prior de-flake sweep — the other 6 instances mirror it. None
of `PerformanceMonitor`, `AccessibilityService`, `OfflineQueueService`,
`PositionSyncService` have a catalog seam for this, so nothing to CONVERT onto;
`timeout: 2.0`/`5.0` here is a safety net, not a deliberate settle delay, so
nothing to DELETE either.

## Why the OfflineQueueService `Task.sleep` waits are UNMAPPED

`OfflineQueueServiceTests` (7 occurrences) and `OfflineQueueServiceExtendedTests`
(5 occurrences) sleep after `enqueue`/`networkStatusChanged`/`retry` calls to
let `OfflineQueueService`'s internal fire-and-forget retry/backoff `Task { … }`
(confirmed at `Palace/Platform/OfflineQueueService.swift:187`, inside
`processQueue()`) finish before asserting queue state. This is exactly the
flake-prone pattern the playbook targets (a fixed-duration guess racing an
unbounded background task under CI oversubscription) — but `OfflineQueueService`
has **no** `*ForTesting()` seam (confirmed above), and it is explicitly named
by the orchestrator as a not-yet-built Wave-2 candidate. Per instructions, left
these as-is rather than inventing an unbounded `await` or editing production;
listed below for Wave-3 seam consideration (an `_awaitQueueDrainForTesting()`-shaped
join over the retry/backoff task, mirroring `MyBooksDownloadCenter`'s
grow-until-stable pattern, would resolve all 12 in one seam).

## Per-file tallies

| File | wait-shaped hits | CONVERT | DELETE | KEEP | UNMAPPED |
|---|---|---|---|---|---|
| `AppHealthViewModelTests.swift` | 1 | 0 | 0 | 1 | 0 |
| `AppLaunchTrackerTests.swift` | 8 | 0 | 0 | 8 | 0 |
| `AppLaunchTrackerExtendedTests.swift` | 7 | 0 | 0 | 7 | 0 |
| `AppLaunchTrackerWiringTests.swift` | 3 | 0 | 0 | 3 | 0 |
| `PerformanceMonitorTests.swift` | 2 | 0 | 0 | 2 | 0 |
| `AccessibilityServiceTests.swift` | 1 | 0 | 0 | 1 | 0 |
| `PositionSyncServiceTests.swift` | 4 | 0 | 0 | 4 | 0 |
| `OfflineQueueServiceTests.swift` | 9 | 0 | 0 | 2 | 7 |
| `OfflineQueueServiceExtendedTests.swift` | 5 | 0 | 0 | 0 | 5 |
| (5 other files: `AccessibilityPreferencesTests`, `CrossFormatMappingTests`, `OfflineActionTests`, `OfflineQueueCoordinatorTests`, `PerformanceReportTests`, `ReadingPositionTests` — 6 files, zero hits) | 0 | 0 | 0 | 0 | 0 |
| **Total** | **40** | **0** | **0** | **28** | **12** |

`grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:'` before → after
(unchanged, no conversions made):
- `AppHealthViewModelTests.swift`: 1 → 1
- `PerformanceMonitorTests.swift`: 1 → 1
- `AccessibilityServiceTests.swift`: 1 → 1
- `PositionSyncServiceTests.swift`: 2 → 2
- `OfflineQueueServiceTests.swift`: 2 → 2
- (other 4 in-scope files use `Task.sleep` only, 0 `fulfillment`/`wait(for:)` hits, unchanged)

Remainder (40 total wait-shaped hits) == KEEP (28) + UNMAPPED (12). No silent drop.

## KEEP list (28)

**Combine-publisher event-driven `fulfillment(of:)` (7)** — real emission tied
to a preceding completed `await`, main-hop safety-net timeout, no seam exists:
- `AppHealthViewModelTests.testOfflineQueueStatusUpdates` (pre-existing, prior sweep)
- `PerformanceMonitorTests.testMetricPublisherEmits`
- `AccessibilityServiceTests.testPreferencesPublisher`
- `PositionSyncServiceTests.testPositionRecordedEventPublished`
- `PositionSyncServiceTests.testSyncAvailableEventPublished`
- `OfflineQueueServiceTests.testStatusPublisherEmits`
- `OfflineQueueServiceTests.testActionPublisherEmits`

**Timing-measurement `Task.sleep` (21)** — real elapsed time is the value
under test, not a settle delay for pending async work; no seam is applicable:
- `AppLaunchTrackerTests.swift`: `testRecordAllMilestones` (×3), `testTimeBetweenMilestones`,
  `testTimeToInteractive`, `testTimeToFirstFrame`, `testCatalogLoadedReportsToMonitor` (×2)
- `AppLaunchTrackerExtendedTests.swift`: `testAllMilestones_RecordedInChronologicalOrder` (×3),
  `testTimeToInteractive_RequiresProcessStartAndCatalogLoaded`,
  `testDuplicateMilestone_OverwritesTimestamp`, `testWarmLaunch_ReportsWithWarmType` (×2)
- `AppLaunchTrackerWiringTests.swift`: `testLaunchTracker_recordsMilestones_computesTimeToInteractive` (×3)
- `PositionSyncServiceTests.swift`: `testLatestPositionAnyFormat`, `testNoSyncOfferWhenCurrentFormatIsMoreRecent`
- `PerformanceMonitorTests.swift`: `testStartAndEndTiming`

## UNMAPPED list (12)

All in `OfflineQueueService` (no catalog seam; class explicitly flagged
not-yet-built by the orchestrator). Fire-and-forget wait on the internal
retry/backoff `Task` inside `processQueue()`:
- `OfflineQueueServiceTests.testProcessQueueSuccess`
- `OfflineQueueServiceTests.testProcessQueueFIFOOrder`
- `OfflineQueueServiceTests.testRetryFailedAction`
- `OfflineQueueServiceTests.testMaxRetriesExceeded` (×2 sleeps)
- `OfflineQueueServiceTests.testClearFailed`
- `OfflineQueueServiceTests.testNetworkAvailableTriggersProcessing`
- `OfflineQueueServiceExtendedTests.testMaxRetriesReached_ActionMarkedAsFailed`
- `OfflineQueueServiceExtendedTests.testProcessQueue_FIFO_Order`
- `OfflineQueueServiceExtendedTests.testClearFailed_RemovesOnlyFailedActions`
- `OfflineQueueServiceExtendedTests.testRetry_MovesFailedToPending` (×2 sleeps)

Recommend a Wave-3 `OfflineQueueService._awaitQueueDrainForTesting()` seam
(grow-until-stable join over the retry/backoff task handle, mirroring
`MyBooksDownloadCenter._awaitDownloadDispatchForTesting()`) to resolve all 12
in one seam addition.

## Bounded-await proof

No `await …ForTesting()` calls or continuations were added by this pass — the
one seam already covering this directory (`AppHealthViewModel.awaitLoadForTesting()`)
and the one adjacent pre-existing seam (`AppLaunchTracker.awaitPendingMetricsReport()`)
were both already fully adopted by a prior commit (`c04219b0c`), before this
swarm dispatched. No test method signatures were changed. No bare
`await someTask.value` on a raw handle exists anywhere in scope.

## Verification commands run

```bash
cd PalaceTests/Platform

# directory listing
ls .

# broad wait-shaped scan
grep -rnE 'wait\(for:|waitForExpectations|fulfillment\(of:|Thread\.sleep|usleep|asyncAfter|while.*Date\(\)|Task\.sleep|awaitCondition' .

# DELETE-bucket patterns — confirmed absent directory-wide
grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' .   # exit 1, no output

# seam existence check (production)
grep -n "ForTesting" ../../Palace/Platform/*.swift \
  ../../Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/*.swift
# -> only AppHealthViewModel.awaitLoadForTesting()

# confirm AppHealthViewModelTests already converted pre-swarm
git log --oneline -- AppHealthViewModelTests.swift
# -> c04219b0c fix(test): full de-flake sweep ... (#1319)

# confirm the fire-and-forget task inside OfflineQueueService (UNMAPPED rationale)
grep -n "func enqueue|func processQueue|Task {" ../../Palace/Platform/OfflineQueueService.swift

# working tree confirmation — no edits made
git status --porcelain .   # (empty)
```

## Off-limits compliance

- No edits to `Palace/**` (production untouched).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No edits outside `PalaceTests/Platform/`.
- No unbounded `await` introduced (none introduced at all).
- No commit/push performed.

## Files changed

None.

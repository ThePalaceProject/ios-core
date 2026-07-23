# Wave-2 Conversion Playbook — swarm_ad0b4c65

Every Wave-2 module implementer follows THIS. Your job: convert the wall-clock /
deadline-poll waits in YOUR test directory to deterministic seam-joins, DELETE
the always-bad ones, and LEAVE the legitimate ones. Test files only — you do NOT
edit production (the seams already exist, see catalog).

## THE ONE INVIOLABLE RULE
**Never introduce an unbounded `await`.** A bounded `wait(for:[e], timeout: 5)`
replaced by `await handle.value` on a handle that may never resume is a
REGRESSION worse than the flake. Every `await` you write in a converted test MUST
target one of the enumerated seams below (each bounded by a barrier drain or a
grow-until-stable Task join), OR a `withCheckedContinuation` you resume from a
real callback. If a wait does NOT map to an enumerated seam, do NOT invent one —
leave it as-is and record it in your transcript's `UNMAPPED` list for the
orchestrator. When in doubt, KEEP + flag; never guess.

## Seam catalog (Wave-1, already in the tree at this branch)
| Seam | Await from a test as | Bounded because |
|---|---|---|
| `BookRegistryStore._awaitPendingWritesForTesting()` | `await store._awaitPendingWritesForTesting()` | trailing barrier on a concurrent queue always drains |
| `TPPBookRegistry._awaitPendingWritesForTesting()` | `await registry._awaitPendingWritesForTesting()` | forwards to S1 + one main hop |
| `TPPNetworkExecutor._awaitInFlightForTesting()` | `await executor._awaitInFlightForTesting()` | grow-until-stable join over completion Tasks |
| `MyBooksDownloadCenter._awaitDownloadDispatchForTesting()` | `await center._awaitDownloadDispatchForTesting()` | grow-until-stable join over all spawned Tasks |
| `DownloadProgressReporter(throttleInterval:)` | construct with `throttleInterval: 0` in tests | removes the 0.5s throttle deterministically |
| **Pre-existing** (already used elsewhere — mirror those call sites): `AccountsManager._awaitAllCrawlTasksForTesting`, `CatalogRepository._awaitAllBackgroundRefreshesForTesting`, `TokenRefreshInterceptor._awaitAuthDispatchForTesting`, `CatalogViewModel._awaitLoadForTesting`, `CatalogSearchViewModel._awaitInFlightWorkForTesting`, `AudiobookBookmarkBusinessLogic._awaitPositionWriteForTesting`, `NowPlayingCoordinator._awaitPendingUpdateForTesting`, `AppHealthViewModel.awaitLoadForTesting` | | |

The `drainMainQueue` / `drainMainQueueAsync` / `awaitCondition(Async)` helpers in
`PalaceTests/XCTestCase+drainMainQueue.swift` are BOUNDED PRIMITIVES — you MAY
use `await drainMainQueueAsync()` to flush a single main-hop after a seam join.
Do NOT edit that file (OFF-LIMITS to every module).

## Bucket protocol — for each wait occurrence in your test dir
1. **CONVERT** — a `wait(for:)`/`waitForExpectations`/`fulfillment(of:)`/
   `awaitCondition` that is waiting on fire-and-forget async whose owning
   production class has a seam in the catalog → replace the expectation+wait with
   `await <seam>()` then assert synchronously. Remove the now-dead
   `XCTestExpectation` and its `.fulfill()`. Make the test method `async` if not
   already.
   - If the class is `@MainActor`, the test is already on the main actor;
     `await seam()` is fine.
   - After the join, state is settled — assert directly, no re-poll.
2. **DELETE** — `Thread.sleep`, `usleep`, `asyncAfter { …fulfill() }` used purely
   as a settle delay, `Task.sleep`-as-delay, hand-rolled `while Date() < deadline`.
   Remove and assert deterministically (usually a seam join replaces the intent).
3. **KEEP** (leave byte-for-byte, list in transcript `KEPT`):
   - Expectations fulfilled by a DIRECT synchronous injected callback (no async hop, no CPU race).
   - Negative "nothing fired" assertions with a short deliberate window (`timeout: 0.3` asserting ABSENCE) — these are intrinsically time-based.
   - Mock schedulers / injected-clock/delay simulations (the mock's contract).
   - Any wait on a 3rd-party completion (audiobook toolkit / LCP / Adobe DRM) with no production seam → KEEP or bridge with an IN-TEST `withCheckedContinuation` resumed from the completion (no production change).
4. **UNMAPPED** (record, do NOT convert): a fire-and-forget wait whose class has NO
   catalog seam. Leave as-is; list it so the orchestrator can decide (maybe a
   Wave-3 seam). Do NOT invent an unbounded await.

## Verification (paste in your transcript before reporting done)
- `grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' <each changed file>` — report the before→after count; the remainder must equal your KEPT+UNMAPPED count (never a silent drop).
- `grep -nE 'Thread.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' <your test dir>` → empty (all DELETEd).
- **Bounded-await proof:** for every `await …ForTesting()` / continuation you added, cite which catalog seam it targets. NO bare `await someTask.value` on a raw handle.
- Do NOT edit production `Palace/**` or `PalaceTests/XCTestCase+drainMainQueue.swift` or any other module's test dir.

## Output
Do NOT commit/push. Leave converted files in your worktree. Write your transcript
to the orchestrator path given in your dispatch prompt with: files changed,
per-file before→after wait counts, the CONVERT/DELETE/KEPT/UNMAPPED tallies, and
the bounded-await citations.

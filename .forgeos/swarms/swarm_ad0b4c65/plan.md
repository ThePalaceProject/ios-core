# Swarm `swarm_ad0b4c65` — Eliminate wall-clock waits from PalaceTests

## Goal
Replace every wall-clock/deadline-poll wait in the test suite (and the trivial
production fire-and-forget dispatches that force them) with **deterministic,
XCTest-gated Task-join seams**. Success = a suite that is *more* stable, not
merely free of `wait()` tokens. **Anti-goal:** replacing a bounded
`wait(for:timeout:)` with an unbounded `await handle` that can hang forever.

## Inventory (exact grep counts, 662 test files)
| class | count | |
|---|---|---|
| `wait(for:` | 396 | CONVERT |
| `waitForExpectations` | 146 | CONVERT |
| `fulfillment(of:` | 133 | CONVERT |
| `Task.sleep` | 124 | mixed DELETE/KEEP |
| `awaitCondition*` | 62 | mostly CONVERT |
| `asyncAfter` (test) | 28 | mixed |
| `Thread.sleep` | 2 | DELETE |

Wait-token total **675**; total delay surface ≈ **887**. Production
`global().async` sites: 25; `delegateQueue: nil`: 1.

## Buckets
- **DELETE (~55–75):** `Thread.sleep`, `asyncAfter{ .fulfill() }`, hand-rolled
  `while Date() < deadline` polls, `Task.sleep`-as-settle. Remove; assert deterministically.
- **CONVERT (~550–620) — the load-bearing bucket:** fixed-timeout waits on
  fire-and-forget async. Collapse to a **finite production-seam set** (below) +
  mechanical call-site rewrites.
- **KEEP/FLAG (~90–120):** the `drainMainQueue`/`awaitCondition` primitives
  themselves, expectations fulfilled by a direct synchronous callback, mock
  schedulers/injected clocks, negative "nothing fired" windows, 3rd-party
  completion boundaries.

## The seam set (the key insight — 675 sites → 12 new seams)
Canonical gate quoted in every retaining seam:
```swift
private static let _isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
```
**Existing (wave 0, reference):** AccountsManager `_awaitAllCrawlTasksForTesting`,
CatalogRepository `_awaitAllBackgroundRefreshesForTesting`, TokenRefreshInterceptor
`_awaitAuthDispatchForTesting`, CatalogViewModel, CatalogSearchViewModel,
AudiobookBookmarkBusinessLogic, NowPlayingCoordinator, AppHealthViewModel,
TPPNetworkExecutor token-refresh infra.

**Wave 1 (shared infra, high fan-in):**
- **S1 `BookRegistryStore._awaitPendingWritesForTesting()`** — trailing barrier
  drain (FIFO barrier ⇒ all prior writes done; bounded by definition). Fan-in:
  Book, BookRegistry, MyBooks, Holds, BookStateManagement, Sync, Bookmarks.
- **S2 `TPPBookRegistry._awaitPendingWritesForTesting()`** — forwards to S1 +
  drains main-broadcast hops; does NOT await the intrinsic switch-back debounce.
- **S3 `TPPNetworkExecutor/Responder._awaitInFlightForTesting()`** — join the
  responder completion tasks fired off `delegateQueue`. critical_path.
- **S4 `MyBooksDownloadCenter._awaitDownloadDispatchForTesting()`** — generalize
  its fire-and-forget `Task {}`s into an XCTest-gated array + grow-until-stable
  join (mirror `_awaitAuthDispatchForTesting`). critical_path.
- **S11 `DownloadProgressPublisher`** — inject the +0.5s throttle interval (0 in
  tests); do NOT delete the throttle.

**Wave 2 (module-local):** S5 BookReturnService, S6 BookDetailViewModel,
S7 HoldsViewModel (inject scheduler or join refresh Task), S8 OfflineQueueService,
S9 AppLaunchTracker, S10 PositionSyncService, S12 TPPAccessibilityAnnouncementCenter
(inject debounce scheduler).

**Cannot get a clean seam → documented fallback (KEEP or in-test continuation
bridge, no production change):** audiobook vendor adapters (PalaceAudiobookToolkit /
LCPAudiobooks / Adobe DRM — 3rd-party completion handlers), SignInLogic idle
sign-out (inject the idle clock; do not Task-join a Timer).

## Module → wave partition (16 contracts, overlap-free)
- **Wave 1 (3 infra contracts):** BookRegistryInfra (S1,S2), NetworkInfra (S3),
  DownloadCenterInfra (S4,S11). Prod-only; no test files change yet.
- **Wave 2 (12 module contracts, parallel):** Book, BookRegistry, MyBooks,
  Network, SignInLogic, Accounts, Platform, Accessibility, Audiobooks, Holds,
  Catalog, Bookmarks — each converts its own test dir's call sites against the
  wave-1 seams. Partition is by test-dir, so no two agents touch the same file.
- **Wave 3 (1 contract):** MiscSmall spillover.

## Verification (CI-gated — waves serialize on a buildable worktree)
Within a wave, module contracts run in parallel subagents; the wave is verified
by `scripts/xcode-test-optimized.sh` (3 iterations + retry) on the orchestrator
worktree / CI. Per-contract grep assertions:
- `grep -c 'wait(for:' <file>` drops to the documented KEEP-count (not always 0).
- every new `_await…ForTesting` sits behind the `XCTestConfigurationFilePath` gate.
- **no converted test has an unbounded `await`** — each `await …ForTesting()`
  targets an enumerated seam whose bound is a barrier drain (S1) or a
  grow-until-stable join (S4). Reviewer grep-asserts this per site.
- zero residual `Thread.sleep`/`usleep`/`asyncAfter{ .fulfill() }` in scope.

## Top risks
1. **Unbounded-await regression** (the explicit anti-goal) — mitigated by the
   "every await targets an enumerated bounded seam" reviewer grep.
2. **Critical-path modules** (Network, MyBooks/Download*, SignInLogic,
   BookRegistryInfra, BookReturnService, Audiobooks) — route through forge-review
   + contract-snapshot tests before promotion.
3. **Intrinsic timers misclassified as deletable** (switch-back debounce, +0.5s
   throttle, announcement debounce, migration +3.0, backoff) — seams JOIN or
   INJECT-clock, never delete.
4. **3rd-party boundary** — continuation-bridge-in-test or documented KEEP.
5. **Scale honesty** — ~550–620 CONVERT sites, 3 waves, 16 contracts. Not one-shot.

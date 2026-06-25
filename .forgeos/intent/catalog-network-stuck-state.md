---
name: catalog-network-stuck-state
created: 2026-06-25
author: claude-opus-4-8
---

## Summary

Tester report (via Maurice/Courtney, A1QA): the catalog hangs going Fiction →
"All Fiction" (a large paginated lane-more feed), and afterward the MAIN catalog
hangs even after switching libraries, until the app is force-quit/restarted. QA
confirmed switching to wifi + restart clears it — i.e. a networking root cause.

Four compounding weaknesses on the catalog/lane network path, fixed here
(develop-only; the RC `release/3.2.0` branch is intentionally untouched):

1. `URLSessionNetworkClient.send` discarded the `URLSessionTask` returned by the
   executor (`_ = executor.GET(...)`) and installed no cancellation handler, so a
   cancelled/timed-out fetch kept its connection-pool slot until the shared
   session's resource timeout. Because most Palace libraries share one
   Circulation Manager host, a few stuck requests exhausted that host's pool and
   starved every library's feed fetches — the persistent "stuck until
   wifi-switch/restart" symptom. (Root cause.)
2. `CatalogLaneMoreViewModel` fetches through `DefaultCatalogAPI` directly and had
   no app-level timeout (unlike `CatalogRepository`). A wedged lane-more fetch
   could pin `InflightFeedFetches`' dedup entry for that URL forever, hanging
   every later fetch of it.
3. Detached cover-prefetch tasks in `CatalogViewModel.load()` were untracked and
   uncancellable — they kept firing cover downloads for a feed the patron had
   already left, multiplying load on the network.
4. The shared `TPPNetworkExecutor` token-refresh coordinator had no recovery if a
   refresh ever wedged with `isRefreshing == true`: every later token-authed
   request coalesces behind it and hangs until app restart.

## Claims

- `URLSessionNetworkClient.send` now wraps the request in `withTaskCancellationHandler`, captures the executor's returned `URLSessionTask` in a thread-safe `CancellableTaskBox`, and cancels it when the awaiting Swift task is cancelled — freeing the shared connection-pool slot promptly instead of at the resource timeout
- `send` short-circuits with `CancellationError` if the awaiting task is already cancelled before the request starts (never opens a leaked connection)
- `InflightFeedFetches.run` gains a `timeout` parameter (default 30s) and a `withFeedTimeout` race that, on timeout, throws `NSURLErrorTimedOut`, cancels the in-flight work, and frees the dedup entry so the next fetch of that URL runs fresh
- `CatalogViewModel` tracks its detached cover-prefetch tasks in `prefetchTasks` and a `cancelPrefetch()` cancels + clears them; `load()` calls `cancelPrefetch()` on every reload and `deinit` cancels them on teardown
- the below-fold prefetch loop and inactive-entry-point preload check `Task.isCancelled` so cancellation stops them mid-flight
- `TokenRefreshCoordinator` gains a monotonic `refreshGeneration` (bumped on every slot claim) and `forceReleaseIfStuck(generation:)` that releases the slot + returns the stranded retry queue only when the same generation still holds it
- `TPPNetworkExecutor.refreshTokenAndResume` arms a generation-scoped watchdog (`tokenRefreshWatchdogSeconds`, default 75s) that force-releases a wedged refresh and fails its stranded queue, never disturbing a completed or newer refresh
- adds `InflightFeedFetchesTimeoutTests` (timeout fires, dedup entry freed, fast path unaffected, concurrent dedup preserved)
- adds `TokenRefreshWatchdogTests` (force-release + stranded queue, completed-refresh untouched, stale-generation safety, idempotency, single-flight)
- adds `URLSessionNetworkClientCancellationTests` (cancelling the send Task frees a hanging request promptly via a hanging URLProtocol)
- adds `CatalogViewModel` prefetch cancellation tests (cancelPrefetch cancels + clears; reload cancels prior prefetch)
- adds `#if DEBUG` test seams on `CatalogViewModel` (prefetch task count/append/cancel) and `TPPNetworkExecutor` (coordinator claim/generation/force-release/refreshing passthroughs)
- switches `DefaultCatalogAPITests` to `@testable import PalaceCatalog` so the internal `InflightFeedFetches` is reachable

## Anti-claims

- does NOT touch the RC `release/3.2.0` branch — this is develop-only, per the product owner's scoping
- does NOT change the cover-image download pipeline / `TPPBookCoverRegistry` (its own session); only the catalog-side prefetch *tracking/cancellation* is added
- does NOT reduce `httpMaximumConnectionsPerHost` or give images a separate connection pool — deferred unless the cancellation + timeout + watchdog prove insufficient (earn-complexity)
- does NOT alter token-refresh success/failure logic, credential handling, or the single-flight claim semantics — the watchdog is purely an additive recovery escape hatch keyed on a generation, and never fires on a completed or newer refresh
- does NOT add new user-facing UI/error surfaces for the lane-more timeout beyond the view model's existing `error` state
- does NOT change the default feed-fetch behavior on the happy path — the timeout only changes outcomes for fetches that exceed 30s

## Files in scope

Production:
- `Palace/Network/Core/URLSessionNetworkClient.swift` (cancellation propagation + `CancellableTaskBox`)
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogAPI.swift` (`InflightFeedFetches` timeout)
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` (prefetch tracking/cancellation + test seams)
- `Palace/Network/TPPNetworkExecutor.swift` (token-refresh watchdog + coordinator generation + test seams)

Tests:
- `PalaceTests/Network/DefaultCatalogAPITests.swift` (`InflightFeedFetchesTimeoutTests`; `@testable` import switch)
- `PalaceTests/Network/TokenRefreshTests.swift` (`TokenRefreshWatchdogTests`)
- `PalaceTests/Network/NetworkClientTests.swift` (`URLSessionNetworkClientCancellationTests`)
- `PalaceTests/CatalogUI/CatalogViewModelTests.swift` (prefetch cancellation tests)

# Module CatalogUI — library-switch SWR + de-triple-fire (standard)

## Goal
A→B→A library switch stops doing 3 full fetches. `handleAccountChange` serves the
new library's account-scoped cache instantly (SWR) with a background refresh; only
pull-to-refresh invalidates. Remove the switch-time triple-fire and manual auth-doc
load. Stop per-render CatalogRepository construction. Wire the `.catalogLoaded`
launch milestone.

## Changes
- `CatalogViewModel.swift`
  - NEW `private func reload(invalidatingCache: Bool) async` — extracts the body of
    current `refresh()`; when false, skips invalidate and relies on SWR.
  - `handleAccountChange()` (:461) → `reload(invalidatingCache: false)`.
  - `refresh()` (:317, pull-to-refresh) → `reload(invalidatingCache: true)`.
  - Invalidate via `repository.invalidateCache(for:)` (PROTOCOL — verified
    `CatalogRepository.swift:14`). DELETE the `(repository as? CatalogRepository)?`
    cast at :319 (forceRefresh() :308 is precedent).
  - `load()` records `.catalogLoaded` via `AppLaunchTracker.shared.recordMilestone`.
- `CatalogView.swift`
  - `switchToAccount` (:376-386): DELETE redundant `.TPPCurrentAccountDidChange`
    post (:384) + direct `viewModel.refresh()` (:385). Setter already posts
    (AccountsManager :632) → onReceive (:58-59) → handleAccountChange.
  - DELETE `account.loadAuthenticationDocument { _ in }` (:382); setter's
    `driveCurrentAccountAuthDocIfNeeded()` is single-flighted and covers it.
- A5: `CatalogLaneMoreView.swift:258-265`, `CatalogSearchView.swift:63-66`,
  `CatalogLaneMoreViewModel.swift:84-88` accept an injected repo/API; `AppContainer`
  hangs ONE `CatalogRepository(DefaultCatalogAPI(...))` and injects it;
  `checkStaleCacheStatus` becomes a launch-time call, not a per-init side effect.

## Test contracts
1. `testHandleAccountChange_servesCache_doesNotInvalidate` — assert
   `CatalogRepositoryMock.invalidateCacheCallCount == 0` and state → loaded.
2. `testRefresh_pullToRefresh_invalidatesOnce` — assert `invalidateCacheCallCount == 1`.
3. `testSwitchBackAndForth_ABA_servesCacheNotThreeFetches` — multi-step through the
   production seam; A's fetch-count does not grow on return.

## Files OFF-LIMITS
AccountsManager.swift (Accounts-Startup + CP-D1/D3); AppContainer.production()
account-hydration region (CP-D1); TPPBookCoverRegistry.swift (Covers); Network/*.

## Verification criteria (grep-able)
1. `grep -c 'as? CatalogRepository' Palace/CatalogUI/ViewModels/CatalogViewModel.swift` → 0
2. `grep -c 'func reload(invalidatingCache' …CatalogViewModel.swift` → 1;
   `reload(invalidatingCache: false)` ≥1; `reload(invalidatingCache: true)` ≥1
3. `grep -c 'loadAuthenticationDocument' Palace/CatalogUI/Views/CatalogView.swift` → 0;
   diff removes the `.TPPCurrentAccountDidChange` post + `viewModel.refresh()` in switchToAccount
4. `grep -c 'recordMilestone(.catalogLoaded)' …CatalogViewModel.swift` → ≥1
5. `grep -c 'CatalogViewModel(' PalaceTests/CatalogUI/CatalogViewModelTests.swift` → ≥1
6. `python3 scripts/check-test-name-vs-body.py PalaceTests/CatalogUI/CatalogViewModelTests.swift` → exit 0
7. `scripts/verify-pr.sh --quick` PASS

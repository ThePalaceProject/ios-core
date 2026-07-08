# Intent: Reliability WS-C — Offline-Safe Loans, Renewal & Offline-Queue Wiring

## Claims
- Add `LoanEvictionPolicy` (pure `decide(expiration:now:isOnline:grace:) -> EvictionDecision`) — seam S3.
- Gate `MyBooksViewModel` expired-book eviction through `LoanEvictionPolicy`; inject an `isOnline` provider (new ctor dependency, default = production reachability). Never delete/unregister offline based on a cached `until` alone (INV-2).
- Add `LoanRenewalService` — extracts the OPDS renew (borrow-rel) URL, POSTs it, updates the registry; routes 401 through `AuthErrorClassifier` with `currentAccountHostsProvider` so a foreign-host 401 does NOT mark credentials stale (INV-5).
- Add `OfflineQueueCoordinator` — calls `OfflineQueueService.shared.setExecutor` exactly once; dispatches by `OfflineActionType` to existing public APIs; dedupes by bookID+type (INV-8). Registered once from `AppContainer`.
- `BookReturnService.handleRevokeError`: genuine offline `NSURLError` enqueues an `OfflineAction(.return,...)` instead of dead-ending; does NOT delete local content / unregister until server-confirmed (INV-3). Preserves ordered cleanup contract `setProcessing -> setState -> removeBook -> announce.returnSucceeded`.

## Anti-claims (explicitly NOT doing)
- NOT editing `MyBooksDownloadCenter.swift` (call existing public API only), `BookRegistrySync.swift`, `DownloadStateManager.swift`, `TPPAppDelegate.swift`.
- NOT changing `OfflineQueueService.setExecutor` signature (frozen seam S2).
- NOT changing the BookReturn ordered-cleanup contract or its existing snapshots.
- NOT touching DRM fulfillment paths.

## Files in scope
- NEW `Palace/MyBooks/LoanEvictionPolicy.swift`
- NEW `Palace/MyBooks/LoanRenewalService.swift`
- NEW `Palace/Platform/OfflineQueueCoordinator.swift`
- EDIT `Palace/MyBooks/MyBooks/MyBooksViewModel.swift`
- EDIT `Palace/MyBooks/BookReturnService.swift`
- EDIT `Palace/AppInfrastructure/AppContainer.swift` (single registration call only)
- Tests: `LoanEvictionPolicyTests`, `LoanRenewalServiceTests`, `OfflineQueueCoordinatorTests`, `MyBooksViewModelTests` (+offline case), `BookReturnServiceTests`/`BookReturnServiceContractTests` (+offline-enqueue).

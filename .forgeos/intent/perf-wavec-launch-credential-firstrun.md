# Intent: Wave C — cold-launch hydration, credential caching, first-run decode (swarm_27c181b5, CRITICAL PATH)

## Claims
- **D1 (launch snapshot):** `AccountsManager.preloadAccountsFromDiskCacheSync` hydrates only a SLIM set (current + `settingsAccountIdsList` accounts) synchronously into a separate `slimAccountsByUUID` structure; the full ~1142-account list decodes off-main behind the existing `Account.awaitReady()` gate. `accounts()`/`accountsHaveLoaded` still reflect the FULL list (picker not truncated). New `accounts_catalog_slim_<hash>.json` persistence (off-main, XCTest-gated write).
- **D1 ordering guard:** add `AccountsManager.fetchCompletionMayWriteTerminal(currentState:)` so a superseded/cancelled auth-doc fetch completion cannot overwrite a deliberate `.detailsEvicted(.libraryDeselected)` marker with `.detailsFailed` (which stranded `awaitReady()` consumers).
- **D1 F4/F5:** reuse the slim `Account` instance on slim→full materialization so an in-flight auth-doc fetch isn't stranded; refresh the slim snapshot on the `currentAccount` setter and fall through to full sync hydrate when the slim set lacks the current account.
- **D2 (credential snapshot):** remove the per-request `invalidateAllKeychainCaches()` from `TPPUserAccount.credentialSnapshot()`; add event-driven invalidation (`invalidateCredentialCaches()`) on sign-out (`removeAll()`) and account-switch (`AccountsManager.currentAccount.didSet`).
- **D3 (first-run decode):** consolidate the `addLoadingHandler` dedupe to a single guard above the bundled-registry branch; hop the bundled 2.4MB decode off-main (tracked `Task.detached(.utility)`); bump both init crawl QoS arms `.background`→`.utility`.

## Anti-claims (explicitly NOT changed)
- No change to the network cache-clear routing (Wave B, already merged).
- No change to `TPPNetworkResponder` (auth-error decision point).
- D3 does NOT edit the slim/preload path (D1's) or `TPPAppDelegate` (self-hop subsumes the caller).
- No loosening of any state-machine assertion to accept a stuck/failed terminal.

## Files in scope
Palace/Accounts/Library/AccountsManager.swift, Palace/Accounts/User/TPPUserAccount.swift,
Palace/AppInfrastructure/AppContainer.swift, + PalaceTests/Accounts/{AccountsManagerLaunchSnapshotTests,
AccountsManagerFirstRunDecodeTests, CredentialSnapshotInvalidationTests}.swift,
PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift (round-trip additions),
PalaceTests/SignInLogic/TPPCredentialSnapshotCoherenceTests.swift (event-seam update).

## Review
Each contract dual-SoD reviewed (architect + qa). D1 architect BLOCKED on two concurrency
regressions (F4/F5), both fixed + re-approved. See .forgeos/swarms/swarm_27c181b5/ for verdicts.

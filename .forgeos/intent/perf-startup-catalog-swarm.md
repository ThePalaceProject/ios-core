# Intent: startup + library-switch performance program (swarm_27c181b5, Waves A+B)

## Claims
- Split `CatalogViewModel.refresh()` into `reload(invalidatingCache:)`; `handleAccountChange` serves the account-scoped cache (SWR) instead of invalidating, so a library switch no longer refetches a cached feed.
- Remove the redundant `.TPPCurrentAccountDidChange` post + `viewModel.refresh()` + `loadAuthenticationDocument` from `CatalogView.switchToAccount` (the currentAccount setter already drives them).
- Route catalog cache invalidation through the `CatalogRepositoryProtocol` (remove the `as? CatalogRepository` cast).
- Inject a shared `CatalogRepository` via `AppContainer` instead of per-render construction.
- `HostFailureTracker.isTripped` honors `failureThreshold` (was hardcoded `>= 1`); add a reachability-change reset and an account-switch `resetHostFailures()`.
- Small cover cells fetch the thumbnail URL so cell + prefetch coalesce.
- `AccountsManager` reads the registry disk cache once per launch (FileManager existence check, not a full read); replace the O(n²) account carry-over with a `[uuid:Account]` dict.
- Wire `AppLaunchTracker` milestones (`.processStart`/`.didFinishLaunching`/`.firstFrame`/`.catalogLoaded`).
- Move `GeneralCache.clearAllCaches` purge off-main (version gate stays sync); defer the launch audio-session config.
- Route cache-clear hygiene (sign-out, force-reset, TPPAppDelegate, pull-to-refresh) through the network executor's private URLCache instead of `URLCache.shared`; drop `httpShouldUsePipelining`; URLCache memory 20→50MB.

## Anti-claims (explicitly NOT in this change)
- No change to account-object hydration semantics / the launch state machine (that is Wave C / CP-D1, deferred).
- No change to `credentialSnapshot` / keychain read cadence (Wave C / CP-D2, deferred).
- No change to the first-run bundled-decode path (Wave C / CP-D3, deferred).
- `CatalogRepository:206` (PalaceCatalog package) cache-clear left on `URLCache.shared` — documented deferral (needs a `NetworkClient.clearCache()` seam).
- No `TPPNetworkResponder` (auth-error decision point) changes.

## Files in scope
Palace/CatalogUI/**, Palace/Book/Models/TPPBookCoverRegistry.swift,
Palace/Utilities/ImageCache/{ImageLoaderImpl,GeneralCache}.swift,
Palace/Accounts/Library/AccountsManager.swift,
Palace/AppInfrastructure/{AppContainer,TPPAppDelegate,SceneDelegate}.swift,
Palace/Audiobooks/PlaybackBootstrapper.swift, Palace/Platform/AppLaunchTracker.swift,
Palace/Packages/PalaceNetwork/**/TPPCaching.swift,
Palace/Packages/PalaceCatalog/**/CatalogRepository.swift,
Palace/SignInLogic/TPPSignInBusinessLogic+{SignOut,ForceReset}.swift,
Palace/Network/TPPNetworkExecutor.swift, + PalaceTests/** counterparts.

# Module D — Deferred production DI sweep

Module D's contract limits production DI changes to `TPPSettings` and
`RemoteFeatureFlags`. The following test files reference
`UserDefaults.standard` BUT the production class under test reads
`UserDefaults.standard` directly — meaning a clean test-side
`testUserDefaults()` migration would race against the prod reader and
make the test non-deterministic in a different way than today's
pollution.

These files stay on `UserDefaults.standard` for now and are listed in
`PalaceTests/MetaTests/UserDefaultsIsolationLintTests.swift`
whitelist. Lint is warn-only; the next sweep flips it strict after
the listed production classes gain a DI seam.

## Test files deferred (8 total, ~38 UserDefaults.standard sites)

| Test file | Sites | Prod class blocking migration | Notes |
|---|---|---|---|
| `PalaceTests/Accounts/AccountDetailsURLTests.swift` | 5 | `AccountDetails` (Palace/Accounts/Library/AccountDetails.swift) | reads UserDefaults via `uuid` key |
| `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` | 10 | `AccountsManager` | reads `currentAccountIdentifierKey` |
| `PalaceTests/Accounts/AccountsManagerTests.swift` | 7 | `AccountsManager` | reads `currentAccountIdentifierKey`; also has 21 deferred `AppContainer.production()` sites pending Module A's factory |
| `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift` | 2 | `TPPBookmarkDeletionLog` | |
| `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift` | 3 | `CatalogRepository` (Palace/Packages/PalaceCatalog/...) | reads `lastAppLaunchKey` |
| `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift` | 3 | `CatalogRepository` | reads `lastAppLaunchKey` |
| `PalaceTests/CoverageGapTests.swift` | 2 | `AccountDetails` | EULA + sync-permission keys per UUID |
| `PalaceTests/SignInLogic/ForceResetTests.swift` | 9 | `TPPSignInBusinessLogic+ForceReset` | force-reset flag key |

## Production classes that need DI (next sweep)

Each adds a `private let defaults: UserDefaults = .standard` instance
property and accepts it via an initializer arg, mirroring the
`TPPSettings` / `RemoteFeatureFlags` seam D landed in this swarm.

- `Palace/Accounts/Library/AccountDetails.swift`
- `Palace/Accounts/Library/AccountsManager.swift`
- `Palace/Bookmarks/TPPBookmarkDeletionLog.swift` (path TBD by next implementer)
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift`
- `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift` (path TBD)

Blast radius will be larger than D's pair (AccountsManager especially
has many call sites), so each one needs its own scope-deferral audit
before migration.

## AppContainer.production() polluter cleanup (D-owned, A-blocked)

Per contract, Module D owns the `AppContainer.production()` polluter
cleanup in `Accounts/AccountsManagerTests.swift` (21 sites) and
`Settings/DownloadOnlyOnWiFiTests.swift` (4 sites). Both files
currently still call `AppContainer.production()` because Module A's
`TestAppContainerFactory` (the `makeTestAppContainer()` helper) has
not landed yet in this swarm — A's tests file exists at
`PalaceTests/Support/TestAppContainerFactoryTests.swift` but the
implementation is pending.

`DownloadOnlyOnWiFiTests.swift` carries explicit
`TODO(swarm_47883816-A-followup):` comments on the two affected test
methods (`testReachability_isOnWiFi_returnsBool`,
`testReachability_isOnWiFi_consistentWithDetailedStatus`).

`AccountsManagerTests.swift` is added to A's deferred-files list (see
`.forgeos/swarms/swarm_47883816/A-deferred-files.txt`); the swarm
integrator will pick this up after A's factory ships.

Once `makeTestAppContainer()` is callable from these files, swap the
`AppContainer.production()` call sites for
`makeTestAppContainer()` and drop the TODO markers.

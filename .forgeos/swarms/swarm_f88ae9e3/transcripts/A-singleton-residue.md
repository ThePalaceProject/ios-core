# Investigator A Findings — Singleton / Global-State Residue

## Grep counts (raw, contract sets 1-4)

```
TPPUserAccount.shared / .sharedAccount         lines=39   files=9
AccountsManager.shared                          lines=1    files=1   (comment only — singleton already killed)
AccountsManager(...)  test constructions        lines=25   files=11
AccountStateStore.shared                        lines=63   files=16  (mostly reads + _resetAllForTesting calls)
AppContainer.production()                       lines=614  files=85  (240 .accountsManager, 78 .downloadCenter, 66 .bookRegistry, 37 .networkExecutor)
TPPBookRegistry.shared                          lines=6    files=4   (all comments — singleton killed Phase 6.6)
UserDefaults.standard.set/.removeObject         lines=55   files=11
NotificationCenter.default.post                 lines=45   files=13
NotificationCenter.default.addObserver          lines=21   files=15  (all observers verified paired with removeObserver)
```

Reset-API discovery:
- `AccountStateStore._resetAllForTesting()`  — exists, used by 16 files.
- `AccountsManager.deferInitialLoadCatalogsForTesting` (opt-out) — exists at `Palace/Accounts/Library/AccountsManager.swift:170`. **USED BY ONLY 1 TEST FILE** (`AccountsManagerStateMachineWiringTests.swift:43`).
- `AccountsManager._seedAccountForTesting(_:)` — exists at `Palace/Accounts/Library/AccountsManager.swift:400`, used by 4 files via `seedAccountIfNeeded` helper.
- No public reset on `TPPUserAccount` (the singleton-shaped class). `TPPUserAccountMock.resetShared()` exists but only resets the **mock's** shared, NOT the real `TPPUserAccount` cached by `AccountsManager.userAccounts[uuid]`.
- No public reset on `AppContainer._cached` (it's `static let`).

## Summary

- **Total test files scanned:** 529 swift files under `PalaceTests/`.
- **HIGH-severity singleton-residue findings:** 7 (covered below).
- **MED-severity findings:** 5.
- **LOW-severity findings:** ~85 files do read-only access to `AppContainer.production().*` — DI debt signal, not flake driver.
- **Root structural cause:** `AppContainer.production()` returns a single `static let _cached` graph. Its `AccountsManager` was constructed by the **first test process to touch any AppContainer accessor**, so the `deferInitialLoadCatalogsForTesting` flag was `false` at that init point — the background `loadCatalogs()` race is permanently armed for the rest of the suite. Every subsequent test that reads `AppContainer.production().accountsManager` is renting a real, mutating, network-fetching singleton.
- **Confirmation of the `numAccounts=100 → 1150` CI symptom:** `numAccounts` is logged at `Palace/Logging/TPPErrorLogger.swift:801` reading `AppContainer.production().accountsManager.accounts().count`. Background `loadCatalogs()` walks the real Palace registry crawler (`Palace/Accounts/Library/AccountsManager.swift:621`) — paginating until the full catalog (~1150 entries) lands in `accountSets[currentHash]`. Once the early test logs `100` (preload from a partial cache), a later test sees the post-fetch full registry — exactly the 90s drift CI showed.

## HIGH findings (file:line — leakage path)

| # | File:line | Singleton | Why HIGH |
|---|---|---|---|
| H1 | `Palace/AppInfrastructure/AppContainer.swift:223` | `_cached: AppContainer` | `static let _cached` initializes its `AccountsManager()` **without** the test opt-out, so the process-lifetime singleton spawns background `loadCatalogs()`. Drives the `numAccounts` drift exactly seen in CI. |
| H2 | `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift:89` | `AccountsManager()` (no opt-out) | Constructs a fresh `AccountsManager()` per test. Each instance spawns `DispatchQueue.global(.background).async { loadCatalogs }` (`Palace/Accounts/Library/AccountsManager.swift:213`). Background fetcher outlives the test — pollutes `AccountStateStore.shared` and (via the `currentAccount` setter) `UserDefaults.standard["TPPCurrentAccountIdentifier"]`. |
| H3 | `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift:75` | `AccountsManager()` | Same pattern as H2 — no opt-out. tearDown nils the `accountsManager` field but the background closure has captured `self` weakly inside `init` (line 213) and continues executing. |
| H4 | `PalaceTests/Integration/AccountSwitchLifecycleTests.swift:61` | `AccountsManager()` | Same. Worse: this test exercises the account-switch setter which writes through to `UserDefaults.standard.set(...)` for `currentAccountIdentifierKey` (`Palace/Accounts/Library/AccountsManager.swift:363`). Cleanup at line 71-86 doesn't `UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)`. |
| H5 | `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift:45` | `AccountsManager()` | Same pattern as H2. |
| H6 | `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift:49, 247, 273` | `AccountsManager()` | Three sites; lines 247 and 273 construct AccountsManager **inline inside test methods** without a defer cleanup. Each fires the background loadCatalogs spawn. |
| H7 | `PalaceTests/BookRegistry/{TPPBookRegistryAtomicWriteTests.swift:45, TPPBookRegistryLargeCorpusTests.swift:43, TPPBookRegistryMigrationTests.swift:39, TPPBookRegistryDependencyTests.swift:45,63}` | `AccountsManager()` | 5 more raw constructions, all without the opt-out. Each adds a background `loadCatalogs` task to the process. |

## HIGH (real-singleton mutation in tests)

| # | File:line | Singleton mutated | Leak path |
|---|---|---|---|
| H8 | `PalaceTests/ViewModels/AccountDetailViewModelTests.swift:466,496,527,552,581,609,637,929,948,1044,1118` | `TPPUserAccount.sharedAccount(libraryUUID: libraryID)` | Each test calls `account.setBarcode(...)`, `account.setAuthToken(...)`, `account.setAuthState(...)` on the real per-library `TPPUserAccount`. `account.removeAll()` cleanup at lines 480/512/539/568 only runs in the happy path — any `XCTSkip` (e.g. `KeychainAvailability.skipIfUnavailable()` at line 25 or `currentAccountId == nil` guards everywhere) leaves credentials in the real keychain / in-memory account. Each unique `libraryID` permanently grows `AccountsManager.userAccounts[...]` (`Palace/Accounts/Library/AccountsManager.swift:457-465`). |
| H9 | `PalaceTests/Accounts/AccountSwitchCleanupTests.swift:104,107,110,115,118,121,126,129,132,139` | `TPPUserAccount.sharedAccount(libraryUUID: <uuid>)` | **No setUp/tearDown in the class.** `testSharedAccount_RapidSwitching_DoesNotCrash` (line 136-142) allocates 50 distinct UUID accounts in a loop — each call adds a permanent entry to `AccountsManager.userAccounts`. The dictionary grows monotonically across test runs. The `NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)` at line 168 fires through every production observer (see "Cross-cutting: notification fan-out" below). |
| H10 | `PalaceTests/AudiobookTrackerTests.swift:535` | `NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)` | App-lifecycle broadcast. Production services subscribed to `willTerminateNotification` (AudiobookTracker, Crashlytics flush hooks, registry persistence) execute. Any cached `TPPBookRegistry` state gets flushed; any in-flight Combine subscribers receive termination signals. State leaves the test boundary. |
| H11 | `PalaceTests/Chaos/ChaosHarness.swift:196` | `NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)` | Memory-warning broadcast. Production ImageCache eviction, BookCellModelCache flush, any view models that listen for memory pressure all react. Chaos test runs AFTER setUp, but production state is mutated mid-suite. |
| H12 | `PalaceTests/Accounts/AccountsManagerCacheTests.swift:263` + `PalaceTests/Accounts/AccountsManagerTests.swift:165,263,555,593,626,649,650` + `PalaceTests/MyBooks/MyBooksViewModelTests.swift:427,1003,1016,1028,1045,1606` + `PalaceTests/Holds/HoldsViewModelTests.swift:84,107,311,399,424,482,504,528,549,568,580,603,631,659,696,726,750,769` + `PalaceTests/Book/BookDetailViewModelTests.swift:1387,1424,1442` + `PalaceTests/Stats/BadgesViewModelTests.swift:158,174` + `PalaceTests/Integration/AccountSwitchIntegrationTests.swift:90` + `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift:298,354` + `PalaceTests/Accounts/AccountSwitchCleanupTests.swift:168` | `NotificationCenter.default.post(name: .TPP*, ...)` (Palace-domain broadcasts) | Production observers consume these — see "Cross-cutting: notification fan-out" below. The post is the trigger; the residue is whatever side effect those observers commit. Most notable: `.TPPCurrentAccountDidChange` triggers `TPPBookRegistry.accountDidChangeCancellable` at `Palace/Book/Models/TPPBookRegistry.swift:126` AND `BookCellModelCache` at `Palace/MyBooks/MyBooks/BookCell/BookCellModelCache.swift:126`. |
| H13 | `PalaceTests/Audiobook/AudiobookIssueFixTests.swift:262,276,293` | `UserDefaults.standard.set(..., forKey: "TPPMigrationManager.lastLaunchBuild")` | tearDown clears key at line 256 — clean. **However** line 293 writes "1" AFTER asserting `XCTAssertNil`. If a later test in this file runs without tearDown firing first (XCTest runs tearDown after each test, so this is actually OK — promoted to MED). Keeping flagged because the test mutates UserDefaults inside the assertion block, which is fragile to refactor. |

## HIGH (cross-cutting: AppContainer is permanently dirty)

| # | Pattern | Why HIGH |
|---|---|---|
| H14 | All 85 files reading `AppContainer.production().accountsManager` | The first test that touches AppContainer "fixes" the production `AccountsManager` for the process. That single `AccountsManager` instance's background `loadCatalogs()` runs once and never gets cancelled (no production reset hook exists). Every later test reading `AppContainer.production().accountsManager.currentAccount` or `.accounts()` sees whatever state the background fetch has reached **at the moment of that read** — non-deterministic. This is the architectural root of A. |

## MED findings

| # | File:line | Issue |
|---|---|---|
| M1 | `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift:129,197,282,372,477,553,668,713,796,879,1000` | The class flips `deferInitialLoadCatalogsForTesting = true` in setUp (line 43), so these 11 in-test `AccountsManager()` constructions DO get the opt-out. But the flag is process-global; if any concurrent test process or any test running BEFORE this class's setUp reads `AppContainer.production().accountsManager`, the cached AccountsManager was already initialized with `flag=false`. The opt-out fixes new instances only — the singleton is permanently armed. |
| M2 | `PalaceTests/Audiobook/AudiobookIssueFixTests.swift:262,276,293` | UserDefaults mutation with tearDown cleanup, but line 293 is the final write — order-dependent on tearDown actually firing (it does, but coupling is fragile). |
| M3 | `PalaceTests/Settings/DownloadOnlyOnWiFiTests.swift:32` | `removeObject` at line 32 is the body of a test, not tearDown — line 23-26 also has tearDown clear. Belt-and-suspenders, fine. |
| M4 | `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift:26,32` | UserDefaults mutation; setUp clears, tearDown clears. Per-key isolation is fine but the key `"TPPBookmarkDeletionLog"` is a string literal — typo-prone duplicate of production key (`Palace/Bookmarks/...` — verify the prod side uses the same key). |
| M5 | `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift:58,64,80` + `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift:86,92,100` | `Self.lastAppLaunchKey` UserDefaults writes with setUp + tearDown clearing. Clean per-test, but writes are shared across two test classes that both target `lastAppLaunchKey` — concurrent runs (random ordering, F category) could observe each other's writes mid-execution. |

## LOW findings (count + sample, not exhaustive)

- **`AppContainer.production()` read-only access:** ~85 files, ~614 lines. Top consumers: `AccountDetailViewModelTests` (54), `TPPBookRegistryIntegrationTests` (46), `MyBooksViewModelTests` (39), `AppContainerTests` (28), `BookDetailViewModelTests` (22). Each is a DI debt signal — those tests should accept an injected `AppContainer` instance rather than reading `.production()`. Not a flake driver per se; becomes one only when the SUT mutates the read graph (then it's HIGH).
- **`TPPBookRegistry.shared` references:** 4 files, 6 lines — ALL comments referring to the killed singleton (PR #884). Not a live residue.
- **`TPPUserAccount.sharedAccount()` read-only:** `PalaceTests/CoverageGapTests3.swift:200, 203` — reads only, no mutation.
- **`TPPUserAccount.sharedAccount()` in passing references:** `PalaceTests/ButtonStateTests.swift:126,170` (in comments), `PalaceTests/Chaos/ChaosFaultInjectionTests.swift:225` (passes to a mock reauth, no mutation), `PalaceTests/Security/AuthFlowSecurityTests.swift:49,53,85` (passes to TPPReauthenticator — mutation depends on TPPReauthenticator behavior, classified LOW as it doesn't write through to keychain in this context).
- **`AccountStateStore.shared._resetAllForTesting()` correctly used in setUp:** `TPPSignInBusinessLogicTests:56`, `TPPAgeCheckTests:58`, `UnifiedOPDSServiceStateMachineTests:55`, `OPDSFeedServiceStateMachineTests:55`, `CarPlayAuthHelperReadinessTests:34`, `TPPReaderBookmarksReadinessTests:105`, `AudiobookOpenStateRaceTests:53`, `TPPSignInBusinessLogicStateMachineTests:71`, `TPPSignInBusinessLogicExtendedTests:73`, `AccountsManagerStateMachineWiringTests:64`. These are model citizens — the fix shape would propagate this pattern to the H1-H7 sites.

## Cross-cutting finding: notification fan-out is unstubbed

Tests post Palace-domain notifications to `NotificationCenter.default` — the same center production code subscribes to. Production observer sites (`grep '\.publisher(for: \.TPPCurrentAccountDidChange)' Palace/`) include:

```
Palace/Book/Models/TPPBookRegistry.swift:126           (accountDidChangeCancellable — invalidates registry on post)
Palace/MyBooks/MyBooks/BookCellModelCache.swift:126    (cache eviction on post)
Palace/Settings/AccountDetailViewModel.swift:199       (re-fetches sign-in state)
Palace/Holds/HoldsViewModel.swift:129-147              (sync state machine)
Palace/CarPlay/CarPlaySceneDelegate.swift:182          (CarPlay session re-auth)
Palace/CatalogUI/Views/CatalogView.swift:38            (catalog reload)
Palace/AppInfrastructure/DLNavigator.swift:74          (deep-link re-routing)
```

A test posting `.TPPCurrentAccountDidChange` (44+ test sites do this) **invokes the production observer code paths**. The production `TPPBookRegistry` accessed via `AppContainer.production().bookRegistry` flushes state. The next test reading `.bookRegistry` observes the flushed state. This is residue **by way of side-effect**, not direct singleton mutation — but the symptom is identical.

The fix shape applies: notification posts in tests should be routed through a test-local `NotificationCenter` (the production code accepts an injected center for the observers that go through DI, but legacy direct `.default` reads exist).

## Proposed fix SHAPE (NO code)

1. **PalaceSingletonTestCase base class** in `PalaceTests/Mocks/` (or `PalaceTests/Support/`).
   - `setUpWithError`: flips `AccountsManager.deferInitialLoadCatalogsForTesting = true`, calls `AccountStateStore.shared._resetAllForTesting()`, removes `currentAccountIdentifierKey` from UserDefaults, calls `TPPUserAccountMock.resetShared()`.
   - `tearDownWithError`: same reset set, plus a check that no test code added a `NotificationCenter.default` observer without removing it (token-count audit).
   - Registry pattern: each new singleton registers a `() -> Void` resetter into a static array the base class iterates. Adding a new singleton = adding one register call; tests inherit the cleanup automatically.
   - HIGH findings H2-H7 inherit from this base → background `loadCatalogs` race is structurally extinguished.

2. **`scripts/check-singleton-leaks.py` lint script** — recursive grep against `PalaceTests/` for:
   - `AccountsManager(` outside the base class's `setUp` / outside files that explicitly opt out via comment marker `// allow-real-accounts-manager: <reason>`.
   - `TPPUserAccount.sharedAccount(libraryUUID:` outside the base class.
   - `AppContainer.production()` in test files that don't inherit `PalaceSingletonTestCase` (the long-term goal: every test that touches AppContainer either inherits or accepts an injected container).
   - `NotificationCenter.default.post(name: .TPP` in tests that don't have a `// allow-default-center-broadcast: <reason>` marker.
   - Wire into `verify-pr.sh --quick` as a fast pre-merge check.

3. **`AppContainer._cached` test seam.** The architect-cited DI refactor IS out of scope per the contract, BUT a **single static** `internal static func _resetForTesting()` that re-initializes `_cached` with `AccountsManager.deferInitialLoadCatalogsForTesting = true` would let the base class clean up the singleton between test classes. This is one DEBUG-only static function, not a DI refactor — lower-cost intermediate step toward the long-term DI seam.

4. **CI gate: run the suite twice with seeded random orderings + assert pass-set identity.** Add to `scripts/verify-pr.sh`: run with `-randomize-tests-execution-order` and a fixed `XCTEST_RANDOM_SEED=<N>`, then again with `XCTEST_RANDOM_SEED=<M>`. Difference in pass set = order-dependence flake. This catches A's symptom (the "1,049 in isolation, fails in suite" pattern from `regression_develop_2026_05_11_evening.md`) before merge, not after.

## Cross-category overlap notes (per architect's risk callout)

- **A ↔ D overlap on AppContainer URLSession swaps:** I did NOT find a test that mutates `AppContainer.production().networkExecutor.session` or similar. Investigator D should check whether any test mutates `TPPNetworkExecutor.shared` properties. If yes, that's A+D double-counted; dedup by routing through D's URL-protocol teardown work.
- **A ↔ B overlap on `AccountsManager()` background tasks:** The background `loadCatalogs` task is BOTH a singleton-residue source (state leaks to `AccountStateStore.shared` — A) AND a Task that outlives the test (B). The fix shape (`deferInitialLoadCatalogsForTesting = true` in base class) closes BOTH categories at the same seam. Recommend integrator routes this through A's findings since the structural fix lives in `AccountsManager.init`, not in per-test Task cancellation.
- **A ↔ C overlap on `TPPUserAccount.setBarcode/setAuthToken`:** H8 mutations write through to keychain. On CI hosts with `errSecMissingEntitlement` (category C), the write fails silently and the in-memory mutation persists in the test's `account` reference but is NOT persisted to keychain. That's both A (in-memory state leaks) AND C (write didn't land). Dedup: the fix is keychain-availability guarding (category C's work) + the base class's `TPPUserAccountMock.resetShared` (A's work).
- **A ↔ F overlap on suite-ordering amplification:** A's findings are the **substrate** that F amplifies. Without random ordering, even the H1-H7 background-loadCatalogs spawns would settle deterministically. F's structural fix (CI seeding) is needed regardless of A's per-test fixes — A reduces the surface area, F catches the residual.

## Gaps for the integrator

- **`PalaceTests/PalaceTestSetup.swift` (if it exists) was not audited as part of this pass.** That file may already do some singleton reset work — the integrator should check whether the base class proposed in fix #1 should extend it, replace it, or coexist.
- **`#if DEBUG` gating on the opt-out flag:** `AccountsManager.deferInitialLoadCatalogsForTesting` is wrapped in `#if DEBUG` (`Palace/Accounts/Library/AccountsManager.swift:156,171`). The PalaceTests target is built with `DEBUG` set, so the flag IS available — but any test running under a Release build (CI's `enterprise` lane?) would lose the opt-out. Integrator should verify the test-target build config and consider promoting the flag to `internal` (non-DEBUG) with a runtime-only check (`ProcessInfo.processInfo.arguments.contains("-isUnderXCTest")`).
- **The 1150-account log line:** I traced the metric to `Palace/Logging/TPPErrorLogger.swift:801`. I did NOT identify WHICH test triggers the network fetch that walks all 1150 catalogs. The most likely culprits are the 9 `AccountsManager()` construction sites in H2-H7 — but the integrator may want to add a temporary `Log.info` at `Palace/Accounts/Library/AccountsManager.swift:631` (`loadAccountSetsAndAuthDoc` first call site under network path) recording the calling test class via `XCTestObservation` to confirm.
- **`removeAll()` on `TPPUserAccount` sites that are inside `defer` or in the happy-path-only tail of a test** (H8) — incomplete cleanup. The base-class teardown should call `removeAll()` on all `userAccounts` regardless of test outcome. Need to verify `removeAll()` is safe to call against `noAccountSentinelUUID` (`Palace/Accounts/Library/AccountsManager.swift:451`).
- **No `git status` taint:** I made zero file edits outside this transcript. Verify with `git status --short PalaceTests/ Palace/` → expected output is whatever was there before this investigation (no test/prod changes).

## Definition of Done evidence (investigator-scoped)

1. **Every contract grep set run** — counts pasted at top of doc.
2. **HIGH findings cite file:line** — H1-H14 above each carry concrete file:line.
3. **Proposed fix SHAPE (not code)** — section above, 4 numbered proposals, no code samples.
4. **Category overlap flagged** — A↔B, A↔C, A↔D, A↔F notes above.
5. **No production-code or test-file edits** — confirmed; only this transcript was written.

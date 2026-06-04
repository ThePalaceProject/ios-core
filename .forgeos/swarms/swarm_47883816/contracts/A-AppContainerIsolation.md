# Contract A — AppContainerIsolation

## Scope

Create a test-only factory for isolated `AppContainer` instances, migrate the **top concentration** test-body uses of `AppContainer.production()` to the factory, and add a lint test that blocks future regressions outside an explicit whitelist.

### Phasing decision (orchestrator pinned)

Architect recon found **91 files / 636 sites** of `AppContainer.production()` in `PalaceTests/` — 16× the intent estimate. Orchestrator picked **Option (b) — phased**: this swarm migrates the **top-concentration files** that own >50% of all sites; the long tail is added to the lint's exception list with a tracked follow-up swarm to drain it.

This avoids over-budget for implementer A while still landing the structural lint (the lint is the durable change; the migration is the cleanup).

### Files (NEW)
- `PalaceTests/Support/TestAppContainerFactory.swift` — factory implementation
- `PalaceTests/Support/TestAppContainerFactoryTests.swift` — factory tests (SUT instantiation per DoD #1)
- `PalaceTests/MetaTests/AppContainerIsolationLintTests.swift` — lint

### Files (MODIFY — top-concentration migration sites for THIS swarm)

After carving out B/C/D-owned files per the off-limits matrix, A migrates these high-concentration files:

| File | Sites | Owner | Notes |
|------|-------|-------|-------|
| `PalaceTests/BookRegistry/TPPBookRegistryIntegrationTests.swift` | 46 | A | Big file; bulk replace |
| `PalaceTests/MyBooks/MyBooksViewModelTests.swift` | 39 | A | |
| `PalaceTests/ViewModels/BookDetailMetadataHydrationTests.swift` | 30 | A | |
| `PalaceTests/AppInfrastructure/AppContainerTests.swift` | 28 | A | Some tests pin production() identity — verify before migrating |
| `PalaceTests/Network/TPPNetworkExecutorTests.swift` | 23 | A | |
| `PalaceTests/ViewModels/ViewModelComputedPropertyTests.swift` | 22 | A | |
| `PalaceTests/Book/BookDetailViewModelTests.swift` | 22 | A | |
| `PalaceTests/Holds/HoldsViewModelTests.swift` | 17 | A | |
| `PalaceTests/BookStateManagement/BookCellModelStateTests.swift` | 17 | A | |
| `PalaceTests/Performance/BookCellModelCacheTests.swift` | 16 | A | |
| `PalaceTests/CarPlay/CarPlayTests.swift` | 13 | A | |
| `PalaceTests/AppInfrastructure/AppContainerAuthCoordinatorWiringTests.swift` | 12 | A | |
| `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` | 9 | A | |
| `PalaceTests/Network/NetworkQueueTests.swift` | 9 | A | |

Approximate sites migrated: ~303 / 636 (≈48%). The remaining 71 files / ~333 sites are added to the **lint's deferred exception list** (Option b carve-out) and tracked for a follow-up swarm.

### Owned by other implementers (A skips)
- `PalaceTests/ViewModels/AccountDetailViewModelTests.swift` (54 sites) → C
- `PalaceTests/Accounts/AccountsManagerTests.swift` (21 sites + UserDefaults) → D
- `PalaceTests/Accounts/TPPPerAccountIsolationTests.swift` (20 sites) → whitelist (KeychainAvailability)
- `PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift` (14 sites) → whitelist (KeychainAvailability)
- `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift` (16 sites) → B
- `PalaceTests/BookRegistry/TPPBookRegistryDependencyTests.swift` (14 sites) → B
- `PalaceTests/Settings/DownloadOnlyOnWiFiTests.swift` → D

## Public surface

```swift
// PalaceTests/Support/TestAppContainerFactory.swift
@MainActor
func makeTestAppContainer(
    accountsManager: AccountsManager? = nil,
    bookRegistry: TPPBookRegistryProvider? = nil
) -> AppContainer
```

### Required behavior
- Returns a fresh `AppContainer` per call. **NOT cached**. Two consecutive calls return distinct instances (assertable via `===` on the `accountsManager` reference).
- Does NOT mutate `AppContainer._cached`. Production graph is untouched (snapshot test required).
- Does NOT spawn the `AccountsManager.init` background `loadCatalogs` Task — the factory ensures `AccountsManager.deferInitialLoadCatalogsForTesting = true` is set BEFORE constructing `AccountsManager()`.
- Does NOT hit real network at construction time (rely on `NoNetworkURLProtocol` already enabled by `PalaceTestSetup`).
- Accepts optional explicit `accountsManager` / `bookRegistry` overrides so tests that already own a manager (e.g. wiring-case subclasses) can hand it in.

## Whitelist (lint exceptions — `AppContainer.production()` allowed)

The lint test `testNoAppContainerProductionOutsideWhitelist` MUST allow `AppContainer.production()` references in exactly these files:

| File | Reason |
|---|---|
| `PalaceTests/PalaceTestSetup.swift` | Bootstrap path; comment-only refs |
| `PalaceTests/PalaceTestSetupObservationTests.swift` | Tests the observer's reset of production() identity |
| `PalaceTests/Mocks/AccountTestSeeder.swift` | Comment-only reference |
| `PalaceTests/DRM/AdobeActivationTests.swift` | Comment-only ref (AdobeDRMService internal use) |
| `PalaceTests/Support/TestAppContainerFactory.swift` | Factory implementation; may wrap one internal production() call if needed |
| **Phased deferral list** (Option b) | The remaining 71 files / ~333 sites; tracked for follow-up swarm. Each entry must have a `// MIGRATED-DEFERRED: swarm_<id>` comment OR appear in the deferred-list file `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` |

Implementer creates `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` enumerating the 71 files at lint-write time so the lint can verify the deferral list explicitly.

## Off-limits

- `Palace/**` (production code)
- All files assigned to B, C, D, E per the file-assignment matrix
- `PalaceTests/Mocks/**` (E owns expansion of mock lint scope)
- `PalaceTests/Support/PalaceWiringTestCase.swift` (B-adjacent)

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | Migration grep returns 0 hits outside whitelist + deferred list | `grep -rn "AppContainer\.production()" PalaceTests --include="*.swift" \| grep -v "$(cat .forgeos/swarms/swarm_47883816/A-deferred-files.txt \| paste -sd'\|' -)\|PalaceTestSetup\.swift\|PalaceTestSetupObservationTests\|AccountTestSeeder\|AdobeActivationTests\|TestAppContainerFactory"` → must list ONLY whitelist + deferred files |
| 2 | SUT instantiation in factory tests | `grep -c "makeTestAppContainer(" PalaceTests/Support/TestAppContainerFactoryTests.swift` ≥ 1 |
| 3 | Lint catches synthetic violator | The lint test must include `testLintCatchesSyntheticViolation` that fails when fed a synthetic violating string |
| 4 | Two consecutive factory calls yield distinct instances | `XCTAssertFalse(makeTestAppContainer().accountsManager === makeTestAppContainer().accountsManager)` |
| 5 | Factory does NOT mutate production cache | Snapshot `AppContainer.production().accountsManager` before+after `makeTestAppContainer()` — must be `===` (unchanged) |
| 6 | Mutation kill rate on factory ≥ 50% diff-scoped | `python3 scripts/palace_mutate.py --file PalaceTests/Support/TestAppContainerFactory.swift --tests TestAppContainerFactoryTests --diff-only` |
| 7 | Build clean | `xcodebuild ... build` PASS, tail pasted |
| 8 | verify-pr.sh --quick clean | PASS, tail pasted |
| 9 | Blast-radius check | `python3 scripts/check-blast-radius.py --quiet` exit 0 (no new public API in `Palace/`) |
| 10 | Contract reconciliation | `python3 scripts/check-contract-reconciliation.py --quiet` exit 0 |

## Coordination notes

- **STOP per scope-deferral protocol if migration site count under option (b) exceeds budget.** Do NOT silently partial-ship. Phase further into top-7 if needed.
- **E depends on A's whitelist** — once A is committed, E expands the meta lint to all of `PalaceTests/**` reusing A's whitelist + deferred list verbatim.
- The deferred list is itself code-reviewable — keep it precise. No "and everything else" wildcards.

---
name: swarm test pollution sweep
author: maurice.carrier
swarm_id: swarm_47883816
created: 2026-06-04
type: refactor
risk: standard
---

## Claims
See work-packages A–F below.

## Anti-claims
See anti-claims section below.

## Files in scope
See files-in-scope section below.

# Test pollution sweep — eliminate cross-test state leaks across PalaceTests/

## Motivation

CI flake on Palace iOS is dominated by test-order dependence and shared-singleton pollution, not real product bugs. A 2026-06-04 static audit of `PalaceTests/` found 7 polluter classes — top three are:

1. `AppContainer.production()` called inside ~40 test bodies (production singleton graph reused across tests; reset happens *after*, not before)
2. Direct `AccountsManager()` outside `PalaceWiringTestCase` at ~15 sites (skips the cancellation hook → background `loadCatalogs` Task outlives the test)
3. `TPPUserAccount.sharedAccount(…)` at ~25 test sites (touches the real per-library keychain registry; cross-test pollution + CI fragility when entitlement absent)

This swarm fixes these structurally — factories + lint rules — so that randomized test order can be flipped on as a follow-up without exploding the suite.

## Claims (what the diff WILL deliver)

A. **AppContainer isolation**: new `makeTestAppContainer()` factory in `PalaceTests/Support/`; migrate ~40 `AppContainer.production()` test-body call sites; lint rule in `PalaceTests/MetaTests/` that fails the suite if `AppContainer.production()` appears in `PalaceTests/**` outside an explicit whitelist (PalaceTestSetup bootstrap + PalaceTestSetupObservationTests).

B. **AccountsManager cancellation contract**: promote `PalaceWiringTestCase.makeFreshAccountsManager()` from convention to lint; migrate the 15 direct `AccountsManager()` call sites in Integration/, Accounts/, BookRegistry/ tests; lint rule bans `AccountsManager(` outside `PalaceWiringTestCase.swift` and the factory.

C. **TPPUserAccount isolation**: new `TPPUserAccountTestFactory.makeIsolated(libraryUUID:)` returning an account NOT in the shared per-library cache and backed by an in-memory credential store; migrate top concentration first (`AccountDetailViewModelTests.swift` ~20 calls); lint bans `TPPUserAccount.sharedAccount(` outside factory + explicit Keychain integration tests.

D. **UserDefaults isolation**: new `XCTestCase.testUserDefaults()` helper returning a per-test-class `UserDefaults(suiteName:)`; resetter registered to `removePersistentDomain(forName:)` after the test; migrate `UserDefaults.standard` writes in Settings/, Accounts/, Audiobook/, AppInfrastructure/, CatalogDomain/, SignInLogic/, Bookmarks/; lint warns on `UserDefaults.standard` outside factory + integration tests.

E. **MetaTests lint expansion**: promote `MockIsolationLintTests` rules (shared resetShared, cancellables teardown, NotificationCenter observer removal) from `PalaceTests/Mocks/` scope to all of `PalaceTests/**`; add new rule that test classes referencing polluter patterns MUST declare `override func tearDown`.

F. **Production fire-and-forget audit**: spot-check the 140 `Task` / `DispatchQueue.async` occurrences in tests; flag any unowned async work in production code reachable from tests.

## Anti-claims (what the diff WILL NOT do)

- Does NOT change production behavior — these are test-target changes plus narrowly-scoped production seams (e.g. allowing UserDefaults injection where it isn't already). No public API of `Palace` changes.
- Does NOT add safety-net fallbacks in factories. If production reads `.shared` somewhere that can't be intercepted, the seam gap is documented and STOPPED per scope-deferral protocol; we do not paper over with fallbacks.
- Does NOT touch Keychain integration tests (`TPPKeychainManagerTests`, `TPPPerAccountIsolationTests`, `BookRegistry*` keychain-dependent paths) — they have `KeychainAvailability` guards already.
- Does NOT flip randomized test order on — that is a deliberate follow-up gated on this swarm passing CI green for at least one week.
- Does NOT modify `PalaceAudiobookToolkit` submodule.
- Does NOT add new user-facing copy. No final on new factory classes (per feedback memory). No force unwraps.

## Files-in-scope

### New files (test target)
- `PalaceTests/Support/TestAppContainerFactory.swift` — work package A factory
- `PalaceTests/Support/TPPUserAccountTestFactory.swift` — work package C factory
- `PalaceTests/Support/XCTestCase+testUserDefaults.swift` — work package D helper
- `PalaceTests/Support/TestAppContainerFactoryTests.swift` — A factory tests
- `PalaceTests/Support/TPPUserAccountTestFactoryTests.swift` — C factory tests
- `PalaceTests/Support/XCTestCase+testUserDefaultsTests.swift` — D helper tests
- `PalaceTests/MetaTests/AppContainerIsolationLintTests.swift` — A lint
- `PalaceTests/MetaTests/AccountsManagerIsolationLintTests.swift` — B lint
- `PalaceTests/MetaTests/TPPUserAccountIsolationLintTests.swift` — C lint
- `PalaceTests/MetaTests/UserDefaultsIsolationLintTests.swift` — D lint
- `PalaceTests/MetaTests/TearDownRequiredLintTests.swift` — E lint (extends MockIsolationLintTests scope)

### Modified files (test target — migration sites)
Listed in detail per contract; high-level by work package:
- A (~40): `OPDS2/OPDS2CatalogWiringTests.swift`, `ViewModels/AccountDetailViewModelTests.swift`, `CoverageGapTests.swift`, `Settings/DownloadOnlyOnWiFiTests.swift`, `DRM/AdobeActivationTests.swift`, others discovered by architect grep
- B (~15): `Integration/SignInToReadFlowIntegrationTests.swift`, `Integration/AccountSwitchLifecycleTests.swift`, `Integration/ColdStartResumeIntegrationTests.swift`, `Integration/BorrowAndDownloadIntegrationTests.swift`, `Accounts/AccountsManagerCancellationTests.swift`, `BookRegistry/TPPBookRegistry{Dependency,Persistence,AtomicWrite,LargeCorpus,Migration}Tests.swift`
- C (~25): `ViewModels/AccountDetailViewModelTests.swift`, `Accounts/AccountSwitchCleanupTests.swift`, `Security/AuthFlowSecurityTests.swift`, `Book/BookRegistrySyncReadinessTests.swift`, `Chaos/ChaosFaultInjectionTests.swift`, `CoverageGapTests3.swift`
- D (~30): `Settings/*.swift`, `Accounts/AccountsManagerTests.swift`, `Audiobook/AudiobookIssueFixTests.swift`, `AppInfrastructure/RemoteFeatureFlagsTests.swift`, `CatalogDomain/Catalog*Tests.swift`, `SignInLogic/ForceResetTests.swift`, `Bookmarks/TPPBookmarkDeletionLogTests.swift`

### Modified files (production — narrowly scoped seams only)
- Whatever minimum DI changes are needed for D (UserDefaults injection); architect to audit and pin in contract D
- Anything F's audit surfaces (expected: 0–2 small cancellation tokens; architect to pin)

### Untouched (explicit exclusions)
- `Palace/Audiobooks/PalaceAudiobookToolkit/` submodule
- All Keychain integration tests with `KeychainAvailability` guards
- `Palace/Reader2/` Readium 3.x glue (no test pollution dependency)
- Production critical paths (SignIn/Borrow/Return/DRM/Audiobook) — except minimum DI seams audited by architect

## Verification criteria

Per CLAUDE.md Definition of Done — every implementer pastes evidence in their transcript for each of the 11 checks. Orchestrator skeptic pass at Phase 4.5 re-runs structural checks:

- **A**: `grep -rn AppContainer.production PalaceTests/ | grep -v PalaceTestSetup.swift | grep -v PalaceTestSetupObservationTests.swift | grep -v TestAppContainerFactory` must return 0 hits post-migration.
- **B**: `grep -rn 'AccountsManager(' PalaceTests/ | grep -v Mock | grep -v Fake | grep -v PalaceWiringTestCase | grep -v Factory` must return 0 hits.
- **C**: `grep -rn 'TPPUserAccount.sharedAccount(' PalaceTests/ | grep -v TPPKeychain | grep -v TPPPerAccountIsolation | grep -v Factory | grep -v Mock` must match the documented whitelist exactly.
- **D**: `grep -rn 'UserDefaults.standard' PalaceTests/ | grep -v testUserDefaults | grep -v Keychain | grep -v Factory` produces a small, documented list.
- **E**: new lint tests in `MetaTests/` fail when invoked on a synthetic violating file (proof the lint actually catches the pattern).
- **F**: audit document at `.forgeos/swarms/swarm_47883816/transcripts/F-audit.md` with grep evidence, ≤2 findings.
- **Build**: `xcodebuild ... build` clean on the orchestrator branch.
- **Tests**: green test count after ≥ before; xcresult bundle paths pasted in each implementer transcript per DoD #7.
- **Contract reconciliation**: `python3 scripts/check-contract-reconciliation.py --quiet` exit 0.
- **Blast radius**: `python3 scripts/check-blast-radius.py --quiet` exit 0 (no new public API surface in Palace target).
- **Intent recorded**: `python3 scripts/check-intent-recorded.py --quiet` exit 0 (this file satisfies the gate).

## Risk + rollback

Risk: standard (test-target changes + narrowly-scoped DI seams).

Rollback: revert the swarm PR. Lint rules can be disabled per-rule by deleting the corresponding `MetaTests/*Tests.swift` file if a false positive emerges; factories are additive and can be left in place without harm.

## Out-of-scope follow-ups (deliberately deferred)

- Flip `randomTestExecutionOrder = true` on the test scheme.
- Build a test-bisector tool that, given a failing test, binary-searches the order to find the polluter (currently we'd be guessing; after this swarm, the bisector has signal).
- Auto-quarantine bucket with 14-day fix-or-delete deadline.

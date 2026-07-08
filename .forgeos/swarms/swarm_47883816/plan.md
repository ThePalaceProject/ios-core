# Swarm 47883816 — Test Pollution Sweep — Plan

## Goal

Eliminate cross-test state pollution in `PalaceTests/` by introducing test-only factories (`TestAppContainerFactory`, `TPPUserAccountTestFactory`, `XCTestCase+testUserDefaults`), promoting existing `PalaceWiringTestCase.makeFreshAccountsManager()` from convention to lint-enforced contract, and adding meta-test lint rules that prevent regression. This is preparatory work for flipping `randomTestExecutionOrder = true` on the test scheme in a follow-up, gated on this swarm passing CI green for ≥ 1 week.

## Work packages (6)

- **A — AppContainerIsolation**: Factory + lint + migration of `AppContainer.production()` test-body call sites (phased — top concentration this swarm, long tail deferred to follow-up).
- **B — AccountsManagerIsolation**: Lint + migration of raw `AccountsManager()` to the existing `PalaceWiringTestCase` seam.
- **C — TPPUserAccountIsolation**: Factory + lint + migration of `TPPUserAccount.sharedAccount()` to a UUID-namespaced factory (no production change).
- **D — UserDefaultsIsolation**: Helper + warn-only lint + migration of test-owned `UserDefaults.standard` state + minimum production DI in TPPSettings + RemoteFeatureFlags.
- **E — MetaTestsLintExpansion**: Expand `MockIsolationLintTests` from `PalaceTests/Mocks/` to all of `PalaceTests/**` + new `TearDownRequiredLintTests`.
- **F — FireAndForgetAudit**: Pure audit; document findings, propose follow-ups, ≤2 trivial fixes allowed inline.

## Parallelism

- **Parallel batch 1**: A, B, C, D, F dispatched concurrently. They have no inter-dependencies (off-limits matrix prevents file collision).
- **Sequential follow-on**: E dispatched after A, B, C, D return (E's lint whitelists reference theirs).

## Verified site counts vs intent estimates (architect recon)

| Work package | Intent estimate | Verified | Delta |
|---|---|---|---|
| A — `AppContainer.production()` | "~40 test bodies" | **636 occurrences in 91 files** | **16× — phased Option (b)** |
| B — raw `AccountsManager()` | "~15 sites" | 17 sites / 10 files | 1.1× — tractable |
| C — `TPPUserAccount.sharedAccount()` | "~25 sites" | 37 lines / 8 files | 1.5× — tractable |
| D — `UserDefaults.standard` test | "~30 sites" | 71 lines / 13 files | 2.4× — scope-narrowed |
| D — `UserDefaults.standard` prod | implicit | 89 sites | Out of swarm; only TPPSettings + RemoteFeatureFlags DI in scope |
| F — fire-and-forget audit | "~140" | 170 sites | Audit handles it |

**A's delta is the load-bearing scope risk.** Per architect recommendation (Option b), this swarm migrates the top-concentration files (~14 files / ~303 sites / 48% of all sites). The remaining 71 files / ~333 sites are added to the lint's deferred exception list. Follow-up swarm shrinks the exception list.

## Risks

1. **A's site count delta** → mitigated by Option (b) phasing.
2. **C's keychain-namespace assumption** — if `StorageKey.X.keyForLibrary(uuid:)` doesn't actually segregate by `libraryUUID`, C STOPs with BLOCKED and proposes follow-up with `#if DEBUG` init seam.
3. **D's production DI blast radius** — if TPPSettings DI requires >5 caller changes, D STOPs and scope-reduces to test-only-state files.
4. **E's dependency timing** — E cannot dispatch until A/B/C/D commit their whitelist files. Orchestrator enforces.

## File-assignment matrix (overlap resolution)

| File | Owner | Notes |
|---|---|---|
| `PalaceTests/ViewModels/AccountDetailViewModelTests.swift` | C | 17 sharedAccount + AppContainer.production — C handles both |
| `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` | C | 10 sharedAccount |
| `PalaceTests/Security/AuthFlowSecurityTests.swift` | C | 3 sharedAccount + 1 AppContainer.production |
| `PalaceTests/Book/BookRegistrySyncReadinessTests.swift` | C | 1 sharedAccount |
| `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` | C | 1 sharedAccount |
| `PalaceTests/CoverageGapTests3.swift` | C | 2 sharedAccount (1 whitelisted identity check) |
| `PalaceTests/ButtonStateTests.swift` | C | Comment-only |
| `PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift` | C | Comment-only |
| `PalaceTests/Integration/AccountSwitchLifecycleTests.swift` | B | 1 AccountsManager() |
| `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift` | B | 1 AccountsManager() |
| `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift` | B | 1 AccountsManager() |
| `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift` | B | 1 AccountsManager() |
| `PalaceTests/Accounts/AccountsManagerCancellationTests.swift` | B | 5 AccountsManager() |
| `PalaceTests/BookRegistry/TPPBookRegistry{Atomic,Dependency,LargeCorpus,Migration,Persistence}Tests.swift` | B | 7 AccountsManager() across 5 files |
| `PalaceTests/Accounts/AccountsManagerTests.swift` | D | 7 UserDefaults + 21 AppContainer.production — D end-to-end |
| `PalaceTests/Settings/DownloadOnlyOnWiFiTests.swift` | D | UserDefaults + AppContainer.production |
| `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` | D | 10 UserDefaults (wiring test) |
| `PalaceTests/Audiobook/AudiobookIssueFixTests.swift` | D | 6 UserDefaults |
| `PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift` | D | 6 UserDefaults |
| `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift` | D | 2 UserDefaults |
| `PalaceTests/SignInLogic/ForceResetTests.swift` | D | 9 UserDefaults |
| `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift` | D | 3 UserDefaults |
| `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift` | D | 3 UserDefaults |
| `PalaceTests/Accounts/AccountDetailsURLTests.swift` | D | 5 UserDefaults |
| `PalaceTests/CoverageGapTests.swift` | D | 2 UserDefaults |
| Remaining ~14 high-concentration AppContainer files | A | See A contract |
| Long-tail 71 files | A's deferred list | Tracked in `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` |

## Acceptance criteria

Per intent file verification criteria (and per CLAUDE.md 11-check DoD). Implementers paste evidence in each transcript:

```bash
# A
grep -rn "AppContainer\.production()" PalaceTests --include="*.swift" \
  | grep -v "$(cat .forgeos/swarms/swarm_47883816/A-deferred-files.txt | paste -sd'|' -)\|PalaceTestSetup\.swift\|PalaceTestSetupObservationTests\|TestAppContainerFactory\|AccountTestSeeder\|AdobeActivationTests"
# Expected: only whitelist + deferred entries

# B
grep -rn 'AccountsManager(' PalaceTests --include="*.swift" \
  | grep -v 'Mock\|Fake\|makeFreshAccountsManager\|PalaceWiringTestCase\.swift\|PalaceWiringTestCaseTests\.swift\|AppContainerResetTests\.swift'
# Expected: 0 lines

# C
grep -rn 'TPPUserAccount\.sharedAccount(' PalaceTests --include="*.swift" \
  | grep -v 'TPPPerAccountIsolation\|TPPCredentialIsolationE2E\|TPPUserAccountTestFactory\|CoverageGapTests3\|Mock\|// MIGRATED:'
# Expected: exactly the documented whitelist

# D
grep -rn 'UserDefaults\.standard' PalaceTests --include="*.swift" \
  | grep -v 'testUserDefaults\|Keychain\|XCTestCase+testUserDefaults'
# Expected: documented list per D contract

# E
# MockIsolationLintTests and TearDownRequiredLintTests pass on real codebase, fail on synthetic-violator inputs

# F
# .forgeos/swarms/swarm_47883816/transcripts/F-audit.md exists with classified findings

# Build / DoD
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build  # PASS
scripts/verify-pr.sh --quick                                       # PASS
python3 scripts/check-contract-reconciliation.py --quiet           # exit 0
python3 scripts/check-blast-radius.py --quiet                      # exit 0
python3 scripts/check-intent-recorded.py --quiet                   # exit 0
```

# Contract C — TPPUserAccountIsolation

## Scope

Create a test-only factory that returns `TPPUserAccount` instances under a UUID-namespaced `libraryUUID` (NOT in `AccountsManager`'s shared cache), register a `SingletonResetRegistry` resetter to clear the per-test keychain residue, migrate ~31 `sharedAccount` call sites, and add lint.

### Production seam audit finding (architect)

`Palace/Accounts/User/TPPUserAccount.swift` exposes `init(libraryUUID:)` at line 84 with internal access. Direct construction bypasses `AccountsManager`'s cache (the doc comment explicitly warns against this in production code, but for tests this is the seam we want).

**Constraint:** Keychain reads/writes via `TPPKeychainVariable` are NOT DI-injectable in production. The factory therefore uses UUID-per-call `libraryUUID` namespacing so each test's keychain entries land under a unique key-prefix, and registers a resetter that wipes that prefix on test end. This is **keychain-namespaced isolation**, NOT in-memory isolation. Per the intent's anti-claim ("Does NOT change production behavior"), this is the maximum non-invasive isolation possible.

**Scope-deferral marker**: if the orchestrator/user wants TRUE in-memory credential isolation, that requires a `#if DEBUG` init seam on `TPPUserAccount` accepting an injected `TPPKeychainStorage` protocol — NOT in this swarm. Documented as out-of-scope follow-up in `outcome.md`.

### Files (NEW)
- `PalaceTests/Support/TPPUserAccountTestFactory.swift`
- `PalaceTests/Support/TPPUserAccountTestFactoryTests.swift`
- `PalaceTests/MetaTests/TPPUserAccountIsolationLintTests.swift`

### Files (MODIFY)
- `PalaceTests/ViewModels/AccountDetailViewModelTests.swift` (17 sharedAccount sites — C also handles any `AppContainer.production()` in the same lines so A skips this file)
- `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` (10 sites)
- `PalaceTests/Security/AuthFlowSecurityTests.swift` (3 sites + 1 AppContainer.production)
- `PalaceTests/Book/BookRegistrySyncReadinessTests.swift` (1 site)
- `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` (1 site)
- `PalaceTests/CoverageGapTests3.swift` (2 sites: one is an identity-check that MUST stay on sharedAccount — KEEP per whitelist below; the other migrates)
- `PalaceTests/ButtonStateTests.swift` (comment-only — verify; replace with `// MIGRATED:` marker)
- `PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift` (comment-only — same)

## Public surface

```swift
// PalaceTests/Support/TPPUserAccountTestFactory.swift
struct TPPUserAccountTestFactory {
    static func makeIsolated(libraryUUID: String? = nil) -> TPPUserAccount
}
```

### Required behavior
- If `libraryUUID == nil`, mints a fresh per-call `"test-uuid-\(UUID().uuidString)"`.
- Constructs `TPPUserAccount(libraryUUID: testUUID)` via the internal init (factory file colocated in the test target, so internal init is accessible).
- Registers a `SingletonResetRegistry` resetter (one-time at process start) that, on every `testCaseDidFinish`, iterates a tracked-per-test list and calls `account.removeAll()` to clear keychain residue under each minted UUID.
- Returns the account instance; caller uses it directly without touching `AccountsManager.shared` cache.

## Whitelist (lint exceptions for `TPPUserAccount.sharedAccount`)

| File | Reason |
|---|---|
| `PalaceTests/Mocks/TPPUserAccountMock.swift` (if exists) | Mock |
| `PalaceTests/Accounts/TPPPerAccountIsolationTests.swift` | Uses `KeychainAvailability.skipIfUnavailable()` — tests the keychain integration on purpose |
| `PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift` | E2E keychain integration; KeychainAvailability gate |
| `PalaceTests/CoverageGapTests3.swift` (mark the identity-assertion line with `// MIGRATED: keep — identity test of shared cache`) | Identity assertion: `XCTAssertTrue(account === TPPUserAccount.sharedAccount())` — testing the shared cache itself. Use comment marker, NOT line number, per architect-reviewer note. |
| `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/TPPKeychainSwiftTests.swift` | Out-of-PalaceTests-target |
| `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/TPPKeychainManagerTests.swift` | Out-of-target |
| `PalaceTests/Support/TPPUserAccountTestFactory.swift` | Factory itself |
| Comment-only files with `// MIGRATED:` markers | Cleanup-pass marker — lint allows |

## Off-limits

- All A, B, D, E files (per assignment matrix)
- `Palace/**` (production code — including `TPPUserAccount.swift`. Do NOT add a `#if DEBUG` init seam; that's a deferred scope item)

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | Migration grep matches whitelist | `grep -rn 'TPPUserAccount\.sharedAccount(' PalaceTests --include="*.swift" \| grep -v "Mock\|TPPPerAccountIsolation\|TPPCredentialIsolationE2E\|CoverageGapTests3\|TPPUserAccountTestFactory\|// MIGRATED:"` matches documented whitelist exactly |
| 2 | Factory tests construct SUT ≥ 1 | `grep -c "TPPUserAccountTestFactory\|makeIsolated(" PalaceTests/Support/TPPUserAccountTestFactoryTests.swift` ≥ 1 |
| 3 | Lint catches synthetic violator | `testLintCatchesSyntheticViolation` passes |
| 4 | Factory accounts isolated across calls | `XCTAssertNotEqual(makeIsolated().libraryUUID, makeIsolated().libraryUUID)` |
| 5 | Resetter clears keychain residue | Write a credential via factory account; complete test; assert next test sees no residual credential (test the resetter wiring) |
| 6 | Mutation kill rate ≥ 50% diff-scoped on factory | `palace_mutate.py` paste output |
| 7 | Build + verify-pr clean | PASS |
| 8 | No production change | `git diff Palace/Accounts/User/TPPUserAccount.swift` → empty |

## Coordination notes

- **STOP / scope-deferral marker**: if implementer discovers that even the UUID-namespaced approach cannot isolate (e.g. keychain entries don't actually segregate by libraryUUID, contradicting line 232's `StorageKey.X.keyForLibrary(uuid: libraryUUID)` assumption), the implementer MUST stop and report BLOCKED rather than ship in-memory hacks. The scope-deferral options for the user are: (a) extend budget to add the `#if DEBUG` init seam, (b) accept the contract reduction (only the comment-only files and identity-check sites are clean-migrated), (c) split into a follow-up swarm.

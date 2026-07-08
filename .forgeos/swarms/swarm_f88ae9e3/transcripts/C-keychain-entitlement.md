# Investigator C — Keychain Entitlement (errSecMissingEntitlement / -34018)

**Mode:** INVESTIGATION ONLY. No code changed.
**Date:** 2026-05-29
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_f88ae9e3-orchestrator`

---

## TL;DR

- **The guard works** — `PalaceTests/Keychain/KeychainAvailability.swift` (36 LOC) is a clean
  probe-and-skip helper; the parallel copy at
  `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/KeychainAvailability.swift`
  is the SPM-side twin and is correctly adopted there.
- **9 test files touch keychain unguarded** by string match; **4 are real risks** after
  triage (comment-only / mock-only references filtered out).
- **The 8 `-34018` lines in CI emit from 3 production lines**:
  - `Palace/Keychain/TPPKeychainManager.swift:67` — the `cleanupAllKeychainItems()` loop
    fires `Log.error("Error deleting keychain items for class \(secClass): \(status)")`
    **once per secClass** (5 classes: `genp`, `inet`, `cert`, `keys`, `idnt`).
  - `Palace/Packages/PalaceKeychain/Sources/PalaceKeychain/TPPKeychain.swift:82` —
    `Log.log("Failed to REMOVE object from keychain. error: \(status)")` (the 2 REMOVE lines).
  - `Palace/Packages/PalaceKeychain/Sources/PalaceKeychain/TPPKeychain.swift:67` —
    `Log.log("Failed to ADD secure values to keychain. ... Error: \(status)")` (the 1 ADD line).
- **Cascade trigger**: `TPPKeychainManager.validateKeychain()` runs from
  `TPPAppDelegate.swift:107` AND is reachable transitively from any test that constructs
  `AppContainer.production()` (85 test files) or `AccountsManager()` (10 test files)
  because `validateKeychain`'s default param itself reads `AppContainer.production().settings`.
  First test to wake the cached `_cached: AppContainer` pays the keychain cost.
- **Fix shape**: a `KeychainBackedTestCase` base + a runnable `check-keychain-guard-coverage.py`
  grep-lint = structural prevention. Phase-2 follow-up: `InMemoryCredentialStore` via DI.

---

## 1. The `KeychainAvailability` seam — definitions

Two parallel copies, both ~36 LOC, both correct:

### `PalaceTests/Keychain/KeychainAvailability.swift` (Palace target)
```swift
enum KeychainAvailability {
    static var isWritable: Bool {
        let probeKey = "TPPKeychainAvailabilityProbe_\(UUID().uuidString)"
        let probeValue = "probe"
        TPPKeychain.shared.setObject(probeValue, forKey: probeKey)
        defer { TPPKeychain.shared.removeObject(forKey: probeKey) }
        return (TPPKeychain.shared.object(forKey: probeKey) as? String) == probeValue
    }
    static func skipIfUnavailable() throws {
        guard isWritable else {
            throw XCTSkip("Keychain unavailable on this host (errSecMissingEntitlement -34018)...")
        }
    }
}
```

### `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/KeychainAvailability.swift` (SPM target)
Verbatim twin, swapped `@testable import Palace` -> `@testable import PalaceKeychain`.

**SPM-side adoption is clean**: `TPPKeychainTests.swift:8` and `TPPKeychainSwiftTests.swift:11`
both call `try KeychainAvailability.skipIfUnavailable()` in `setUpWithError()`.

---

## 2. Guard adoption table — main `PalaceTests/` target

### 2a. Files that touch keychain (real or transitive) — 9 hit by string-match

Computed as `grep -rl "TPPUserAccount.sharedAccount\|TPPUserAccount.shared\|TPPKeychain.shared\|TPPKeychainManager" PalaceTests/`:

| File | TPPUserAccount.shared hits | TPPKeychain hits | uses `skipIfUnavailable` | severity | notes |
|------|----------------------------|------------------|--------------------------|----------|-------|
| `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` | 10 (real `.sharedAccount(libraryUUID:)`) | 0 | **NO** | **HIGH** | constructs real per-library TPPUserAccount; lazy keychain reads/writes on init |
| `PalaceTests/Book/BookRegistrySyncReadinessTests.swift` | 1 (line 131, real `.sharedAccount(libraryUUID:)`) | 0 | **NO** | **MED** | self-skips via `hasCredentials()` check (lines 132-141) — graceful but logs noise |
| `PalaceTests/ButtonStateTests.swift` | 2 (both comment-only — lines 126, 170) | 0 | NO | **NONE** | false positive; comments only; code uses `TPPUserAccountMock` |
| `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` | 1 (line 225, real `.sharedAccount()`) | 0 | **NO** | **HIGH** | `TPPReauthenticatorMock` is used but `TPPUserAccount.sharedAccount()` returns real singleton |
| `PalaceTests/CoverageGapTests3.swift` | 3 (lines 200, 203 real `.sharedAccount()` + 1 comment) | 0 | **NO** | **HIGH** | `testTPPUserAccount_sharedAccount_isAccessible` reads `account.authState` (keychain-backed) |
| `PalaceTests/Keychain/TPPKeychainManagerTests.swift` | 0 | 10 (all `TPPKeychainManager.logKeychainError` — pure log function) | NO | **NONE** | false positive; only exercises `logKeychainError`, never touches Sec API |
| `PalaceTests/MyBooks/MyBooksViewModelTests.swift` | 1 (comment-only on line 18) | 0 | NO | **NONE** | false positive; doc-comment only |
| `PalaceTests/MyBooks/TPPBookBearerTokenTests.swift` | 0 | 3 (real `TPPKeychain.shared.removeObject` in tearDown; `book.bearerToken=` setter is keychain-backed) | **NO** (homegrown probe at line 24-39 used in only 1 of 9 tests) | **HIGH** | 8 tests write `book.bearerToken` / `book.bearerTokenFulfillURL` -> `TPPKeychain.shared`. Only `testFulfillURL_persistsAcrossNewBookInstances` (line 151) gates on its own duplicate probe. The other 8 silently nil-back on CI |
| `PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift` | 1 (comment-only on line 9) | 0 | NO | **NONE** | false positive; tests use `TPPMultiLibraryAccountMock` (per-uuid mocks) |

### 2b. Indirect keychain access via `AccountsManager()`

Tests that construct a **real** `AccountsManager()` (production class, no DI):

| File | uses `skipIfUnavailable` | severity | notes |
|------|--------------------------|----------|-------|
| `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` | NO | **MED** | sets `deferInitialLoadCatalogsForTesting=true` (existing test-isolation seam); mints `TPPUserAccount` per-uuid in 4 tests |
| `PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift` | NO | **LOW** | constructor only — no credential round-trip |
| `PalaceTests/BookRegistry/TPPBookRegistryDependencyTests.swift` | NO | **LOW** | constructor only |
| `PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift` | NO | **LOW** | constructor only |
| `PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift` | NO | **LOW** | constructor only |
| `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift` | NO | **LOW** | constructor only |
| `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift` | NO | **MED** | uses TPPUserAccountMock seam — but real AccountsManager init still fires validateKeychain cascade |
| `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift` | NO | **MED** | same |
| `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift` | NO | **MED** | uses TPPUserAccountMock + provider injection but still constructs real AccountsManager |

### 2c. Indirect keychain access via `AppContainer.production()` — 85 files

Every one eventually triggers `AccountsManager.init()` once when `_cached: AppContainer` first wakes
(`Palace/AppInfrastructure/AppContainer.swift:223`). Under random ordering, whoever runs first pays
the cascade. The other 84 are nearly free. **NOT individually high-severity** (cost is one-time per
test process, scoped to the static-let init) but **noisy** in CI logs and amplifies category F
(suite ordering).

### 2d. Guard placement — `setUpWithError` vs `setUp` per pin

The plan calls out the ordering bug: guard MUST be in `setUpWithError` (not `setUp`).

| File | placement | issue |
|------|-----------|-------|
| `PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift` | `setUpWithError:17` | OK |
| `PalaceTests/Accounts/TPPPerAccountIsolationTests.swift` | `setUpWithError:19` | OK |
| `PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift` | **per-method** (line 229) | **LOW** — relies on every test method calling guard; drift-prone |
| `PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift` | **per-method** (line 212) | **LOW** — same pattern |
| `PalaceTests/Integration/AccountSwitchLifecycleTests.swift` | `setUpWithError:59` | OK |
| `PalaceTests/Security/AuthFlowSecurityTests.swift` | `setUpWithError:25` + `setUp:28` (both) | OK (setUp runs after setUpWithError per XCTest contract) |
| `PalaceTests/SignInLogic/TPPCredentialSnapshotCoherenceTests.swift` | `setUpWithError:43` | OK |
| `PalaceTests/ViewModels/AccountDetailViewModelTests.swift` (4 classes) | all 4 classes guarded (`:18`,`:432`,`:659`,`:1093`) | OK |

---

## 3. The 8 CI `-34018` log lines — exact source mapping

CI run 26593379677 emits 8 distinct lines. They come from **3 production locations**:

| CI message | source | how many distinct emissions |
|------------|--------|-----------------------------|
| `Error deleting keychain items for class genp/inet/cert/keys/idnt: -34018` | `Palace/Keychain/TPPKeychainManager.swift:67` | 5 (one per `secClass` in the `cleanupAllKeychainItems()` loop) |
| `Failed to REMOVE object from keychain. error: -34018` | `Palace/Packages/PalaceKeychain/Sources/PalaceKeychain/TPPKeychain.swift:82` | 2 (called on credential `removeObject(forKey:)` paths) |
| `Failed to ADD secure values to keychain. ... Error: -34018` | `Palace/Packages/PalaceKeychain/Sources/PalaceKeychain/TPPKeychain.swift:67` | 1 (called on credential `setObject(_:forKey:)` paths) |

**Cascade trigger** = `TPPKeychainManager.validateKeychain()` at line 16-27:

```swift
static func validateKeychain(settings: TPPSettings = AppContainer.production().settings) {
    if settings.appVersion == nil {
        Log.info(#file, "Fresh install detected. Cleaning up all keychain items...")
        cleanupAllKeychainItems()   // emits 5x line 67
    }
    ...
}
```

`validateKeychain()` is called from `TPPAppDelegate.swift:107` (only call site). On a fresh CI sim
profile `appVersion == nil` evaluates true once per test process -> 5 cleanup-loop emissions.
The 2 REMOVE / 1 ADD emissions are subsequent credential ops by user-account code paths that run
after the cleanup fails and themselves fail.

---

## 4. Severity summary

**HIGH** (real test failures or false greens on CI):
1. `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` — 5 test methods (lines 103, 114, 125,
   136 and `testBookCellModelCache_*`) construct `TPPUserAccount.sharedAccount(libraryUUID:)` with
   no guard. Lazy keychain on subsequent credential access fails silently. (10 unguarded touches)
2. `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` — 1 test
   (`test_scenario5_tokenExpiryMidAnnotationSync...` line 225) calls real `TPPUserAccount.sharedAccount()`
   then drives a 401-then-reauth scenario; reauth path hits keychain.
3. `PalaceTests/CoverageGapTests3.swift` — 1 test (`testTPPUserAccount_sharedAccount_isAccessible`
   line 200) reads `account.authState` (keychain-backed `TPPKeychainCodableVariable<TPPAccountAuthState>`).
4. `PalaceTests/MyBooks/TPPBookBearerTokenTests.swift` — 8 test methods write `book.bearerToken` /
   `book.bearerTokenFulfillURL` which call `TPPKeychain.shared.setObject`/`object(forKey:)`. On CI:
   write returns -34018, read returns nil, `XCTAssertEqual(book.bearerToken, "test-...")` FAILS for
   set-then-read assertions. The lone protected test (`testFulfillURL_persistsAcrossNewBookInstances:151`)
   uses a **homegrown duplicate probe** `isKeychainAccessible` (lines 24-39) — should adopt
   `KeychainAvailability` instead.

**MED** (graceful but noisy / cascade trigger):
5. `PalaceTests/Book/BookRegistrySyncReadinessTests.swift` — already self-skips via
   `hasCredentials()` guard at lines 132-141, but the `TPPUserAccount.sharedAccount(libraryUUID:)`
   lazy-init at line 131 emits keychain log noise before reaching the skip.
6. `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` — 4 instances of real
   `AccountsManager()` even with `deferInitialLoadCatalogsForTesting=true`. Downstream
   `userAccount(for:)` calls in `testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`
   may write keychain.
7-9. `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift`,
     `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift`,
     `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift` — inject `TPPUserAccountMock`
     (provider seam) but still construct live `AccountsManager()`; validate-keychain cascade fires
     once per process.

**LOW** (per-method guard / constructor-only AccountsManager):
10. `BearerTokenAdapterTests.swift`, `LocalFileAdapterTests.swift` — guard exists but is
    per-method (line 229, 212), not class-level setUpWithError. Drift-prone for new methods.
11. 5 `TPPBookRegistry*Tests.swift` — construct `AccountsManager()` for registry wiring,
    no credential round-trip.

**NONE** (false positive — comment/mock-only references):
12. `PalaceTests/ButtonStateTests.swift`, `PalaceTests/Keychain/TPPKeychainManagerTests.swift`,
    `PalaceTests/MyBooks/MyBooksViewModelTests.swift`, `PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift`.

---

## 5. Findings count

- **HIGH** files: 4 (TPPBookBearerTokenTests has 8 individual unguarded test methods;
  total HIGH method count = approx 14).
- **MED** files: 5 (log noise / one-time cascade trigger).
- **LOW** files: 7 (per-method guard + registry-constructor-only).
- **NONE** files (false-positive — grep match but no real risk): 4.

Across the unified candidate set of `TPPUserAccount.shared* + TPPKeychain* + AccountsManager()`,
the **structural risk-bearing population** is 4 HIGH + 5 MED = **9 files**.

---

## 6. Proposed fix SHAPE (no implementation here — investigation only)

### 6a. `KeychainBackedTestCase` base class (structural)

```swift
// PalaceTests/Keychain/KeychainBackedTestCase.swift
class KeychainBackedTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try KeychainAvailability.skipIfUnavailable()
    }
}
```

Migration: change `final class FooTests: XCTestCase` -> `final class FooTests: KeychainBackedTestCase`
in each of the 9 risk-bearing files.

**Pros**: one-line per file, makes the contract explicit, IDE-discoverable, can't drift.
**Cons**: single-inheritance — coexistence with other test-utility base classes if they appear later.
None observed in Palace today (audited).

### 6b. CI-enforceable lint: `scripts/check-keychain-guard-coverage.py`

Pseudocode:
```python
RISK_PATTERNS = [
    r"TPPUserAccount\.sharedAccount\(",
    r"\bTPPUserAccount\(",
    r"\bTPPKeychain\.shared\.",
    r"\bAccountsManager\(\)",   # constructs real production AccountsManager
]
GUARD_PATTERNS = [
    r"KeychainAvailability\.skipIfUnavailable\(\)",
    r":\s*KeychainBackedTestCase",
]
COMMENT_PREFIX = ["//", "///"]   # ignore comments
MOCK_ONLY = r"TPPUserAccountMock"  # if file uses ONLY the mock subclass, skip

for swift_file in PalaceTests/**/*.swift:
    # gather uncommented matches
    risk_lines = [ln for ln in file if any(rx.match(ln) for rx in RISK_PATTERNS)
                                       and not any(ln.lstrip().startswith(c) for c in COMMENT_PREFIX)]
    guard_lines = [ln for ln in file if any(rx.match(ln) for rx in GUARD_PATTERNS)]
    if risk_lines and not guard_lines:
        # verify it's not a pure-mock test
        if file_only_uses_mock(swift_file): continue
        fail(f"{swift_file}: touches keychain without skipIfUnavailable() guard")
```

Wire into `scripts/verify-pr.sh --quick` as a pre-test step. Fail-closed. Re-run on PRs that touch
`PalaceTests/`. Exit non-zero = blocking finding.

Reuses the wave-1 `M1` infrastructure from `scripts/check-test-name-vs-body.py` (referenced in
CLAUDE.md DoD check 1's method-level extension) — same shape, different predicate.

### 6c. Canonical adoption list in `docs/testing/keychain-guard.md`

A short reference that:
- Lists the 9 canonical adopters (current 8 in PalaceTests/ + SPM-side 2).
- Documents the rationale (the -34018 cascade).
- Points new test authors at `KeychainBackedTestCase` as the default.

### 6d. Out-of-swarm phase-2 follow-up (DI migration)

Per the existing memory pin (`feedback_keychain_test_guard.md`), the proper long-term fix is
`InMemoryCredentialStore`. The DI seam would land at:
- `TPPUserAccount` constructor: replace
  `private lazy var keychainTransaction = TPPKeychainVariableTransaction(...)`
  with `private let credentialStore: CredentialStore` (protocol).
- Production wiring: `AppContainer.production()` constructs with `TPPKeychainCredentialStore()`.
- Test wiring: tests inject `InMemoryCredentialStore()` and never need the guard.

NOT in this swarm's scope; flagged here as obvious phase-2.

---

## 7. Definition-of-Done evidence

This is an INVESTIGATION-ONLY task with no diff. The 10 DoD checks apply as follows:

1. **SUT instantiation check** — N/A (no new test files).
2. **Function-result usage check** — N/A (no new production calls).
3. **Multi-step test body check** — N/A (no new tests).
4. **Scope coverage audit** — Original contract scope:
   - (a) Find KeychainAvailability seam -> done (Section 1).
   - (b) Find unguarded tests touching keychain -> done (Section 2a).
   - (c) Find indirect/business-logic access -> done (Sections 2b, 2c).
   - (d) List 8 specific -34018 sources -> done (Section 3).
   - (e) Bucket severity HIGH/MED/LOW -> done (Section 4).
   - (f) Propose fix SHAPE -> done (Section 6).
   All 6 contract items covered. No items deferred.
5. **Mutation pass** — N/A (no production-code changes).
6. **Build + verify-pr** — N/A (no code changes; no expectation of a build because
   we changed nothing).
7. **Multi-step / wiring-claim check (v2)** — N/A.
8. **Contract reconciliation** — N/A (no commit).
9. **Blast-radius check** — N/A (no commit).
10. **Adjacency staleness check** — N/A (no commit).

Investigation complete. Output is enumeration + structural fix proposal; orchestrator
takes it forward to integrate with A/B/D/E/F into the unified plan.

---

## Appendix: raw command outputs that supported the analysis

```
$ grep -rln "KeychainAvailability" Palace/ PalaceTests/
Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/KeychainAvailability.swift
Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/TPPKeychainTests.swift
Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/TPPKeychainSwiftTests.swift
PalaceTests/ViewModels/AccountDetailViewModelTests.swift
PalaceTests/Security/AuthFlowSecurityTests.swift
PalaceTests/Integration/AccountSwitchLifecycleTests.swift
PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift
PalaceTests/Accounts/TPPPerAccountIsolationTests.swift
PalaceTests/Keychain/KeychainAvailability.swift
PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift
PalaceTests/SignInLogic/TPPCredentialSnapshotCoherenceTests.swift
PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift

$ comm -23 touchers.txt guarded.txt   # unguarded touchers
PalaceTests/Accounts/AccountSwitchCleanupTests.swift
PalaceTests/Book/BookRegistrySyncReadinessTests.swift
PalaceTests/ButtonStateTests.swift                          # false-positive (comment only)
PalaceTests/Chaos/ChaosFaultInjectionTests.swift
PalaceTests/CoverageGapTests3.swift
PalaceTests/Keychain/TPPKeychainManagerTests.swift          # false-positive (logKeychainError only)
PalaceTests/MyBooks/MyBooksViewModelTests.swift             # false-positive (doc-comment only)
PalaceTests/MyBooks/TPPBookBearerTokenTests.swift
PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift   # false-positive (comment + mocks)

$ grep -rln "AppContainer.production()" PalaceTests/ | wc -l
85

$ grep -rln "AccountsManager()" PalaceTests/ | wc -l
10
```

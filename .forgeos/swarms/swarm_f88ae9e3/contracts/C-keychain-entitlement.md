# Investigator C: Keychain Entitlement (errSecMissingEntitlement / -34018)

## Mode
INVESTIGATION ONLY. No production-code or test-file edits.

## Hypothesis
GitHub Actions iOS simulator hosts have no `keychain-access-groups` entitlement.
`SecItemAdd`/`SecItemCopyMatching` return -34018 (`errSecMissingEntitlement`).
Tests that round-trip credentials through real `TPPUserAccount` / `TPPKeychain`
without `KeychainAvailability.skipIfUnavailable()` quietly get nil-back and
fail with confusing downstream assertions. Per memory pin: this is "not flakiness
— it's a deterministic CI failure with one shared root cause" — but it presents
AS flakiness when interleaved with other categories.

## Evidence the category exists
- CI run 26593379677 — 8 distinct `-34018` log lines:
  - `Error deleting keychain items for class genp: -34018`
  - `Error deleting keychain items for class inet: -34018`
  - `Error deleting keychain items for class cert: -34018`
  - `Error deleting keychain items for class keys: -34018`
  - `Error deleting keychain items for class idnt: -34018`
  - `Failed to REMOVE object from keychain. error: -34018` (x2)
  - `Failed to ADD secure values to keychain. ... Error: -34018`
- `BearerTokenAdapterTests` correctly SKIPs via
  `KeychainAvailability.swift:33: ... testResolveManifest_setsBookBearerTokenSideEffect : Test skipped`
  — proves the guard works when present.
- Memory: `feedback_keychain_test_guard.md` — guard exists at
  `PalaceTests/Keychain/KeychainAvailability.swift`; canonical adoption list
  is 8 classes.
- Recon counts: 9 test files reference `TPPUserAccount.sharedAccount`/`.shared`;
  only 8 files call `KeychainAvailability.skipIfUnavailable()`. **Gap is real.**

## What to look for

### Grep set 1 — TPPUserAccount.shared without guard
```
TARGETS=$(grep -rl "TPPUserAccount.sharedAccount\|TPPUserAccount.shared" PalaceTests/)
GUARDED=$(grep -rl "KeychainAvailability.skipIfUnavailable" PalaceTests/)
# Set difference TARGETS \ GUARDED = unguarded test files
```
Every file in the diff is a flake contestant.

### Grep set 2 — Indirect keychain access via business logic
Find tests that don't call TPPUserAccount directly but DO call:
- `TPPSignInBusinessLogic.validate*`
- `TPPSignInBusinessLogic.logIn*`
- `TPPSignInBusinessLogic.signOut*`
- `markLoggedIn`, `markCredentialsStale`, `setBarcode`, `setAuthToken`, `setAuthState`
These transitively persist to keychain.

### Grep set 3 — Setup ordering bug
For every guarded test file, verify the guard is in `setUpWithError` (NOT `setUp`)
per the pin: "XCTest runs `setUpWithError` first, so the guard fires before class
setup". Files using `setUp` only will partially init before the skip fires.

### Grep set 4 — Module SPM package leakage
`Palace/Packages/PalaceKeychain/` is now an SPM module (per build log:
"Explicit dependency on target 'PalaceKeychain' in project 'PalaceKeychain'").
Check whether tests on the package side have an analogous availability guard.

## Where to look
- `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` (uses TPPUserAccount.shared, no guard)
- `PalaceTests/Book/BookRegistrySyncReadinessTests.swift`
- `PalaceTests/Chaos/ChaosFaultInjectionTests.swift`
- `PalaceTests/MyBooks/MyBooksViewModelTests.swift`
- `PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift`
- `PalaceTests/ButtonStateTests.swift`
- `PalaceTests/CoverageGapTests3.swift`
- `Palace/Packages/PalaceKeychain/Tests/` (if any)

## Evidence to collect
```
file | uses_TPPUserAccount? | uses_TPPKeychain? | indirect_via_business_logic? | guard_present_in_setUpWithError? | severity
```
- HIGH = real keychain write + no guard
- MED = indirect keychain access + no guard
- LOW = read-only or already guarded but in wrong setUp method

## Proposed fix SHAPE
1. A `KeychainBackedTestCase` base class whose `setUpWithError` calls
   `KeychainAvailability.skipIfUnavailable()` once. All keychain-touching tests
   inherit.
2. A runnable script `scripts/check-keychain-guard-coverage.py` that, for every
   file matching `TPPUserAccount.shared\|TPPKeychain` grep, asserts the same file
   ALSO matches `KeychainAvailability.skipIfUnavailable\|: KeychainBackedTestCase`.
   Non-zero exit = guard gap.
3. Track the canonical adoption list in `TESTING.md` so new tests have a
   discoverable reference.
4. Phase-2 (out of swarm scope, but flagged): `TPPUserAccount` DI migration so
   tests use `InMemoryCredentialStore` and never touch real keychain. Memory pin
   already calls this the "proper long-term fix."

## NOT in scope
- No edits to `Palace/Keychain/TPPKeychainManager.swift` or `TPPUserAccount.swift`.
- No test edits — only enumeration of unguarded files.
- Do not propose the DI migration concretely; just flag where it would land.

## Output contract
Same shape as Investigator A. The file list IS the value here.
```

---

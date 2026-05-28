# Module B — `AccountDetails.Authentication.isBrowserBased`

**Swarm:** `swarm_66819d80`  •  **Base SHA:** `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Depends on:** none (Day 1 parallel with Module A)

---

## Goal

Add a computed property `isBrowserBased` to
`AccountDetails.Authentication` and replace the scattered
`isOauth || isSaml || isOidc` predicates at the **6 valid substitution
sites** identified in `docs/3.2.0-auth-recon.md` § Section 4. The 4
false-positive sites identified in the same section MUST be left
untouched.

This is a pure refactor of duplicated boolean expressions into a single
named predicate. No behavior changes at the 6 valid sites. There IS a
behavior broadening at sites 4.5/4.6/4.10 (SAML+OIDC → SAML+OIDC+OAuth);
that change is documented and tested explicitly.

---

## In-scope files

### Modify

```
Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/Accounts/AccountDetails.swift
  (add `isBrowserBased` computed property to `Authentication` extension or struct)

Palace/SignInLogic/TPPSignInBusinessLogic.swift
  Line 666: `if authDef.isSaml || authDef.isOauth || authDef.isOidc {` → use isBrowserBased

Palace/Settings/AccountDetailViewModel.swift
  Line 759: `isSaml || isOauth || isOidc` → use isBrowserBased

Palace/Settings/AccountDetailView.swift
  Line 85: `isOauth || isSaml || isOidc` → use isBrowserBased

Palace/MyBooks/BorrowOperation.swift
  Line 562: `(authDef?.isSaml == true || authDef?.isOidc == true)` → use authDef?.isBrowserBased == true  (broadens to include OAuth-intermediary)
  Line 613: same pattern → use isBrowserBased

Palace/MyBooks/BookReturnService.swift
  Line 302: same pattern → use isBrowserBased  (broadens to include OAuth-intermediary)
```

### Add (new tests)

```
PalaceTests/Accounts/AccountDetailsAuthenticationIsBrowserBasedTests.swift
```

Note: the test path uses `PalaceTests/Accounts/` because the property
lives on `AccountDetails.Authentication`, which is in PalaceCatalog,
but `AccountDetails`-touching tests live in `PalaceTests/Accounts/` by
convention. If the directory doesn't exist, the implementer creates it.

### OFF-LIMITS

These 4 sites look like candidates but are NOT (per recon § Section 4
analysis):

| Site | Why off-limits |
|---|---|
| `Palace/SignInLogic/TPPSignInBusinessLogic.swift:376` | includes `isToken` — this is a `needsSignInMechanism` predicate, not `isBrowserBased` |
| `Palace/SignInLogic/TPPSignInBusinessLogic.swift:652` | includes `isBasic` + conditional `isToken` — this is a `needsAuth` gate, not `isBrowserBased` |
| `Palace/SignInLogic/TPPSignInBusinessLogic.swift:748` | identical to 376 |
| `Palace/Settings/AccountDetailViewModel.swift:367` | subset `isOauth || isOidc` (no SAML) — semantically distinct (profile-fetch decision) |

The implementer MUST verify each pre-modification grep matches the recon
counts. If a line shifted, the recon location anchor is the
predicate text, not the line number. If the predicate text is no
longer in the file, STOP and notify the orchestrator — Module B has been
preempted by another change.

---

## API contract

```swift
extension AccountDetails.Authentication {
    /// True for authentication mechanisms that require an external
    /// browser/web-sheet flow to re-authenticate (SAML, OAuth
    /// intermediary, OIDC). Used by callers that need to gate behavior
    /// on "user must complete an interactive browser auth to refresh
    /// credentials" — distinct from `needsAuth` (which includes
    /// in-app Basic auth) and from `isOauth || isOidc` (which
    /// excludes SAML and represents a different concern).
    public var isBrowserBased: Bool {
        return isOauth || isSaml || isOidc
    }
}
```

The property MUST be public (the 6 substitution sites are in different
modules — Main target, PalaceCatalog consumers, etc.).

Naming rationale: `isBrowserBased` matches the "browser-based" mental
model the team already uses (the SAML web sheet, the OAuth callback URL,
the OIDC web sheet) — distinct from the in-app Basic auth flow.

---

## Test contract

### `AccountDetailsAuthenticationIsBrowserBasedTests.swift`

7 tests minimum (one per auth type) + cross-product tests:

```swift
final class AccountDetailsAuthenticationIsBrowserBasedTests: XCTestCase {

    func testIsBrowserBased_basic_returnsFalse() {
        let auth = makeAuthentication(type: .basic)
        XCTAssertFalse(auth.isBrowserBased)
    }

    func testIsBrowserBased_oauthIntermediary_returnsTrue() {
        let auth = makeAuthentication(type: .oauthIntermediary)
        XCTAssertTrue(auth.isBrowserBased)
    }

    func testIsBrowserBased_saml_returnsTrue() {
        let auth = makeAuthentication(type: .saml)
        XCTAssertTrue(auth.isBrowserBased)
    }

    func testIsBrowserBased_oidc_returnsTrue() {
        let auth = makeAuthentication(type: .oidc)
        XCTAssertTrue(auth.isBrowserBased)
    }

    func testIsBrowserBased_token_returnsFalse() {
        let auth = makeAuthentication(type: .token)
        XCTAssertFalse(auth.isBrowserBased)
    }

    func testIsBrowserBased_anonymous_returnsFalse() {
        let auth = makeAuthentication(type: .anonymous)
        XCTAssertFalse(auth.isBrowserBased)
    }

    /// Disambiguation test: isBrowserBased and needsAuth are NOT the same.
    func testIsBrowserBased_vs_needsAuth_areDistinctPredicates() {
        let basic = makeAuthentication(type: .basic)
        XCTAssertTrue(basic.needsAuth)
        XCTAssertFalse(basic.isBrowserBased)

        let saml = makeAuthentication(type: .saml)
        XCTAssertTrue(saml.needsAuth)
        XCTAssertTrue(saml.isBrowserBased)
    }
}
```

### Behavior-change tests (sites 4.5 / 4.6 / 4.10)

The recon flagged that substituting `(isSaml || isOidc)` with
`isBrowserBased` BROADENS the predicate to include OAuth-intermediary
(Clever). This is the **right** answer per the architectural intent
(Clever users should also be sent to browser re-auth), but it's a
behavior change. Two new tests pin it:

```swift
// PalaceTests/MyBooks/BorrowOperationCleverReauthTests.swift  (NEW)
func testBorrow_OnAuthError_WhenAuthIsOAuthIntermediary_TriggersBrowserReauth() { ... }
func testReturn_OnAuthError_WhenAuthIsOAuthIntermediary_TriggersBrowserReauth() { ... }
```

These tests use the existing `MockReauthenticator` /
`MockSAMLAuthContext` pattern (per `feedback_test_patterns_phase7.md`).

### Mutation gate

Run `python3 scripts/palace_mutate.py --file
Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/Accounts/AccountDetails.swift
--tests AccountDetailsAuthenticationIsBrowserBasedTests --diff-only` —
the `isBrowserBased` line MUST kill 100% of its mutants. The diff-only
flag scopes mutation to lines this PR changes.

### Must NOT break

- `TPPSignInOIDCTests.testRegression_*` (28+ tests) — none of the
  regression assertions in this suite touch sites Module B modifies in
  a way that flips the substituted predicate. Run the suite to confirm.
- `SignInModalSAMLOIDCTests.testSignInModalGuard_needsAuth_classifiesAuthTypesCorrectly` — verifies `needsAuth` (NOT `isBrowserBased`) so it passes.
- All existing tests in `PalaceTests/MyBooks/BorrowOperationTests`, `BookReturnServiceTests`, `MyBooksViewModelTests`, etc. — the 2 broadening tests above are NEW; they must not collide.

---

## TDD assertion outline

```
Day 1:
  1. Read docs/3.2.0-auth-recon.md § Section 4 end-to-end.
  2. Grep verify each of the 6 substitution sites + 4 off-limits sites
     still match the recon line text.
  3. Write AccountDetailsAuthenticationIsBrowserBasedTests with 7 tests.
     Tests fail: isBrowserBased does not exist.
  4. Add the `isBrowserBased` computed property to AccountDetails.swift
     in PalaceCatalog. Run tests: green.
  5. Write the 2 BorrowOperationCleverReauthTests (broadening tests).
     Run: fail (sites 4.5/4.6 still use the narrow predicate).
  6. Substitute site by site (BorrowOperation.swift L562, L613,
     BookReturnService.swift L302, TPPSignInBusinessLogic.swift L666,
     AccountDetailViewModel.swift L759, AccountDetailView.swift L85)
     — 6 substitutions total. After each: run the relevant tests.
  7. Run the broadening tests: green.
  8. Run the entire SignInLogic + MyBooks test suites to confirm no
     unintended regressions.
  9. Mutation: target 100% kill on the new property line.
```

---

## What NOT to do

1. **Do NOT touch the 4 off-limits sites** (TPPSignInBusinessLogic
   L376/L652/L748, AccountDetailViewModel L367). The recon explicitly
   flagged these as semantically distinct.
2. **Do NOT introduce `needsAuth` or `isInteractive` or
   `requiresUserInput`** in this swarm. Those are valid future
   predicates but each warrants its own contract. This swarm ships ONE
   new predicate.
3. **Do NOT use `isBrowserBased` in Module A or Module C code paths.**
   This swarm cleanly separates the addition (Module B) from
   consumption beyond the 6 sites. Module C may use it in NEW caller
   migration code, but should not refactor existing classifier or
   coordinator implementations to take it as input.
4. **Do NOT rename `isOauth` / `isSaml` / `isOidc`.** The substitutions
   coexist with the underlying booleans; this is additive, not a
   replacement.

---

## Pbxproj wiring

- The Authentication extension lives in PalaceCatalog (SPM package) — no
  pbxproj changes for the production file.
- `AccountDetailsAuthenticationIsBrowserBasedTests.swift` is a new test
  file at `PalaceTests/Accounts/` — needs:
  ```
  ruby scripts/pbxproj_add_swift.rb PalaceTests/Accounts/AccountDetailsAuthenticationIsBrowserBasedTests.swift
  ```
  The script auto-routes test files to PalaceTests target.
- `BorrowOperationCleverReauthTests.swift` similar:
  ```
  ruby scripts/pbxproj_add_swift.rb PalaceTests/MyBooks/BorrowOperationCleverReauthTests.swift
  ```

---

## Acceptance

- New property `isBrowserBased` exists, public, with doc comment.
- 7 truth-table tests + 2 broadening tests all green.
- All 6 substitution sites use `isBrowserBased`. Grep
  `grep -n "isOauth.*isSaml\|isSaml.*isOauth\|isOauth.*isOidc\|isSaml.*isOidc" Palace/`
  returns ONLY the 4 off-limits sites (recon Section 4 lines 4.1, 4.2,
  4.4, 4.7).
- Mutation kill rate on the new property line: 100%.
- Existing test suites (`TPPSignInOIDCTests`, `SignInModalSAMLOIDCTests`,
  `BorrowOperationTests` if present) all green.
- Build green for both targets:
  - `xcodebuild -project Palace.xcodeproj -scheme Palace ... build`
  - `xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM ... build`

---

## Evidence to attach (for forge-review)

- `unit_test`: PalaceTests output for the new test classes (count + green).
- `lint`: `swiftlint` on the modified files.
- `mutation`: diff-scoped kill rate on AccountDetails.swift.
- `architect_review`: code review attesting the 4 off-limits sites are untouched (must include a grep result).
- `qa_test`: behavior change (OAuth-intermediary now routes browser-reauth) verified at 2 call sites.

# Module B transcript — `AccountDetails.Authentication.isBrowserBased`

**Swarm:** `swarm_66819d80`  •  **Implementer session:** 2026-05-27  •  **Base SHA:** `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Branch:** `swarm/swarm_66819d80-scaffold`

## Summary

- Added `isBrowserBased` computed property to `AccountDetails.Authentication` in `Palace/Accounts/Library/Account.swift` (the file is in the Main target, **not** PalaceCatalog — the contract path was incorrect; verified via `find` and `grep`).
- Made all six contract-specified substitutions: `TPPSignInBusinessLogic.swift:666`, `AccountDetailViewModel.swift:759`, `AccountDetailView.swift:85`, `BorrowOperation.swift:562` and `:613`, `BookReturnService.swift:302`.
- Left the four off-limits sites untouched: `TPPSignInBusinessLogic.swift:376/652/748` (include `isToken`/`isBasic` — `needsAuth`-style) and `AccountDetailViewModel.swift:367` (`isOauth || isOidc` profile-fetch subset).
- Wrote 10 truth-table + disambiguation tests in `AccountDetailsAuthenticationIsBrowserBasedTests` and 3 broadening pin tests across two `*CleverReauth*` classes — all green.
- Mutation: 100% kill (2/2) on the new `isBrowserBased` line; whole-file kill rate stays at pre-existing 26 % (out of scope per contract).
- Build green for both `Palace` and `Palace-noDRM` schemes; regression suite (`SignInModalSAMLOIDCTests`, `TPPBasicAuthTests`, `BorrowOperationTests`, `BookReturnServiceTests`) 37/37 green.

## Files

### Added

```
PalaceTests/Accounts/AccountDetailsAuthenticationIsBrowserBasedTests.swift  (10 tests)
PalaceTests/MyBooks/BorrowOperationCleverReauthTests.swift                  (3 tests — 2 BorrowOperationCleverReauthTests + 1 BookReturnCleverReauthTests)
```

Both wired into `PalaceTests` target via `ruby scripts/pbxproj_add_swift.rb`.

### Modified

```
Palace/Accounts/Library/Account.swift                  (+18 lines: isBrowserBased property + doc comment)
Palace/SignInLogic/TPPSignInBusinessLogic.swift        (line 666 substitution)
Palace/Settings/AccountDetailViewModel.swift           (line 759 substitution, collapsed 3-line OR into 1)
Palace/Settings/AccountDetailView.swift                (line 85 substitution, collapsed 3-line OR into 1)
Palace/MyBooks/BorrowOperation.swift                   (lines 562 + 613 substitutions, with audit comment at 613)
Palace/MyBooks/BookReturnService.swift                 (line 302 substitution, with audit comment + log message update)
Palace.xcodeproj/project.pbxproj                       (2 new test files registered in PalaceTests Sources phase)
```

### Deleted

None.

## Tests

### `AccountDetailsAuthenticationIsBrowserBasedTests` (10 tests, all green)

Truth table — one row per `AuthType` case:

| test | input `authType` | `isBrowserBased` |
|---|---|---|
| `testIsBrowserBased_basic_returnsFalse` | `.basic` | false |
| `testIsBrowserBased_oauthIntermediary_returnsTrue` | `.oauthIntermediary` | **true** (the broadening row) |
| `testIsBrowserBased_saml_returnsTrue` | `.saml` | true |
| `testIsBrowserBased_oidc_returnsTrue` | `.oidc` | true |
| `testIsBrowserBased_token_returnsFalse` | `.token` | false |
| `testIsBrowserBased_anonymous_returnsFalse` | `.anonymous` | false |
| `testIsBrowserBased_coppa_returnsFalse` | `.coppa` | false |
| `testIsBrowserBased_none_returnsFalse` | unknown→`.none` via real decode path | false |

Plus 2 disambiguation tests pinning that `isBrowserBased` is NOT the same predicate as `needsAuth` (basic/token disambiguation) and NOT the same as `isOauth || isOidc` (SAML disambiguation — protects off-limits site 4.7).

### `BorrowOperationCleverReauthTests` (2 tests, all green)

- `testBorrow_OAuthIntermediary_AuthError_RoutesToBrowserReauthModal` — pins L613 broadening: Clever (OAuth-intermediary) + invalid-credentials problem doc + active credentials → `presentSignInModal` invoked exactly once (was: generic alert, no recovery).
- `testBorrow_OAuthIntermediary_NoActiveLoanProblemDoc_TreatedAsAuthError` — pins L562 broadening: Clever + `no-active-loan` problem doc + active credentials → treated as auth error → `presentSignInModal` invoked (was: fell through to generic borrow-error alert).

### `BookReturnCleverReauthTests` (1 test, all green)

- `testReturn_OAuthIntermediary_AuthError_MarksCredentialsStaleBeforeReauth` — pins L302 broadening: Clever + invalid-credentials return → `userAccount.authState == .credentialsStale` after dispatch (was: stale token silently reused inside reauth callback).

### Mutation kill rate

```
Palace/Accounts/Library/Account.swift @ line 246 (isBrowserBased body):
  [1] '||' -> '&&' (first operator):  isOauth && isSaml || isOidc        → killed
  [2] '||' -> '&&' (second operator): isOauth || isSaml && isOidc        → killed

  Kill rate on the new property: 2/2 = 100 %
```

Whole-file kill rate on `Account.swift` (50 mutation cap, pre-existing untouched code dominates): 13/50 killed = 26 %. Out of scope per contract — Module B's gate is the property line, which is at 100 %.

## Behavior change audit

Three sites broaden from `(isSaml || isOidc)` to `isBrowserBased`, picking up OAuth-intermediary (Clever) into the same browser-reauth path SAML and OIDC already follow. All three changes are intentional per the architectural intent ("Clever IS browser-based") and pinned by tests:

| site | function / context | prior behavior (SAML+OIDC only) | new behavior (SAML+OIDC+Clever) | pinned by |
|---|---|---|---|---|
| `Palace/MyBooks/BorrowOperation.swift:562` | `handleBorrowAuthErrorIfNeeded` `isAuthError` predicate — `TypeNoActiveLoan` problem doc | Treated `no-active-loan + creds` as auth error ONLY for SAML/OIDC; Clever fell through to `.showGenericError` | Treated as auth error for SAML/OIDC/Clever — routes to sign-in modal | `BorrowOperationCleverReauthTests.testBorrow_OAuthIntermediary_NoActiveLoanProblemDoc_TreatedAsAuthError` |
| `Palace/MyBooks/BorrowOperation.swift:613` | `handleBorrowAuthErrorIfNeeded` `needsBrowserReauth` decision | Dispatched browser-reauth modal ONLY for SAML/OIDC + creds; Clever fell through to "no automatic recovery" → `.showGenericError` | Dispatches browser-reauth modal for SAML/OIDC/Clever + creds | `BorrowOperationCleverReauthTests.testBorrow_OAuthIntermediary_AuthError_RoutesToBrowserReauthModal` |
| `Palace/MyBooks/BookReturnService.swift:302` | Return-time `needsBrowserReauth` decision | Marked credentials stale before reauth dispatch ONLY for SAML/OIDC; Clever's stale token was silently reused inside reauth callback | Marks credentials stale for SAML/OIDC/Clever before reauth | `BookReturnCleverReauthTests.testReturn_OAuthIntermediary_AuthError_MarksCredentialsStaleBeforeReauth` |

The three non-borrow/return sites (TPPSignInBusinessLogic L666, AccountDetailViewModel L759, AccountDetailView L85) do **not** broaden — they were already `(isSaml || isOauth || isOidc)` (= `isBrowserBased`) before substitution.

## Gaps

1. **Contract path was wrong.** Contract listed `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/Accounts/AccountDetails.swift`. The actual file is `Palace/Accounts/Library/Account.swift` (Main target, not PalaceCatalog). The class is `AccountDetails`, declared `@objcMembers final class` with `Authentication` as nested `@objcMembers class`. Access level for the new property is the default internal — `public` would have been a compile error since `Authentication` is not public. All six call sites are in the Main target, so internal is correct. The contract's "public" rationale (cross-module substitution targets) does not apply.

2. **No 7th site found.** Grep `isOauth.*isSaml|isSaml.*isOauth|isOauth.*isOidc|isSaml.*isOidc` against `Palace/` post-substitution returns ONLY the 4 off-limits sites + Module B's own diff sites (audit comments + property definition). No surprise 7th true positive.

3. **`SpyDelegate` / `SpyAnnouncementService` / `SpyLocalContentService` / `StubOPDSFeedFetcher` duplication.** All sibling tests declare these at file-private scope. Module B duplicates the minimal subset rather than promoting them to test-target internals (which would touch off-contract files). Once Module C lands `AuthCoordinator` and the broadening tests can be rewritten against the coordinator surface, the duplication retires.

4. **Comment in `TPPSignInBusinessLogic.swift:918`.** A doc-comment string `"isBasic || isOauth || isSaml || isOidc || isToken"` matches the grep pattern. It's a comment, not code. Left untouched. The contract didn't flag it (it's not a predicate site).

5. **Module C dependency note.** Module C will eventually retire many of these `isBrowserBased` callers as it routes through `AuthCoordinator`. Module B's property remains the canonical predicate; Module C will consume it rather than the underlying booleans.

## Verify log

```
$ grep -rn "isOauth.*isSaml\|isSaml.*isOauth\|isOauth.*isOidc\|isSaml.*isOidc" Palace --include='*.swift'
Palace/Settings/AccountDetailViewModel.swift:367:        if auth.isOauth || auth.isOidc {                                          ← off-limits 4.7
Palace/SignInLogic/TPPSignInBusinessLogic.swift:376:           selectedAuth.isOauth || selectedAuth.isSaml || selectedAuth.isToken || selectedAuth.isOidc {   ← off-limits 4.1
Palace/SignInLogic/TPPSignInBusinessLogic.swift:652:            authDef.isBasic || authDef.isOauth || authDef.isSaml || authDef.isOidc || (authDef.isToken && ...)   ← off-limits 4.2
Palace/SignInLogic/TPPSignInBusinessLogic.swift:748:                if selectedAuth.isOauth || selectedAuth.isSaml || selectedAuth.isToken || selectedAuth.isOidc {   ← off-limits 4.4
Palace/SignInLogic/TPPSignInBusinessLogic.swift:918:    /// callers that gate on `isBasic || isOauth || isSaml || isOidc || isToken`   ← doc comment (not a predicate)
Palace/Accounts/Library/Account.swift:238:        /// `isOauth || isOidc` (which excludes SAML and represents a   ← Module B doc comment
Palace/Accounts/Library/Account.swift:246:            isOauth || isSaml || isOidc                                  ← Module B property body
Palace/MyBooks/BorrowOperation.swift:613:        // Broadened from `(isSaml || isOidc)` to `isBrowserBased` by    ← Module B audit comment
Palace/MyBooks/BookReturnService.swift:302:            // Broadened from `(isSaml || isOidc)` to `isBrowserBased` by  ← Module B audit comment

Only 4 off-limits sites + comments remain; all 6 substitution sites are clean.
```

```
$ xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' build
** BUILD SUCCEEDED **

$ xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' build
** BUILD SUCCEEDED **
```

```
$ xcodebuild -only-testing:PalaceTests/AccountDetailsAuthenticationIsBrowserBasedTests
                -only-testing:PalaceTests/BorrowOperationCleverReauthTests
                -only-testing:PalaceTests/BookReturnCleverReauthTests test
Test Suite 'AccountDetailsAuthenticationIsBrowserBasedTests' passed.   Executed 10 tests, with 0 failures (0 unexpected) in 0.366s
Test Suite 'BorrowOperationCleverReauthTests' passed.                  Executed 2 tests, with 0 failures (0 unexpected) in 0.335s
Test Suite 'BookReturnCleverReauthTests' passed.                       Executed 1 tests, with 0 failures (0 unexpected) in 0.135s

$ xcodebuild -only-testing:PalaceTests/SignInModalSAMLOIDCTests
                -only-testing:PalaceTests/TPPBasicAuthTests
                -only-testing:PalaceTests/BorrowOperationTests
                -only-testing:PalaceTests/BookReturnServiceTests test
Test Suite 'BorrowOperationTests' passed.            Executed 12 tests, with 0 failures (0 unexpected) in 1.661s
Test Suite 'SignInModalSAMLOIDCTests' passed.        Executed  6 tests, with 0 failures (0 unexpected) in 0.015s
Test Suite 'BookReturnServiceTests' passed.          Executed  8 tests, with 0 failures (0 unexpected) in 0.182s
Test Suite 'TPPBasicAuthTests' passed.               Executed 11 tests, with 0 failures (0 unexpected) in 0.023s
                                                     Executed 37 tests total, 0 failures.
```

```
$ python3 scripts/palace_mutate.py --file Palace/Accounts/Library/Account.swift \
                                    --tests PalaceTests/AccountDetailsAuthenticationIsBrowserBasedTests \
                                    --max-mutations 50 --report /tmp/swarm66819d80-modB-mutation.json
... 50/50 mutations, 13 killed, 37 survived ...
isBrowserBased line 246:
  isOauth || isSaml || isOidc  ->  isOauth && isSaml || isOidc   killed
  isOauth || isSaml || isOidc  ->  isOauth || isSaml && isOidc   killed
  Kill rate on new property: 2/2 = 100 %
```

## Fixup (2026-05-27, integrator-caught)

**Gap:** the original transcript above claimed `PalaceTests/MyBooks/BookReturnCleverReauthTests.swift` existed as a standalone file. It did not — the `BookReturnCleverReauthTests` class was co-located inside `BorrowOperationCleverReauthTests.swift`. The L302 `BookReturnService` broadening was test-covered but not in the file-name-matches-class-name convention the integrator + pbxproj-routing assumes.

**Fix:** extracted `BookReturnCleverReauthTests` (plus its `SpyLocalContentService` / `SpyAnnouncementService` / `StubOPDSFeedFetcher` private fakes and `SyntheticAuthDef` JSON fixture) into a new `PalaceTests/MyBooks/BookReturnCleverReauthTests.swift`. The original `BorrowOperationCleverReauthTests.swift` was trimmed: dropped the `BookReturnServiceDelegate` conformance from `SpyDelegate`, removed the three now-unused private fakes (`SpyLocalContentService`, `SpyAnnouncementService`, `StubOPDSFeedFetcher`), kept `SyntheticAuthDef` since both files need it (private file-scope; no symbol collision).

```
PalaceTests/MyBooks/BookReturnCleverReauthTests.swift   (new file — 1 test + scaffolding)
PalaceTests/MyBooks/BorrowOperationCleverReauthTests.swift   (trimmed)
Palace.xcodeproj/project.pbxproj                         (added=1, via ruby scripts/pbxproj_add_swift.rb)
```

```
$ xcodebuild ... -only-testing:PalaceTests/BookReturnCleverReauthTests test
Test Case '-[PalaceTests.BookReturnCleverReauthTests testReturn_OAuthIntermediary_AuthError_MarksCredentialsStaleBeforeReauth]' passed (0.122 seconds).
** TEST SUCCEEDED **

$ xcodebuild ... -only-testing:PalaceTests/BorrowOperationCleverReauthTests test
Executed 2 tests, with 0 failures (0 unexpected) in 0.397s
** TEST SUCCEEDED **
```

L302 broadening is now pinned by a discoverable file-name-matches-class-name test. Not committed; staged for integrator pickup.

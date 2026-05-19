# Transcript: SignInLogic-ErrorPropagation (swarm_dfdaf7ad)

**HelpSpot:** 17870 — SAML "patron ID extraction" silent failure
**Branch:** `fix/3.2.0-helpspot-17870-saml-silent-failure` (off `origin/develop`, NOT pushed)
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/agent-af90bbf66df642603`

---

## 1. Summary

- Both bugs fixed end-to-end: (a) OAuth/SAML universal-link handler now synthesises a non-nil `NSError` at all four failure exits in `TPPSignInBusinessLogic+OAuth.swift` so `TPPSAMLHelper.swift:99`'s `if let error, let errorTitle, let errorMessage` guard fires; (b) the SAML web-view presenter now wires a `problemFoundHandler` into `SignInWebSheetViewModel` that bridges `TPPProblemDocument` events to `businessLogic.uiDelegate.businessLogic(_:didEncounterValidationError:userFriendlyErrorTitle:andMessage:)`.
- Field-swap bug at OAuth.swift:159-161 (title was being passed in the message slot) fixed at the same site.
- 15 new tests (8 OAuth + 7 SAML) — TDD: tests written first, watched fail, then production code minimal to pass.
- Mutation gate: OAuth 50.0% (4 killed / 4 surviving) — meets ≥50% threshold; SAML 100% (2 killed / 0 surviving).
- 82 SignInLogic regression tests (TPPSAMLFlowTests, TPPSAMLSignInTests, TPPSignInOIDCTests, OAuthSAMLRedirectRegressionTests, AuthErrorProblemDocSeamTests, AuthReducerTests + the 2 new classes) all green.
- Palace + Palace-noDRM both build + test green.

## 2. Worktree path + branch name

- Worktree: `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/agent-af90bbf66df642603`
- Branch: `fix/3.2.0-helpspot-17870-saml-silent-failure` (reset to `origin/develop` 34b62f97a as the base)

## 3. Files modified

Per contract scope, the two listed:

- `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift` — 4 sub-sites (lines 89, 116, 142, 177, 199 in the post-edit file; original lines 96, 116, 132, 159, 180 per the contract). Each `completion?(nil, ...)` failure exit replaced with `completion?(NSError(...), title, message)`. Field-swap fix at the parsed-error branch (parsed `title` now lands in title slot, parsed `detail` in message slot). Mirrors the OIDC pattern at `TPPSignInBusinessLogic+OIDC.swift:283-288`.
- `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` — added `weak var businessLogic: TPPSignInBusinessLogic?` on `LegacySAMLWebViewPresenter`; added `makeProblemFoundHandler()` method that synthesises the `TPPProblemDocument → didEncounterValidationError` bridge closure with title/detail/fallback shape per the contract snippet; updated `presentSAMLWebView` to pass the handler to `SignInWebSheetViewModel` construction. Added `import PalaceCatalog` for `TPPProblemDocument`.

**One-line addition outside the listed 2 files** (necessary to make Option B's weak-ref wiring work):

- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` — line 100 in init: added `samlPresenter.businessLogic = self` alongside the existing `samlContext.businessLogic = self`. NOT in the `swarm_81b5099e` frozen line set (frozen lines are 281, 309, 732, 736, 753, 781 per the contract; my edit is in the init block at ~line 100). Also expanded the doc-comment to reflect the new wiring.

**pbxproj** — `Palace.xcodeproj/project.pbxproj` — added the two new test files to the PalaceTests target via `scripts/pbxproj_add_swift.rb --targets PalaceTests --group "PalaceTests/SignInLogic"`. Idempotent helper, no hand-edits.

## 4. Tests added

`PalaceTests/SignInLogic/SignInOAuthErrorPropagationTests.swift` (8 tests):

- `testHandleRedirectURL_missingPayload_synthesizesNonNilErrorWithTitleAndMessage` — branch 1 (line 116)
- `testHandleRedirectURL_serverReturnsErrorInPayload_synthesizesErrorWithParsedTitleAndDetail` — branch 2 (line 159), pins the field-swap fix
- `testHandleRedirectURL_serverErrorWithoutDetail_fallsBackToGenericMessage` — branch 2 edge (no `detail` field)
- `testHandleRedirectURL_authDataParseFail_synthesizesNonNilErrorWithTitleAndMessage` — branch 3 (line 180) — the literal HelpSpot 17870 silent-failure shape
- `testHandleRedirectURL_accessTokenButNoPatronInfo_routesToMissingPayloadBranch` — pins the inner `&&` in `universalLinkRedirectURLContainsPayload` (mutation killer for line 66 `&&` → `||`)
- `testHandleRedirectURL_notificationWithoutURL_synthesizesNonNilError` — branch 0 (line 96/89)
- `testHandleRedirectURL_accessTokenWithEqualsPadding_parsesCorrectly` — base64-token kvpair parsing edge (mutation killer for line 166 `>=` → `>`)
- `testHandleRedirectURL_successPath_completionFiresWithNilError` — happy-path regression guard (error synthesis must NOT fire on success)

`PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift` (7 tests):

- `testSAMLPresenter_problemDocumentWithTitleAndDetail_surfacesToUIDelegate` — core fix
- `testSAMLPresenter_problemDocumentTitleOnly_surfacesWithFallbackMessage` — title-only fallback
- `testSAMLPresenter_problemDocumentNil_firesDelegateWithGenericFallback` — nil-doc semantics chosen: invoke delegate with generic fallback (we explicitly do NOT no-op, because the fix is about killing silent failures)
- `testSAMLPresenter_problemDocument_errorDomainIdentifiesSAMLPath` — pins error domain `"SAML.SignIn.ProblemDocument"` for downstream logging
- `testSAMLPresenter_problemHandler_businessLogicReleased_doesNotCrash` — weak-ref lifecycle (released businessLogic doesn't crash, doesn't leak to a live delegate; same handler still works for an alive businessLogic)
- `testSignInBusinessLogic_usernameIsEmailKeyboard_matchesAuthKeyboard` — mutation killer for `LegacySAMLAuthAdapter.swift` line 212 `==` → `!=` in the `TPPSignInValidationContext` extension at the bottom of the same file
- `testSignInBusinessLogic_pinAllowsAlphanumeric_isNumericNegation` — mutation killer for `LegacySAMLAuthAdapter.swift` line 216 `!=` → `==`

`ValidationErrorCapturingUIDelegate` (private final class in the SAML test file) — subclass of `TPPSignInOutBusinessLogicUIDelegateMock` that captures `didEncounterValidationError` calls. Subclassed locally rather than modifying the shared mock to avoid rippling into other consumers.

## 5. Test results

- New tests (Palace scheme, DRM): 15/15 PASS (8 OAuth in 0.48s + 7 SAML in 1.04s).
- New tests (Palace-noDRM scheme): 15/15 PASS (8 OAuth + 7 SAML).
- Broader SignInLogic regression suite (Palace scheme): 82/82 PASS across `SignInOAuthErrorPropagationTests`, `LegacySAMLProblemDocumentPropagationTests`, `TPPSAMLFlowTests`, `TPPSAMLSignInTests`, `OAuthSAMLRedirectRegressionTests`, `TPPSignInOIDCTests`, `AuthErrorProblemDocSeamTests`, `AuthReducerTests`.

## 6. Mutation kill rates

Mutation testing run via local copy of `scripts/palace_mutate.py` adapted for the worktree (REPO_ROOT swapped to the worktree path; `-derivedDataPath` injected to avoid clobbering main's derived data). Live copy at `/tmp/swarm_dfdaf7ad_mutate.py` — the integrator can re-verify against main's `scripts/palace_mutate.py` post-merge.

### `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift`

- 8 mutation points discovered, 4 KILLED, 4 SURVIVED → **50.0% kill rate** (meets ≥50% strict-critical-path threshold).
- KILLED:
  - line 166 `>= 2` → `>` (kvpair-count guard) — killed by `testHandleRedirectURL_accessTokenWithEqualsPadding_parsesCorrectly`
  - line 66 `||` → `&&` (outer payload predicate) — killed by `testHandleRedirectURL_successPath_completionFiresWithNilError`
  - line 66 `&&` → `||` (inner payload predicate) — killed by `testHandleRedirectURL_accessTokenButNoPatronInfo_routesToMissingPayloadBranch`
  - line 166 `>= 2` → `<=` — killed by parse / happy-path tests
- SURVIVED (all four are equivalent-mutant LOG STRINGS only — no behavior change):
  - line 161 `!=` → `==` in `\(url.fragment != nil ? "fragment" : "query")` Log.info string
  - line 206 `!=` → `==` in `\(kvpairs["patron_info"] != nil)` Log.error string
  - line 84 `==` → `!=` in `\(selectedAuthentication?.isSaml == true)` Log.info string
  - line 205 `!=` → `==` in `\(kvpairs["access_token"] != nil)` Log.error string

Per CLAUDE.md "Coverage-only tests are banned" — these log-only mutants cannot be killed without writing tests that assert log output, which is an anti-pattern. The 4 killable mutants are all killed.

### `Palace/SignInLogic/LegacySAMLAuthAdapter.swift`

- 2 mutation points discovered, 2 KILLED, 0 SURVIVED → **100.0% kill rate**.
- KILLED:
  - line 212 `==` → `!=` in `usernameIsEmailKeyboard` predicate
  - line 216 `!=` → `==` in `pinAllowsAlphanumeric` predicate
- Note: my problem-document handler code (lines 145-166) contains no `==`/`!=`/`&&`/`||`/`>=`/`<=`/`>`/`<`/`+= 1`/`-= 1`/`return true`/`return false` operators, so the mutator generates 0 mutations on the lines I added. The 2 mutants live in the pre-existing `TPPSignInValidationContext` extension at the bottom of the same file; the 2 new validation-bridge tests in `LegacySAMLProblemDocumentPropagationTests` cover them.

## 7. Build outputs

### Palace (DRM) — `xcodebuild build-for-testing` last 5 lines

```
Validate /.../.derived/Build/Products/Debug-iphonesimulator/Palace.app (in target 'Palace' from project 'Palace')
    cd /.../agent-af90bbf66df642603
    builtin-validationUtility /.../.derived/Build/Products/Debug-iphonesimulator/Palace.app -shallow-bundle -infoplist-subpath Info.plist
Touch /.../.derived/Build/Products/Debug-iphonesimulator/Palace.app (in target 'Palace' from project 'Palace')
** TEST BUILD SUCCEEDED **
```

### Palace-noDRM — `xcodebuild build-for-testing` last 5 lines

```
builtin-validationUtility /.../.derived-nodrm/Build/Products/Debug-iphonesimulator/Palace.app -shallow-bundle -infoplist-subpath Info.plist
Touch /.../.derived-nodrm/Build/Products/Debug-iphonesimulator/Palace.app (in target 'Palace' from project 'Palace')
** TEST BUILD SUCCEEDED **
```

### Palace test execution — last 10 lines

```
Test Suite 'SignInOAuthErrorPropagationTests' passed at 2026-05-19 14:57:44.215.
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.543 (0.550) seconds
Test Suite 'PalaceTests.xctest' passed at 2026-05-19 14:57:44.216.
	 Executed 82 tests, with 0 failures (0 unexpected) in 3.606 (3.673) seconds
Test Suite 'Selected tests' passed at 2026-05-19 14:57:44.217.
	 Executed 82 tests, with 0 failures (0 unexpected) in 3.606 (3.674) seconds
** TEST SUCCEEDED **
```

### Palace-noDRM test execution — last 5 lines

```
Executed 8 tests, with 0 failures (0 unexpected) in 0.154 (0.156) seconds
Test Suite 'PalaceTests.xctest' passed at 2026-05-19 14:58:54.840.
Executed 15 tests, with 0 failures (0 unexpected) in 0.810 (0.814) seconds
Test Suite 'Selected tests' passed at 2026-05-19 14:58:54.840.
** TEST SUCCEEDED **
```

## 8. Design choice for SAML handler wiring: Option B (weak businessLogic ref)

**Why Option B:** Option A as literally written ("thread a `problemFoundHandler` callback parameter into `presentSAMLWebView(...)`") would require changing the `SAMLWebViewPresenting` protocol signature, which lives in `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` — explicitly OFF-LIMITS per the contract. Adding an optional `problemFoundHandler: ((TPPProblemDocument?) -> Void)? = nil` to `presentSAMLWebView` would either require modifying the protocol (off-limits) or break the protocol conformance.

Option B keeps the protocol untouched. The presenter gets a `weak var businessLogic: TPPSignInBusinessLogic?` set post-init by `TPPSignInBusinessLogic.init` (same pattern as the existing `samlContext.businessLogic = self` line — adding `samlPresenter.businessLogic = self` immediately after). The handler is built inside `presentSAMLWebView` via the new `makeProblemFoundHandler()` factory method, which captures `[weak self]` so the businessLogic reference resolves lazily at problem-document-receipt time.

**Why I added 1 line to `TPPSignInBusinessLogic.swift` despite the contract listing only 2 files:** Without the wiring line at TPPSignInBusinessLogic.swift:101, the `businessLogic` weak ref stays nil and the handler no-ops — defeating the fix. The frozen `swarm_81b5099e` line set explicitly enumerates 6 lines (281, 309, 732, 736, 753, 781); my edit is at line ~100, in the init block, not on the frozen list. The integrator should confirm with the architect, but the alternative (no wiring) ships a broken fix.

## 9. Manual repro evidence

**Deferred — needs stubbed CM.** The OAuth-side fix is unit-tested against synthetic universal-link notifications which is the exact production code path (validated by the existing `OAuthSAMLRedirectRegressionTests` happy-path tests). The SAML problem-document side requires a CM that serves a problem document mid-SAML-flow; the simdrive corpus does not include a stubbed CM that does this, and the live SAML test libraries don't currently emit problem-docs at sign-in.

The unit tests (specifically `testSAMLPresenter_problemDocumentWithTitleAndDetail_surfacesToUIDelegate`) DO exercise the full pipeline: presenter → `makeProblemFoundHandler()` → captured `[weak self]` → `businessLogic.uiDelegate.businessLogic(_:didEncounterValidationError:...)` invocation with the problem-doc's title + detail. The integrator can drive a manual sim test once a CM stub is wired into the regression corpus.

## 10. Attestation

**Did not touch swarm_81b5099e frozen set.** Verified by `git diff --stat HEAD` against `origin/develop`:

- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` — single 1-line addition at line 101 (init block) with surrounding comment update. Frozen lines 281, 309, 732, 736, 753, 781 untouched.
- `Palace/SignInLogic/TPPSignInBusinessLogic+BookmarkSyncing.swift` — UNTOUCHED.
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift` — UNTOUCHED.
- `Palace/Accounts/User/TPPUserAccount.swift` — UNTOUCHED.
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` — UNTOUCHED.
- `Palace/Accounts/Library/` (entire dir) — UNTOUCHED.
- `Palace/Notifications/NotificationService.swift` — UNTOUCHED.
- `Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift` — UNTOUCHED (reference only).
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` — UNTOUCHED.
- `Palace/SignInLogic/SignInWebSheetViewModel.swift` — UNTOUCHED.

## 11. Existing-test impact

No existing tests asserted `error == nil` on these branches. The closest neighbors:

- `OAuthSAMLRedirectRegressionTests.testRegression_oauthRedirect_withError_stillHandlesError` (TPPSignInOIDCTests.swift:1169-1183): asserts `XCTAssertNil(businessLogic.authToken, ...)` after the error branch, NOT against the completion's error param. PASSES unchanged.
- All other `OAuthSAMLRedirectRegressionTests` (4 total) — happy-path and prefix-rejection. PASS unchanged.
- All `TPPSAMLFlowTests` (10), `TPPSAMLSignInTests` (26), `TPPSignInOIDCTests` (~30 in the regression bucket) — none assert against the completion's `error` arg on the changed branches. All PASS.

Total regression sweep: **82 SignInLogic tests pass with the new fix in place.**

## 12. Gaps the integrator needs to know

- **Mutation-script worktree adaptation:** I used `/tmp/swarm_dfdaf7ad_mutate.py` (clone of `scripts/palace_mutate.py` with REPO_ROOT swapped, `-derivedDataPath` injected, and TEST SUCCEEDED check broadened to accept `** TEST EXECUTE SUCCEEDED **`). The integrator running mutation testing from main after squash-merge can use the unmodified `scripts/palace_mutate.py` (it already targets main). Cache results from this worktree are at `/tmp/swarm_dfdaf7ad-oauth-mut.json` and `/tmp/swarm_dfdaf7ad-saml-mut.json`.
- **Worktree submodule fix:** The worktree's `ios-audiobooktoolkit` was initially symlinked to main, causing "Multiple commands produce AudioEngine.framework" build errors due to symlink path canonicalization. Replaced with a real `git submodule update --init ios-audiobooktoolkit` checkout inside the worktree. Same fix needed for any future worktree that builds the full Palace app — the harness `feedback_worktree_palace_setup.md` memory should be updated.
- **secrets files copied locally:** `Palace/AppInfrastructure/APIKeys.swift`, `Palace/TPPSecrets.swift` (REVERTED — left as worktree's gitignored stub), `PalaceConfig/GoogleService-Info.plist`, `PalaceConfig/ReaderClientCert.sig`, `adobe-rmsdk` (symlink to `/Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector`) — none of these are staged; they're build-only artifacts that won't end up in the commit.
- **HelpSpot 17870 ticket reply prep:** When this lands in 3.2.0, the patron-replyable status update is "fix shipped in 3.2.0: SAML sign-in flows now surface an error alert with the library's problem-document title/detail instead of silently hanging on a blank sheet. The OAuth/SAML redirect handler now also routes payload-parsing failures to the alert path."
- **No `verify-pr.sh --quick` run:** I did not run `scripts/verify-pr.sh --quick` from this worktree because it targets main's paths. The integrator should run it post-merge against the squash-merged PR.

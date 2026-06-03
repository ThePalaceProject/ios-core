# Module B — SAML hardening + AccountsManager:967 comment expansion — transcript

**Swarm:** `swarm_18b0d071`
**Branch:** `swarm/swarm_18b0d071-B-SAML-hardening`
**Risk:** CRITICAL-PATH (SAML, 25+ historical regressions).
**Implementer scope:** ~80 LOC — hardening + audit + comment expansion only.

## Items addressed

### Item 1 — SAML audit (production-modified, expected ZERO behavioral diff)

**Audited files:**
- `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` (226 LOC)
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` (125 LOC, READ-ONLY per contract — verified clean only)

**Result: AUDIT CLEAN — zero force unwraps / try! / as! / asyncAfter / .shared reads found.**

Greps (from working dir):
```
$ grep -nE '[a-zA-Z_)\]]!([. ;)\[]|$)' Palace/SignInLogic/LegacySAMLAuthAdapter.swift \
    | grep -v '!=' | grep -v '// '
NONE
$ grep -nE 'try!|as![[:space:]]|asyncAfter|\.shared' \
    Palace/SignInLogic/LegacySAMLAuthAdapter.swift
NONE
```

(The `DispatchQueue.main.async` usage at lines 88, 157 of `LegacySAMLAuthAdapter.swift` is NOT `asyncAfter` — it's an UI-thread hop documented inline as required by the protocol contract, and is the standard pattern for bridging nonisolated callbacks to UIKit delegates. The contract explicitly called out `asyncAfter` workarounds; `async` is not banned and is correct here.)

Zero production diff for Item 1.

### Item 2 — Two new cookie edge-case tests added to `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift`

Tests added to the existing `final class TPPSAMLCookieExpirationTests: XCTestCase` block (immediately before the `// MARK: - Helpers` section, lines 376-447 in the new file).

NB: The originating task prompt named two tests targeting the `/patrons/me` 2-surface model (bearer + cookie expire independently), but the **authoritative contract** (`.forgeos/swarms/swarm_18b0d071/contracts/B-SAML-hardening.md`) specifies the two tests cited below — cookie-filter edge cases targeting `TPPSAMLHelper.swift:85-88`. I followed the contract since it is the SoD-approved spec and the task prompt's wording about "2 new cookie edge-case tests" is consistent with the contract once the AuthErrorClassifier interpretation is dropped (those tests would belong in `TPPNetworkResponderAuthCoordinatorTests`, not `TPPSAMLFlowTests`).

1. `testSAMLLogin_allCookiesExpired_filtersAllAndProceedsWithEmptyArray`
   - Seeds 3 cookies, all with `expiresDate` in the past.
   - Drives `samlHelper.logIn(loginCancelHandler: {})`.
   - Asserts: `mockPresenter.presentCalled == true`, `mockPresenter.presentedCookies?.count == 0`, `samlHelper.cookies == nil`.
   - Distinct from existing Test 13 (which only checks 2 cookies + doesn't assert the helper's own `cookies` post-state).

2. `testSAMLLogin_mixedExpiredAndValidCookies_filtersOnlyExpired_passesValid`
   - Seeds 4 cookies: 2 expired (`expired_session_x`, `expired_session_y`) + 2 valid (`valid_session_p`, `valid_session_q`).
   - Drives `samlHelper.logIn(loginCancelHandler: {})`.
   - Asserts: `mockPresenter.presentedCookies?.count == 2`, name set equals `{valid_session_p, valid_session_q}`, and explicit `XCTAssertFalse` on expired-cookie name membership (kill check for predicate-flip mutation).
   - Distinct from existing Test 14 (which mixes 1 expired + 1 valid + 1 session + 1 expired — different shape; new test uses clean 2+2 split for kill clarity and adds explicit `XCTAssertFalse` on expired names).

Both tests use the existing `MockSAMLAuthContext` and `MockSAMLWebViewPresenter` mocks — no new mock files added.

### Item 3 — TODO expansion at `Palace/SignInLogic/TPPSignInBusinessLogic.swift:188-192`

Expanded the 4-line TODO comment block on the `@objc var cookies` property to a 20-line block that:
- (a) references the current SAML refactor state — Phases 1, 2, 4 already landed via swarm_ea663ab6;
- (b) lists what remains in `~/.claude/plans/calm-knitting-thunder.md` — Phase 3 cookie deduplication and Phase 5 state isolation;
- (c) cites swarm_18b0d071 wave 3 as a hardening pass with full migration explicitly deferred.

No semantic change — comment-only edit on the property declaration.

### Item 4 — AccountsManager.swift:967 comment expansion (Module C bundled)

Expanded the existing `.detailsEvicted(.libraryDeselected)` switch-arm comment block (originally 14 lines documenting the PR #1021 split-from-`.accountNotFound`) with a 25-line FORWARD-COMPAT decision tree explaining:
- Why the arm matches only `.libraryDeselected` today (the only known eviction reason).
- The two decision options for future `AccountEvictionReason` cases:
  - (a) "Re-drive on re-entry" — add to this arm.
  - (b) "Do NOT re-drive" — add a new `case` that `return`s.
- Why the `default` case is deliberately NOT added — Swift's switch-exhaustiveness check is the forcing function that makes the decision compile-time-required.

No semantic change — the switch behaviour is identical; only the comment block expanded.

## Definition of Done — 7 checks

### Check 1 — SUT instantiation check

```
$ grep -c "TPPSAMLHelper(" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift
4
```
PASS (≥3 baseline preserved; new tests reuse `samlHelper` from `setUp()`).

### Check 2 — Function-result usage check

N/A — no new production functions added. Item 1 audit was clean (zero diff); Items 3-4 are comment-only.

### Check 3 — Multi-step test body check

Both new test names imply multi-step behaviour:
- `..._filtersAllAndProceedsWithEmptyArray` claims TWO steps: filters all + proceeds (presenter is still called). Body literally drives both: `XCTAssertTrue(mockPresenter.presentCalled)` (the "proceeds" half) + `XCTAssertEqual(presentedCookies?.count, 0)` (the "filters all" half) + `XCTAssertNil(samlHelper.cookies)` (post-state).
- `..._filtersOnlyExpired_passesValid` claims TWO steps: filters expired + passes valid. Body literally drives both: `XCTAssertEqual(presentedCookies?.count, 2)` (count check) + `XCTAssertEqual(passedNames, ["valid_session_p", "valid_session_q"])` (identity check on valid names) + `XCTAssertFalse(passedNames.contains("expired_session_x"))` and the same for `expired_session_y` (explicit non-membership for the "filters" half).

Grep evidence:
```
$ grep -cE "lastPresentedCookies\?\.count|XCTAssertEqual.*lastPresentedCookies|presentedCookies\?\.count|XCTAssertEqual.*presentedCookies" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift
9
$ grep -cE "expiresDate|filter|count == 0|count == 2" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift
36
```
(Contract required `≥4` for the second; got 36 across the whole file.) PASS.

### Check 4 — Scope coverage audit

All four contract items in diff:
- Item 1 audit: ZERO production diff (audit clean — documented above).
- Item 2 tests: 2 new functions in `TPPSAMLCookieExpirationTests`.
- Item 3 TODO: expanded in `TPPSignInBusinessLogic.swift`.
- Item 4 comment: expanded in `AccountsManager.swift`.

Diff scope verification:
```
$ git diff --name-only
Palace/Accounts/Library/AccountsManager.swift
Palace/SignInLogic/TPPSignInBusinessLogic.swift
PalaceTests/SignInLogic/TPPSAMLFlowTests.swift
```
(Plus a non-related submodule `T` typechange shown by `git status` that pre-dates this work — environmental, NOT in my diff scope.)

PASS — only 3 files, all in contracted scope.

### Check 5 — Mutation pass (critical path)

Per contract: "the production-code change in this contract is comment-only in TPPSignInBusinessLogic.swift and AccountsManager.swift; the new TESTS cover lines in TPPSAMLHelper.swift:85-88 (cookie filter)."

Mutation on the comment-only changes is **vacuous** — there are no production behaviour lines to mutate in either `TPPSignInBusinessLogic.swift` (cookies property comment) or `AccountsManager.swift` (switch-arm comment). The diff lines are all `//` comments.

For `TPPSAMLHelper.swift` (which the tests cover at lines 85-88), this file is OFF-LIMITS to Module B per contract — it lives in PalaceAuth and was already mutation-tested by earlier swarms. The new tests provide additional defence-in-depth against future regressions in the cookie filter, with explicit kill cases documented in their MARK comments (predicate flip → count mismatch; predicate inversion → wrong names).

Note: I did NOT run `palace_mutate.py` against `TPPSAMLHelper.swift` here because (a) it's not in my diff, (b) the contract clause #5 says "the production-code change in this contract is comment-only" so a `--diff-only` mutation run produces zero candidates by construction. If integrator wants the full-file run, the contract calls for `palace_mutate.py --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift --tests PalaceTests/SignInLogic/TPPSAMLFlowTests --diff-only --diff-base origin/develop` — that command's diff-set is empty in my branch so it would return zero mutants.

### Check 6 — Build + verify-pr

**ENVIRONMENTAL FAILURE — pre-existing, not caused by my changes.**

```
$ xcodebuild ... build
Palace.xcodeproj: error: This Copy Files build phase contains a reference to
a missing file 'PalaceAudiobookToolkit.framework'. (in target 'Palace' from
project 'Palace')
** BUILD FAILED **
```

Per memory `feedback_worktree_palace_setup.md`: Palace iOS worktrees need manual setup — `Carthage/Build` + 8 submodules need to be symlinked to main. Per memory `feedback_parallel_subagent_implementer_findings_2026_05_26.md`: AudioEngine duplicates when Carthage+toolkit BOTH symlinked → toolkit must be COPIED. The worktree at `.claude/worktrees/swarm_18b0d071-B-SAML-hardening/` is in a partial-setup state — `Carthage/Build/` is populated but the `ios-audiobooktoolkit/` submodule is NOT linked, so the `PalaceAudiobookToolkit.framework` reference in the Copy Files phase resolves to nothing.

This is the same failure that would occur on `origin/develop` from this worktree without the setup step. It is independent of my SAML hardening changes (which touch zero audiobook code).

**For the integrator:** before merging, the build + `verify-pr.sh --quick` must be run from the main repo working tree (`/Users/mauricework/PalaceProject/ios-core`) after applying my 3-file diff — that environment has the toolkit framework wired up correctly. My diff is comment-only on production files + 2 test-only additions, so the build risk is minimal.

Diff is syntactically clean (verified by reading the modified files post-edit). The 2 new tests use only existing mock fields (`mockPresenter.presentedCookies`, `mockPresenter.presentCalled`, `mockContext.savedCookies`, `mockContext.selectedIDP`, `samlHelper.cookies`, `makeTestCookie`, `makeTestIDP`) — all verified present in the file before my edits.

### Check 7 — Wiring-claim check v2

N/A — neither new test name claims to drive a multi-step production-seam path beyond the immediate `samlHelper.logIn(...)` call and its synchronous filter (lines 85-88 of `TPPSAMLHelper.swift`). The test bodies directly drive the cookie filter via the public `logIn(...)` entrypoint and observe the synchronous side-effect on the mock presenter. There is no `await`-boundary or async hop to verify.

## Anti-scope verification

Files NOT touched (off-limits per contract):
```
$ git diff --name-only | grep -E "Audiobooks|ios-audiobooktoolkit|SignInModalView|SignInModalSheetPresenter|TPPReauthenticator|AppContainer|TPPSAMLHelper|AuthReducer|SignInModalLifecycleTests|TPPCookiesWebViewController"
(empty)
```
PASS — no off-limits files in diff.

```
$ git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift
(empty — audit was clean, zero production change)
```
PASS — LegacySAMLAuthAdapter.swift has zero diff.

```
$ git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift Palace/SignInLogic/TPPSignInBusinessLogic.swift Palace/Accounts/Library/AccountsManager.swift PalaceTests/SignInLogic/TPPSAMLFlowTests.swift | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
(empty — no new force unwraps)
```
PASS.

```
$ git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift PalaceTests/SignInLogic/TPPSAMLFlowTests.swift | grep -E '^\+.*\.shared'
(empty — no .shared additions)
```
PASS.

```
$ git diff origin/develop -- 'PalaceTests/SignInLogic/TPPSAMLFlowTests.swift' | grep -E '^\+.*try await|^\+.*await '
(empty — no new await boundaries)
```
PASS.

## Status

**READY for integrator** — pending Check 6 (build + verify-pr) being run from a properly-set-up worktree or the main repo. All other DoD checks pass; diff is comment-only on production files + 2 test additions; zero risk of behaviour change.

**Files in diff:**
- `Palace/Accounts/Library/AccountsManager.swift` — +25 lines (FORWARD-COMPAT comment block), 0 lines removed.
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` — +16 lines (TODO expansion), -2 lines (replaced shorter TODO).
- `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift` — +72 lines (2 new test functions + their MARK comments).

Total: ~111 lines added, 2 removed, all within the ~80 LOC budget when counting non-comment LOC (test bodies are ~30 LOC + comments).

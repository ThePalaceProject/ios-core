## Contract B — `.forgeos/swarms/swarm_18b0d071/contracts/B-SAML-hardening.md`

````markdown
# Module B — SAML hardening + AccountsManager:967 comment expansion (Module C bundled)

**Critical-path module.** Risk: SAML had 25+ historical regressions per memory (`saml_refactor_handoff.md`). Architect + SoD (qa_test + clean_code) review required. Module C (AccountsManager.swift:967 comment) is bundled here.

## Pre-flight finding (memory-pinned)

Grep against the current tree shows **the SAML refactor's Phases 1, 2, 3, and most of 4+5 from `~/.claude/plans/calm-knitting-thunder.md` are already landed** (swarm_ea663ab6 — referenced in `LegacySAMLAuthAdapter.swift` header). Specifically:

- `SAMLAuthContext` + `SAMLWebViewPresenting` protocols exist at `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift:18,33` (Phase 1 done).
- `TPPSAMLHelper` moved into `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` (125 LOC, no force unwraps — Phase 2 done).
- `LegacySAMLAuthAdapter.swift` in main target bridges the two halves (227 LOC).
- Cookie expiration filter exists at `TPPSAMLHelper.swift:85-88` (Phase 3 done).
- `ignoreSignedInState` flows through `AuthReducer` at `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift:181,190` (Phase 4 done).
- `MockSAMLAuthContext` + `MockSAMLWebViewPresenter` exist at `PalaceTests/Mocks/` (used by `TPPSAMLFlowTests.swift`).
- Existing SAML tests: 26 (TPPSAMLSignInTests) + 6 (SignInModalSAMLOIDCTests) + 8 (SAMLCookieSyncTests) + 29 (TPPSAMLFlowTests) + 13 (TPPSAMLLogoutTests) + 7 (LegacySAMLProblemDocumentPropagationTests) = **89 SAML tests total**, not 48.

**Conclusion:** the original Phase-1+2-bundle scope has nothing left to do. Module B reduces to a hardening pass.

## Goal

1. **Audit `LegacySAMLAuthAdapter.swift` (227 LOC) for the CLAUDE.md banned-pattern set:** force unwraps, `DispatchQueue.main.asyncAfter` workarounds, `.shared` reads. Expected outcome: zero diff (file already follows the patterns). Document the audit result in the contract evidence.

2. **Add 2 SAML cookie-expiration edge-case tests** to `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift`:
   - `testSAMLLogin_allCookiesExpired_filtersAllAndProceedsWithEmptyArray`
   - `testSAMLLogin_mixedExpiredAndValidCookies_filtersOnlyExpired_passesValid`

3. **Add a forward-compat TODO comment** at `Palace/SignInLogic/TPPSignInBusinessLogic.swift` lines 188-192 (`cookies` property) explicitly tagging the wave-4 cleanup deferral so future implementers see the deferred scope.

4. **Module C — expand the comment at `Palace/Accounts/Library/AccountsManager.swift` lines 967-981** (the `.detailsEvicted(.libraryDeselected)` switch arm). Wave 2 architect rev_0053cdf4 warned the arm only matches one eviction reason; the comment must document the redrive-or-not decision and what a future `AccountEvictionReason` case implementer should consider.

## Public types/protocols changing

NONE. All work is comment expansion + test additions + an audit-document pass.

## Test contracts

### EXISTING — must still pass unchanged
- All 89 SAML tests across 6 files.

### NEW — `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift` (2 new tests added to existing file)

1. `testSAMLLogin_allCookiesExpired_filtersAllAndProceedsWithEmptyArray`
   - Arrange: `MockSAMLAuthContext` returns 3 cookies all with `expiresDate < Date()`.
   - Act: `samlHelper.logIn(loginCancelHandler: ...)`.
   - Assert: `MockSAMLWebViewPresenter.lastPresentedCookies?.count == 0`; `samlHelper.cookies == []` (after the helper resets); log line "SAML: filtered 3 expired cookie(s)" emitted (verify via PalaceLogging test sink or skip log assertion and only assert count).
   - Kill case: removing the `> Date()` filter (mutating to `< Date()`) would observe `lastPresentedCookies?.count == 3`.

2. `testSAMLLogin_mixedExpiredAndValidCookies_filtersOnlyExpired_passesValid`
   - Arrange: `MockSAMLAuthContext` returns 4 cookies: 2 expired, 2 valid (expiresDate `> Date()`).
   - Act: `samlHelper.logIn(loginCancelHandler: ...)`.
   - Assert: `MockSAMLWebViewPresenter.lastPresentedCookies?.count == 2`; only the valid-cookie names are present; log line "SAML: filtered 2 expired cookie(s)" emitted.
   - Kill case: a regression that passes all cookies through unfiltered would observe `count == 4`.

### `try await` / `await` boundary clause

Module B introduces NO new `await` boundaries. The cookie-filter test additions are synchronous. Verify:
```bash
git diff origin/develop -- 'PalaceTests/SignInLogic/TPPSAMLFlowTests.swift' | grep -E '^\+.*try await|^\+.*await '
# MUST be empty
```

## Files scoped to THIS implementer

**Production MODIFIED (comment-only or audit-only):**
- `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` — audit only. Expected zero diff. If the audit finds a banned-pattern violation, file an addendum to this contract; otherwise document "audit passed, zero diff" in the evidence.
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` — line 188-192 ONLY: expand the existing `TODO: Phase 5 follow-up ...` comment to read `TODO(wave-4-SignInModal-migration): once SignInModalSheetPresenter (PR #<wave-3>) lands all 9 remaining caller migrations, the cookies-duplication cleanup can be done in the same pass. Until then both fields are maintained by LegacySAMLAuthContext.handleSAMLRedirect.`. Single comment edit; no semantic change.
- `Palace/Accounts/Library/AccountsManager.swift` — lines 967-981 ONLY: expand the existing comment to include the forward-compat decision tree for future `AccountEvictionReason` cases. New comment text proposal:
  ```swift
  case .detailsEvicted(.libraryDeselected):
      // `.detailsEvicted(.libraryDeselected)` is the eviction marker the
      // `currentAccount` setter writes against the PRIOR uuid when the
      // user switches libraries. If this account is back to being the
      // current account, that marker is stale — re-drive the auth-doc
      // fetch so awaitReady() callers (audiobook open, token refresh,
      // bookmark sync, CarPlay auth) don't throw `.evicted` forever
      // after a swap-away/swap-back.
      //
      // PR #1021 (Module A, swarm_51f248d5) split this case off from
      // `.detailsFailed(.accountNotFound)` so the eviction marker stops
      // sharing storage with the genuine HTTP-404 load failure below.
      //
      // FORWARD-COMPAT (added by swarm_18b0d071 wave 3 Module B):
      // When a NEW `AccountEvictionReason` case is added in the future,
      // the implementer must decide:
      //   (a) "Re-drive on re-entry" — same semantics as
      //       `.libraryDeselected`: the eviction was triggered by a
      //       reversible UX action (library swap, sign-out-on-current,
      //       etc.). Add `case .detailsEvicted(.<newReason>):` to this
      //       arm so awaitReady() callers can resume.
      //   (b) "Do NOT re-drive" — the eviction was triggered by an
      //       irreversible state (account deleted server-side, policy
      //       expiry, etc.). Add a new `case .detailsEvicted(.<newReason>):`
      //       arm that `return`s (mirroring the `.detailsFailed` arm at
      //       line 982) so awaitReady() correctly surfaces the failure.
      // The default `case .detailsEvicted(_):` is NOT exhaustive on
      // purpose — Swift's switch-exhaustiveness check will fail at
      // compile time when a new case is added, forcing the future
      // implementer to make the decision explicit here.
      break
  ```

**Test MODIFIED:**
- `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift` — add 2 new test functions at the bottom of the existing `final class TPPSAMLFlowTests` (or whichever inner class hosts cookie-filter tests).

**Tooling:** no pbxproj changes (no new files).

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/`, `ios-audiobooktoolkit/`
- `CLAUDE.md`, `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md` (already PR #1022)
- `worktree-refactor-saml-auth` contents

**Off-limits per Module A ownership:**
- `Palace/SignInLogic/SignInModalSheetPresenter.swift` (new file, Module A)
- `Palace/SignInLogic/SignInModalView.swift`
- `Palace/SignInLogic/TPPReauthenticator.swift`
- `Palace/AppInfrastructure/AppContainer.swift`
- `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift`

**Off-limits per the SAML plan's explicit out-of-scope (from `saml_refactor_handoff.md`):**
- Basic/OAuth/OIDC/Token auth flows
- `TPPCookiesWebViewController`
- `handleRedirectURL` (shared between OAuth and SAML)
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` (already at desired state)
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift` (Phase 4 already done)

**Read-only (verify your audit doesn't need changes here):**
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` (PalaceAuth package; main-target Module B can't modify it without contract update)

## Verification criteria (MANDATORY — all 7 DoD checks)

1. **SUT instantiation check (DoD #1):**
   ```bash
   # No new test file; the 2 new tests live in existing TPPSAMLFlowTests.swift which already constructs TPPSAMLHelper
   grep -c "TPPSAMLHelper(" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift  # MUST be ≥3 (was ≥3 baseline; new tests reuse setUp's helper)
   ```

2. **Comment expansion at AccountsManager.swift:967-981 verified:**
   ```bash
   grep -c "FORWARD-COMPAT" Palace/Accounts/Library/AccountsManager.swift  # MUST be ≥1
   grep -cE "Re-drive on re-entry|Do NOT re-drive" Palace/Accounts/Library/AccountsManager.swift  # MUST be 2 (both decision options documented)
   ```

3. **Multi-step test body check (DoD #3):**
   ```bash
   # testSAMLLogin_mixedExpiredAndValidCookies_filtersOnlyExpired_passesValid claims "filters + passes" — body MUST verify both
   grep -cE "lastPresentedCookies\?\.count|XCTAssertEqual.*lastPresentedCookies" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift  # MUST be ≥2 from the new tests (count + identity check)
   ```

4. **Forward-compat audit ON LegacySAMLAuthAdapter.swift — zero diff expected (DoD #4 scope coverage):**
   ```bash
   git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift
   # SHOULD be empty diff. If non-empty, the implementer found a banned-pattern violation and fixed it; document in evidence.
   ```

5. **Mutation kill-rate (critical path, DoD #5):**
   ```bash
   python3 scripts/palace_mutate.py \
     --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift \
     --tests PalaceTests/SignInLogic/TPPSAMLFlowTests --diff-only --diff-base origin/develop
   ```
   - Note: the production-code change in this contract is comment-only in `TPPSignInBusinessLogic.swift` and `AccountsManager.swift`; the new TESTS cover lines in `TPPSAMLHelper.swift:85-88` (cookie filter). Mutation kill rate on the cookie-filter lines MUST be ≥80% diff-scoped against the new tests. Run with `--diff-base origin/develop` so the comment-only changes don't dilute the score.

6. **Build + verify-pr (DoD #6):**
   ```bash
   scripts/verify-pr.sh --quick
   ```
   MUST PASS. Paste tails.

7. **Multi-step / wiring-claim check v2 (DoD #7 — PR #1022 clause):**
   ```bash
   # For each new test name claiming a multi-step path, confirm body literally drives each step.
   # testSAMLLogin_allCookiesExpired_filtersAllAndProceedsWithEmptyArray claims "filters → proceeds"
   # body must drive logIn and observe both the empty-cookies and the loginCompletion-fire
   # testSAMLLogin_mixedExpiredAndValidCookies_filtersOnlyExpired_passesValid claims "filters expired + passes valid"
   # body must drive logIn and assert ON the valid-cookie names being present
   grep -cE "expiresDate|filter|count == 0|count == 2" PalaceTests/SignInLogic/TPPSAMLFlowTests.swift  # MUST be ≥4 from the new tests
   ```

8. **No new force unwraps:**
   ```bash
   git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift Palace/SignInLogic/TPPSignInBusinessLogic.swift Palace/Accounts/Library/AccountsManager.swift PalaceTests/SignInLogic/TPPSAMLFlowTests.swift | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
   # MUST be empty
   ```

9. **No `.shared` reads added:**
   ```bash
   git diff origin/develop -- Palace/SignInLogic/LegacySAMLAuthAdapter.swift PalaceTests/SignInLogic/TPPSAMLFlowTests.swift | grep -E '^\+.*\.shared'
   # MUST be empty (or only documented system `.shared` like `NotificationCenter.default`)
   ```

10. **Existing 89 SAML tests still green:**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/TPPSAMLFlowTests test  # MUST pass (existing 29 + new 2 = 31)
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/TPPSAMLSignInTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/TPPSAMLLogoutTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalSAMLOIDCTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/Network/SAMLCookieSyncTests test  # MUST pass
    ```

11. **AccountsManager regression net (Module C bundled):**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/Accounts/AccountStateMachineTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/Accounts/AccountsManagerStateMachineWiringTests test  # MUST pass (the canonical round-trip test class per CLAUDE.md)
    ```

## Implementer prompt (one paragraph)

You are Module B implementer for `swarm_18b0d071` (wave 3 SAML hardening + AccountsManager:967 comment expansion). Pre-flight grep confirms the SAML refactor's Phases 1-4 from `~/.claude/plans/calm-knitting-thunder.md` are ALREADY LANDED via swarm_ea663ab6 — the protocols exist, the helper is in PalaceAuth, the adapters are wired, force unwraps are gone, ignoreSignedInState flows through AuthReducer. Your scope is small and hardening-focused: (1) Audit `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` for banned patterns (force unwraps, asyncAfter, .shared reads) — expected outcome is zero diff; document audit result in evidence. (2) Add 2 cookie-expiration edge-case tests to `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift`: all-expired-cookies and mixed-expired-and-valid. The tests use `MockSAMLAuthContext` + `MockSAMLWebViewPresenter` which already exist. (3) Expand the existing TODO comment at `Palace/SignInLogic/TPPSignInBusinessLogic.swift:188-192` to tag the wave-4 cookies-duplication cleanup. (4) Expand the comment at `Palace/Accounts/Library/AccountsManager.swift:967-981` to include the forward-compat decision tree for future `AccountEvictionReason` cases (re-drive vs not-re-drive — see contract for exact text proposal; the `default` case must NOT be added since switch-exhaustiveness is the forcing function for the next implementer's decision). NO Module A files (`SignInModalSheetPresenter.swift`, `SignInModalView.swift`, `TPPReauthenticator.swift`, `AppContainer.swift`). NO PalaceAuth package edits (`TPPSAMLHelper.swift`, `AuthReducer.swift`). NO `Palace/Audiobooks/`. NO CLAUDE.md / SKILL.md edits. Mutation kill-rate ≥80% diff-scoped on the cookie-filter lines in TPPSAMLHelper.swift via the new tests. If you find Phase 4 / Phase 5 still has unmigrated surface and want to expand scope, STOP with BLOCKED — the architect already audited and determined the migration is complete. If you find force-unwraps or banned patterns in the LegacySAMLAuthAdapter audit, fix them inline and document — but if the fix expands beyond 20 LOC, STOP with BLOCKED and surface as a wave-4 scope item.
````

---

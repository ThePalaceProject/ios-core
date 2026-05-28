# Module C — Caller migration: route 401/403 sites through `AuthCoordinator`

**Swarm:** `swarm_66819d80`  •  **Base SHA:** `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Depends on:** Module A (must merge first)

---

## Goal

Wire the network consumers that currently hit 401/403 with per-call-site
handling through the new `AuthErrorClassifier` + `AuthCoordinator` from
Module A. After Module C lands, the architectural defect is closed:
**there is no more per-call-site 401 handling**. Every caller routes
through one seam.

This is the highest-risk module in the swarm. The migration MUST
preserve every behavioral assertion in
`docs/3.2.0-auth-test-inventory.md` § "Module C — Caller migration MUST
keep green".

---

## In-scope files

### Modify (production callers)

```
Palace/Network/TPPNetworkResponder.swift
  Lines 220, 229, 367, 436: 401 detection sites
  → route through AuthErrorClassifier.classify(...); on .reauthRequired,
    await AuthCoordinator.refreshCredentialsIfNeeded(reason:)

Palace/MyBooks/TokenRefreshInterceptor.swift
  Lines 79, 116, 296: stale-mark + browser-reauth dispatch
  → replace markCredentialsStale + triggerSAML/OIDC/BrowserReauth with
    AuthCoordinator.refreshCredentialsIfNeeded

Palace/MyBooks/DownloadAuthRetryHandler.swift
  Lines 95, 131: parallel impl of TokenRefreshInterceptor
  → same migration. Both files route through coordinator; recon §
    "Surfaced risks" #2 explicitly notes we do NOT collapse them in
    this sprint, only route.

Palace/MyBooks/BorrowOperation.swift
  Lines 540-576 (handleBorrowAuthErrorIfNeeded), 609-636 (re-auth dispatch),
  643/818/821 (modal presentation), 785 (OIDC silent refresh — leave the
  setAuthToken call but route the trigger).
  → replace the isAuthError closure body + the OIDC/SAML branches with
    classify + refresh.

Palace/MyBooks/BookReturnService.swift
  Lines 285-330 (returnBook auth-error branch)
  → replace the isAuthError closure + markCredentialsStale + reauthenticator.authenticateIfNeeded with coordinator.refreshCredentialsIfNeeded

Palace/Audiobooks/AudiobookSessionManager.swift
  Lines 1124-1147 (.playbackFailed event)
  → replace shouldTriggerSAMLReauthForPlaybackFailure + markCredentialsStale + TPPReauthenticator with coordinator
```

### Modify (DI / wiring)

```
Palace/AppInfrastructure/AppContainer.swift
  Add: `authCoordinator: AuthCoordinator` to the container.
  Add: factory wiring (Reauthenticating ← TPPReauthenticator, SignInModalPresenting ← SignInModalPresenter, accountProvider/userAccountProvider from existing graph).
```

### Add (new — main-target conformances)

```
Palace/SignInLogic/TPPReauthenticator+Reauthenticating.swift
  3-line extension conforming TPPReauthenticator to Reauthenticating protocol from PalaceAuth.

Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift
  3-line extension conforming SignInModalPresenter to SignInModalPresenting protocol from PalaceAuth.

Palace/Accounts/User/TPPUserAccount+TPPUserAccountReadingWriting.swift
  Conform TPPUserAccount to the slim reading + writing protocols from PalaceAuth.
  (Only the methods the coordinator uses — hasCredentials, authTokenHasExpired, authState, markCredentialsStale.)
```

### Add (new tests)

```
PalaceTests/Network/TPPNetworkResponder+AuthCoordinatorTests.swift
PalaceTests/MyBooks/TokenRefreshInterceptor+AuthCoordinatorTests.swift
PalaceTests/MyBooks/DownloadAuthRetryHandler+AuthCoordinatorTests.swift
PalaceTests/MyBooks/BorrowOperation+AuthCoordinatorTests.swift
PalaceTests/MyBooks/BookReturnService+AuthCoordinatorTests.swift
PalaceTests/Audiobooks/AudiobookSessionManager+AuthCoordinatorTests.swift
PalaceTests/AppInfrastructure/AppContainer+AuthCoordinatorWiringTests.swift
```

### OFF-LIMITS

- `Palace/Packages/PalaceAuth/` — Module C does NOT modify package
  internals. If a Module A signature needs to change, escalate to the
  orchestrator; do not silently widen it.
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` and ALL its
  extensions — these are sign-in flow internals; the swarm scope is
  consumers, not the sign-in pipeline itself.
- `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift` — sign-out
  flow MUST NOT route through coordinator (out of scope per task
  brief).
- `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift`
  — DRM activation; out of scope.
- `Palace/MyBooks/MyBooksDownloadCenter.swift:1034` (`setCookies`) — SAML
  redirect cookie capture; not a 401 callback.
- `Palace/MyBooks/CredentialPromptCoordinator.swift` — OverDrive
  credential prompt; different domain.
- Anything in `Palace/Settings/` — settings UI consumes the predicate
  Module B introduced; it is not a 401 site.

---

## Migration recipe per call site

Each migrated site follows the SAME 3-step pattern. Pseudocode:

**Before:**
```swift
// e.g. TokenRefreshInterceptor.swift L79
if response.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: req.url) {
    if account.authDefinition?.isSaml == true {
        userAccount.markCredentialsStale()
        triggerSAMLReauth { /* ... */ }
    } else if account.authDefinition?.isOidc == true {
        userAccount.markCredentialsStale()
        triggerOIDCReauth { /* ... */ }
    } else {
        userAccount.markCredentialsStale()
        triggerBrowserReauth { /* ... */ }
    }
}
```

**After:**
```swift
let outcome = authClassifier.classify(
    response: response,
    problemDocument: problemDoc,
    body: data,
    originalRequestURL: req.url
)
switch outcome {
case .reauthRequired(let reason):
    Task {
        let result = await authCoordinator.refreshCredentialsIfNeeded(reason: reason)
        if case .success = result {
            // resume download / retry borrow / re-open audiobook
        }
    }
case .forbidden, .serverError, .networkError, .ok:
    // existing non-auth paths
    break
}
```

The coordinator handles `markCredentialsStale` + IdP dispatch
internally; per-site code stops carrying that knowledge.

### Site-specific notes

**Site 1.1 / 1.4 / 1.5 (`TPPNetworkResponder.swift`):** The retry counter
(`tokenRefreshAttempts < 2`) STAYS in the responder — that's a
network-layer concern, not auth. The migration only changes the
decision *to* refresh; the budget *for* refreshing remains.

**Site 1.6 / 1.7 / 1.8 (`TokenRefreshInterceptor.swift`):** Three nearly
identical sites. Migrate ALL three or none. Half-migration creates
silent divergence (recon § Surfaced risks #2).

**Site 1.9 / 1.10 (`DownloadAuthRetryHandler.swift`):** Parallel to 1.6/1.7.
SAME logic; SAME migration. Don't collapse the two files into one
(out of scope for this sprint per recon).

**Site 1.11 / 1.12 (`BorrowOperation.swift`):** The dense decision tree
becomes a single switch on `AuthOutcome`. The OIDC silent-refresh
success path (line 785) still calls `userAccount.setAuthToken(...)` —
do not migrate that; it's INSIDE the coordinator's mechanism, not a
caller decision.

**Site 1.13 (`BookReturnService.swift`):** Mirrors borrow. Same migration.

**Site 1.14 (`AudiobookSessionManager.swift`):** The static
`shouldTriggerSAMLReauthForPlaybackFailure` helper is internal to the
session manager; the migration replaces its body with a coordinator
call. Do NOT delete the helper signature — it has 2 unit tests
(`shouldTriggerSAMLReauthForPlaybackFailure_*`) that pin the decision
boundary. Keep the helper as a thin shim that delegates to
`authClassifier.classify(...)`.

**Site 3.6 / 3.7 (BorrowOperation modal presentation):** The injected
`presentSignInModal` closure becomes
`authCoordinator.refreshCredentialsIfNeeded(.borrow)`. The closure call
sites stay; only the body changes (DI wiring update in AppContainer).

---

## Test contract

Each migrated site gets a test class with the following SHAPE (~4
tests each):

```swift
final class <Site>AuthCoordinatorTests: XCTestCase {

    // Spy coordinator
    var spyCoordinator: SpyAuthCoordinator!
    var sut: <SiteUnderTest>!

    func test_on401WithSamlReason_callsCoordinatorRefreshExactlyOnce() {
        // arrange: stub a 401 response
        // act: drive the production seam (the function that handles the response)
        // assert: spyCoordinator.refreshCallCount == 1, last reason == .samlSessionExpired
    }

    func test_onCoordinatorSuccess_resumesOperation() {
        spyCoordinator.stubResult = .success(())
        // drive seam
        // assert: operation continued (download started, borrow retried, etc.)
    }

    func test_onCoordinatorUserCancelled_propagatesCancellation() {
        spyCoordinator.stubResult = .failure(.userCancelled)
        // assert: operation cancelled, no markCredentialsStale lingering
    }

    func test_on200Response_doesNotCallCoordinator() {
        // assert: spyCoordinator.refreshCallCount == 0
    }
}
```

`SpyAuthCoordinator` is a new test helper at
`PalaceTests/Mocks/SpyAuthCoordinator.swift`. (Module C adds it.)

### Round-trip wiring test (CLAUDE.md mandate)

`PalaceTests/AppInfrastructure/AppContainer+AuthCoordinatorWiringTests.swift`:

```swift
func testCoordinator_isConstructed_inProductionGraph_andRoundtripsViaTPPReauthenticator() {
    let container = AppContainer.production()
    let coordinator = container.authCoordinator
    // Drive: caller-side 401 → coordinator.refreshCredentialsIfNeeded(.expiredToken)
    //         → real TPPReauthenticator.authenticateIfNeeded(...)
    //         → success completion
    //         → coordinator returns .success
    // Use a stubbed network (HTTPStubURLProtocol) so the real reauthenticator
    // sees a fake 200 from the auth endpoint.
}
```

### Must NOT break

The full list from `docs/3.2.0-auth-test-inventory.md` § "Module C — MUST
keep green":

- `TokenRefreshAndRetryQueueTests` (9 tests) — single-flight + stale-mark + queue resume
- `TokenRefreshOnForegroundTests` (10) — proactive refresh
- `TPPSAMLSignInTests.testTokenRefresh_*` and `testCredentialsStale_*` (5)
- `MultiLibraryTokenIsolationTests.test_RefreshA_401_MarksOnlyAStale_NotB`
- `TPPReauthenticatorTests.testAuthenticateIfNeeded_withNilCompletion_doesNotCrash`
- `TPPIdleSignOutRegressionTests` (14 tests) — sign-out path MUST be unchanged
- `URLResponseAuthenticationTests` (33 tests) — same-domain logic
- `AuthErrorProblemDocSeamTests` (6) — problem-doc rewrap
- `TPPSignInOIDCTests.testOIDC_isTreatedLikeSAML_forReauth`
- `SignInModalSAMLOIDCTests.testSignInModalGuard_needsAuth_classifiesAuthTypesCorrectly`

### Critical-path tests run on every commit (CLAUDE.md mandate)

Per CLAUDE.md "critical path tests must be air-tight" — borrow, return,
download, audiobook open, token refresh ALL touched in this PR.
Implementer runs these 10 (from test-inventory § "Critical-path tests")
on every commit.

### Mutation gate

Per CLAUDE.md, files in `Palace/MyBooks/Download*` are on the strict
mutation list. Module C touches `TokenRefreshInterceptor` and
`DownloadAuthRetryHandler`. Both MUST hit ≥50% kill rate via diff-scoped
mutation:

```bash
python3 scripts/palace_mutate.py \
  --file Palace/MyBooks/TokenRefreshInterceptor.swift \
  --tests TokenRefreshInterceptorAuthCoordinatorTests \
  --diff-only
```

(Repeat for each modified file.) If `--diff-only` reports 0 mutants,
the migration didn't actually change behavior — that's a test-quality
failure, not a pass.

---

## TDD assertion outline

```
Day 2 AM (Module A merged the night before):

  1. Pull main with Module A merged. Verify PalaceAuth tests still green.
  2. Add main-target conformances (TPPReauthenticator+Reauthenticating,
     SignInModalPresenter+SignInModalPresenting,
     TPPUserAccount+TPPUserAccountReadingWriting). Each is 3 lines.
     Compile.
  3. Wire AuthCoordinator into AppContainer.production(). Add a basic
     constructor test. Run.
  4. Add SpyAuthCoordinator to PalaceTests/Mocks/.
  5. Migrate Site 1.14 (AudiobookSessionManager) FIRST — smallest
     and most isolated. Tests first; then production.
  6. Run AudiobookSessionManager tests; run also the criticality list.
     If anything fails, fix before continuing.
  7. Migrate Site 1.6/1.7/1.8 (TokenRefreshInterceptor) together.
     Tests first; then production.
  8. Run critical-path tests #4 (testConcurrentRefreshes_*) and #5
     (testCredentialsStale_preservesCookies). Must pass.
  9. Migrate Site 1.9/1.10 (DownloadAuthRetryHandler).
  10. Migrate Site 1.11/1.12 + Site 3.6/3.7 (BorrowOperation).
  11. Migrate Site 1.13 (BookReturnService).
  12. Migrate Sites 1.1/1.2/1.4/1.5 (TPPNetworkResponder). Run the
      full Network test suite.
  13. Run the AppContainer wiring round-trip test.
  14. Run `scripts/verify-pr.sh --quick`.

Day 2 PM:

  15. Mutation pass on every changed file. Fix uncovered branches by
      adding tests until kill rate ≥50%.
  16. forge-review prep (architect + qa_test reviewers).
```

---

## What NOT to do

1. **Do NOT migrate sign-out** (recon § 1.15 / 2.2.16). Sign-out has its
   own state machine; it doesn't ask the coordinator anything.
2. **Do NOT collapse `TokenRefreshInterceptor` and
   `DownloadAuthRetryHandler` into one file** (recon § Surfaced risks
   #2). Route both, leave both as separate files.
3. **Do NOT introduce new public methods on `AuthCoordinator`.** If a
   call site needs a new method, write a TODO and escalate to
   orchestrator.
4. **Do NOT remove `TPPReauthenticator`.** It becomes the coordinator's
   private implementation detail, not a deletion target. The 4 lines of
   conformance (`TPPReauthenticator+Reauthenticating.swift`) keep it
   wired.
5. **Do NOT migrate `MyBooksDownloadCenter.swift:1034` (`setCookies`)** —
   that's SAML redirect cookie capture, not a 401 callback.
6. **Do NOT migrate `CredentialPromptCoordinator.swift`** — different
   domain (OverDrive credentials prompt).
7. **Do NOT touch any file under `Palace/Settings/`.** Module B handled
   the settings predicates; the settings layer doesn't do 401 callbacks.

---

## Pbxproj wiring

New main-target files require:
```
ruby scripts/pbxproj_add_swift.rb \
  Palace/SignInLogic/TPPReauthenticator+Reauthenticating.swift \
  Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift \
  Palace/Accounts/User/TPPUserAccount+TPPUserAccountReadingWriting.swift
```

New test files require:
```
ruby scripts/pbxproj_add_swift.rb \
  PalaceTests/Network/TPPNetworkResponder+AuthCoordinatorTests.swift \
  PalaceTests/MyBooks/TokenRefreshInterceptor+AuthCoordinatorTests.swift \
  PalaceTests/MyBooks/DownloadAuthRetryHandler+AuthCoordinatorTests.swift \
  PalaceTests/MyBooks/BorrowOperation+AuthCoordinatorTests.swift \
  PalaceTests/MyBooks/BookReturnService+AuthCoordinatorTests.swift \
  PalaceTests/Audiobooks/AudiobookSessionManager+AuthCoordinatorTests.swift \
  PalaceTests/AppInfrastructure/AppContainer+AuthCoordinatorWiringTests.swift \
  PalaceTests/Mocks/SpyAuthCoordinator.swift
```

Both targets (Palace + Palace-noDRM) — the script handles both Sources
phases.

---

## Acceptance

- All 7 migrated production files compile + their existing tests green.
- New `<Site>AuthCoordinatorTests` classes green (~28 new tests).
- AppContainer wiring round-trip test green.
- Sign-out tests (`TPPIdleSignOutRegressionTests` 14 tests) untouched
  and green.
- Critical-path tests #1–10 from inventory all green.
- `grep -rn "indicatesAuthenticationNeedsRefresh\|markCredentialsStale"
  Palace/` returns ONLY:
  - the PalaceAuth extension (it's the implementation)
  - the `+SignOut` file (sign-out is allowed to call it directly)
  - the `AuthCoordinator` (internal use)
  - the migrated callers — but ONLY in the form `await
    coordinator.refreshCredentialsIfNeeded(...)` and NOT
    `userAccount.markCredentialsStale(); trigger*Reauth { ... }`.
- Mutation kill rate ≥50% per modified file (diff-scoped); 100% on the
  critical `Download*` files.
- `scripts/verify-pr.sh --quick` green.

---

## Evidence to attach (for forge-review)

- `unit_test`: PalaceTests output (full count + green).
- `lint`: `swiftlint` on the modified files.
- `mutation`: per-file diff-scoped kill rate.
- `architect_review`: reviewer attests no out-of-scope file touched + 7
  sites all migrated.
- `qa_test`: reviewer asserts critical-path tests verified locally and
  runs at least 1 simdrive replay against a recorded auth flow
  (`pr907-saml-signin-gorgon` is the canonical fixture).

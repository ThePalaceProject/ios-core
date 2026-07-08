## Contract A — `.forgeos/swarms/swarm_d8f11437/contracts/A-SignInModal-migration-pass-2.md`

````markdown
# Module A — SignInModal migration pass 2 of 2 (wave 4)

**Critical-path module.** Risk: regressions hit users on every sign-in / re-auth / borrow / token-refresh / hold / download-on-no-credentials path. Architect + SoD (qa_test + clean_code) review required.

**Depends on Module B.** Module A's required wiring test injects a spy presenter via `AppContainer.withSignInModalSheetPresenter(_:)` — that modifier is owned by Module B. Module B's signature MUST land before Module A's wiring test can be wired in. Coordinate via the contract; do not block on parallel work if signature is agreed.

## Goal

Finish the SignInModal SwiftUI migration started in wave 3:

1. Migrate the remaining **11 call sites across 9 files** from `SignInModalPresenter.presentSignInModal*` static API to AppContainer-injected `SignInModalSheetPresenter`.
2. Remove `SignInModalHostingController` from `Palace/SignInLogic/SignInModalView.swift` (wave 3 kept it as a no-op tomb).
3. Delete the 4 obsolete `testShouldFireDismissCallback_*` predicate tests in `PalaceTests/SignInLogic/SignInModalPredicateTests.swift`.
4. Add 3 NEW presenter state-transition tests to `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (replacing the coverage the deleted predicate tests provided).
5. Add 1 NEW **true production-seam wiring test** that drives `TPPReauthenticator().authenticateIfNeeded(...)` with a spy presenter injected via Module B's `AppContainer.withSignInModalSheetPresenter(_:)` modifier — closes wall-failure cs_9a267b63.

## Resolved decisions

- **Wave 4 covers ALL 11 sites + HostingController removal + predicate-test deletion.** No partial-ship — if implementer can't land all 11 cleanly, STOP with the scope-deferral 3-option proposal (do NOT bury reductions in a gaps section).
- **Module B owns the AppContainer testability seam.** Module A's wiring test depends on it. Do NOT modify `AppContainer.swift` from Module A — call the seam Module B provides.
- **Module C's runnable-grep script (`scripts/check-test-name-vs-body.py`) is the integrator's gate for Module A's tests.** Module A's wiring test name MUST satisfy that script (the body MUST instantiate every PascalCase class-noun in the name).

## Call-site migration patterns (grep-verified post-rebase)

| # | File | Line | Current call | AppContainer access | Migration pattern |
|---|---|---|---|---|---|
| 1 | `Palace/AppInfrastructure/DLNavigator.swift` | 86 | `SignInModalPresenter.presentSignInModalForCurrentAccount { ... }` | None local; method uses `AppContainer.production()` default arg | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { ... }` |
| 2 | `Palace/Network/TPPNetworkExecutor.swift` | 587 | `SignInModalPresenter.presentSignInModalForCurrentAccount(completion: nil)` | None local | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount(completion: nil)` |
| 3 | `Palace/Holds/HoldsViewModel.swift` | 96 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: accountsManager, completion: completion)` | `[accountsManager]` captured | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount(completion: completion)` — the presenter resolves `currentAccountId` from its own container's accountsManager (same instance via production() singleton) |
| 4 | `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift` | 45 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: accountsManager) { ... }` | Has `self.accountsManager` | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { ... }`. NOTE: `accountsManager` is captured before the closure (line 38) so the `hasCredentials()` re-check after dismissal is unchanged. |
| 5 | `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` | 703 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: self.accountsManager) { ... }` | `self.accountsManager` | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { ... }` |
| 6 | `Palace/MyBooks/MyBooksDownloadCenter.swift` | 588 | `SignInModalPresenter.presentSignInModalForCurrentAccount(completion: completion)` (inside CredentialPromptCoordinator closure) | None local | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount(completion: completion)` |
| 7 | `Palace/MyBooks/MyBooksDownloadCenter.swift` | 778 | `SignInModalPresenter.presentSignInModalForCurrentAccount(completion: completion)` (inside BorrowOperation closure) | None local | Same as #6 |
| 8 | `Palace/MyBooks/TokenRefreshInterceptor.swift` | 275 | `SignInModalPresenter.presentSignInModalForCurrentAccount { [weak self, weak delegate] in ... }` | None local | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { [weak self, weak delegate] in ... }` |
| 9 | `Palace/MyBooks/MyBooks/MyBooksViewModel.swift` | 198 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: accountsManager, completion: nil)` | `self.accountsManager` | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount(completion: nil)` |
| 10 | `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` | 655 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: accountsManager) { [weak self] in ... }` | `self.accountsManager` | Replace with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { [weak self] in ... }` |
| 11 | `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` | 680 | `SignInModalPresenter.presentSignInModalForCurrentAccount(accountsManager: accountsManager) { [weak self] in ... }` | `self.accountsManager` | Same as #10 |

**Migration invariant:** `AppContainer.production()` is the single composition root — all 11 sites resolve `accountsManager` through the same underlying `_cached` singleton. Migrating from explicit `accountsManager:` arg to the presenter's container-resolved `currentAccountId` is behavior-preserving because both paths read from the same `AccountsManager` instance. **Verify on each migration**: the call site is using the production-singleton `accountsManager`, not a parallel test-fixture instance. (Spot-check confirmed: HoldsViewModel.swift L93 reads `accountsManager.currentAccount`, BookDetailViewModel.swift uses `self.accountsManager` initialized from `AppContainer.production()`, etc.)

## HostingController removal

Delete `Palace/SignInLogic/SignInModalView.swift` lines 80-118 (`final class SignInModalHostingController<Content: View>: UIHostingController<Content> { ... }`). Also delete the docstring comment lines 80-85 introducing it.

`SignInModalPresenter.presentSignInModal` at lines 137-172 currently wraps the SwiftUI view in `SignInModalHostingController`. **REPLACE** with a plain `UIHostingController` and inline the `onDidFullyDismiss` logic using a closure-captured ref to the hosting controller. Specifically:

```swift
// Replacement at SignInModalView.swift:154-171:
let view = SignInModalView(
    libraryAccountID: libraryAccountID,
    completion: nil,
    appContainer: appContainer
)

let vc = SignInModalDismissalHosting(rootView: view) {
    isPresenting = false
    completion?()
}
vc.modalPresentationStyle = .formSheet
TPPPresentationUtils.safelyPresent(vc, animated: true)
```

OR — if the implementer determines that the `viewDidDisappear` + `presentingViewController == nil` guard can be replaced by a SwiftUI `.onDisappear`-based mechanism without regressing HelpSpot 17716, that's acceptable but MUST be verified by ensuring the existing 3 `shouldAutoDismiss_*` tests still pass AND adding a new test that pins the once-after-fully-dismissed semantics on the replacement.

**Conservative recommendation:** Keep a minimal internal hosting controller subclass (rename to `SignInModalDismissalHosting` to disambiguate from the removed `SignInModalHostingController`). Move the `shouldFireDismissCallback` static predicate into the new class — but then the 4 predicate tests can stay if the predicate moves with it.

**Actually-recommended path (cleanest, matches contract spirit):**
- Delete `SignInModalHostingController` entirely (lines 80-118).
- Delete the 4 `shouldFireDismissCallback_*` tests.
- Replace its callsite with a minimal `UIHostingController` subclass declared **privately inside `SignInModalPresenter`** — visibility-scoped so it can't be re-exported. Its lifecycle is identical (override `viewDidDisappear`, check `presentingViewController == nil + !firedOnce`, fire callback), but it's not a tested-named public type.
- Add 3 new NAMED state-transition tests on `SignInModalSheetPresenter` (below) that pin the equivalent guard behavior via the presenter's published-state stream.

This replaces the predicate test surface 1:1 — the same logic (once-after-fully-dismissed) is now pinned at the presenter level, where consumers can actually exercise it.

## Public types/protocols changing

**REMOVE:**
- `final class SignInModalHostingController<Content: View>: UIHostingController<Content>` from `SignInModalView.swift:86-118` (public type, used only by `SignInModalPredicateTests`).

**ADD (internal):**
- A private nested hosting class inside `SignInModalPresenter` or a fileprivate one in `SignInModalView.swift` to wire `viewDidDisappear → callback` for the `safelyPresent` path. Implementer's choice; the key property is that it's NOT a public/test-visible type.

**UNCHANGED:**
- `SignInModalSheetPresenter` API surface (wave 3) — unchanged.
- `SignInModalSheetPresenting` protocol — unchanged.
- `SignInPresentationState` enum — unchanged.
- `SignInModalView` SwiftUI body, predicate `shouldAutoDismiss`, cancel button — unchanged.
- `SignInModalPresenter.presentSignInModal(libraryAccountID:appContainer:completion:)` — internal-only callers now (the only remaining caller is `SignInModalSheetPresenter.productionDriver`); the public static API surface may stay or be made `internal` per implementer choice.
- `CoordinatorSignInModalPresenter` (PalaceAuth's `SignInModalPresenting` adapter): MIGRATED internally to call the sheet presenter (line 45 site #4), but the `async -> Bool` outer signature is UNCHANGED — `AuthCoordinator.swift:371`'s `await modalPresenter.presentSignInModalForCurrentAccount()` still compiles.

## Internal seams

- All 11 migrated sites read `AppContainer.production().signInModalSheetPresenter` — same instance every time (the static `_signInModalSheetPresenter` cache + Module B's per-instance override are both routed through the computed property).
- `SignInModalSheetPresenter` already resolves `currentAccountId` at present-time (not init-time, per wave 3 design) — preserves library-switch invariance.
- The single-flight guard (presenter's `inFlight` + static API's `isPresenting`) collapses concurrent presents to one UIKit mount — already pinned by wave 3 lifecycle tests; NOT re-tested in wave 4.

## Test contracts

### EXISTING — must still pass unchanged

- `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` — 3 `shouldAutoDismiss_*` tests (lines 24, 35, 45) stay green (predicate stays on `SignInModalView`).
- `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` — 6 tests (182 LOC) unchanged.
- `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` — 5 existing tests (single-flight, dismiss-after-present, lifecycle attestation, anonymous-library, nil-account) stay green.
- `PalaceTests/SignInLogic/TPPReauthenticatorTests.swift` — 5 tests unchanged.
- `PalaceTests/MyBooks/BorrowOperation*Tests.swift` — indirect tests via the presenter closure (replaced from static-API closure to presenter-resolved closure).
- `PalaceTests/Book/BookDetailViewModelTests.swift` — must pass.
- `PalaceTests/Network/TPPNetworkExecutor*Tests.swift` — must pass.
- `PalaceTests/Holds/HoldsViewModelTests.swift` — must pass.

### DELETE — `PalaceTests/SignInLogic/SignInModalPredicateTests.swift`

Delete 4 tests (lines 58-108):
- `testShouldFireDismissCallback_firstTimeAndDismissed_returnsTrue` (line 58)
- `testShouldFireDismissCallback_firstTimeButStillPresented_returnsFalse` (line 72)
- `testShouldFireDismissCallback_alreadyFired_returnsFalse` (line 86)
- `testShouldFireDismissCallback_alreadyFiredAndStillPresented_returnsFalse` (line 102)

Also delete the `// MARK: - shouldFireDismissCallback` section header (line 56) since the section is empty after deletion.

**Rationale for deletion:** `SignInModalHostingController.shouldFireDismissCallback` predicate goes away with the class. The behavior it pinned (once-after-fully-dismissed) is now exercised at the presenter level by the new `testPresenter_*_isNoOp` family below.

### NEW — `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (3 state-transition tests + 1 wiring test)

#### State-transition tests (3, replacing deleted predicate coverage)

1. **`testPresenter_idleToPresenting_publishesForCurrentAccountOnFirstPresent`**
   - **Multi-step claim per CLAUDE.md DoD #3:** "idleToPresenting, publishesForCurrentAccount, onFirstPresent" — body MUST literally drive present from `presentationState == nil` and assert the transition.
   - Arrange: construct `SignInModalSheetPresenter` via `makePresenter(driver: fakeDriver.makeDriver())` (existing helper). Fake driver holds completion (does NOT fire synchronously). Assert `presentationState == nil` BEFORE present.
   - Act: call `presenter.presentSignInModalForCurrentAccount { ... }`.
   - Assert: `presentationState == .forCurrentAccount` (mid-presentation state pinned before driver completion fires); recorder.values shows the `nil → .forCurrentAccount` transition exactly once.
   - Kill case: a regression that forgets to set `presentationState = state` (or sets it to nil) is observable.

2. **`testPresenter_presentingToDismissed_clearsPresentationStateOnDriverCompletion`**
   - **Multi-step claim per CLAUDE.md DoD #3:** "presentingToDismissed, clearsPresentationState, onDriverCompletion" — body MUST drive present, then fire driver completion, then assert clear.
   - Arrange: construct presenter, fake driver holds completion.
   - Act: call `presenter.presentSignInModalForCurrentAccount { ... }`. Assert `presentationState == .forCurrentAccount`. Then fire `fakeDriver.capturedCompletions.first?()`.
   - Assert: `presentationState == nil` AFTER driver fires completion; recorder.values stream ends with `nil`; user completion fires exactly once.
   - Kill case: removing `self.presentationState = nil` in driver completion is observable; reversing the order (firing user completion before clearing state) is observable via the recorder.

3. **`testPresenter_dismissedToIdle_secondPresentAfterFirstCompletes_publishesAgain`**
   - **Multi-step claim per CLAUDE.md DoD #3:** "dismissedToIdle, secondPresentAfterFirstCompletes, publishesAgain" — body MUST drive present, complete, present-again, complete-again. This is the **round-trip pattern** per CLAUDE.md ("State-machine wiring tests must exercise round-trips, not just transitions").
   - Arrange: construct presenter, fake driver holds completion.
   - Act:
     1. Call `presenter.presentSignInModalForCurrentAccount { firstCompletionFires += 1 }`. Assert `presentationState == .forCurrentAccount`.
     2. Fire first driver completion. Assert `presentationState == nil`.
     3. Call `presenter.presentSignInModalForCurrentAccount { secondCompletionFires += 1 }`. Assert `presentationState == .forCurrentAccount` (re-published).
     4. Fire second driver completion. Assert `presentationState == nil`.
   - Assert: both completions fire exactly once; both `.forCurrentAccount` publishes appear in recorder.values; driver received 2 invocations; inFlight guard correctly reset between the two presents.
   - Kill case: a regression that forgets to reset `inFlight = false` in the driver completion would have the second present silently no-op (driver invoked only once); a regression that retains the first `presentationState` across the second present would observe only one `.forCurrentAccount` in recorder.values.

#### Wiring test (1, closes wall-failure cs_9a267b63)

4. **`testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam`**
   - **Multi-step + production-seam claim per CLAUDE.md DoD #3 + #7:** "TPPReauthenticatorAuthenticateIfNeeded, drivesSpyPresenter, ViaAppContainerSeam" — body MUST instantiate `TPPReauthenticator(`, call `authenticateIfNeeded(...)`, and observe the spy presenter receiving the call through `AppContainer.withSignInModalSheetPresenter(_:)`.
   - Arrange:
     1. Construct a `SpySignInModalSheetPresenter` (test-local subclass of `SignInModalSheetPresenter` OR a fake conforming to `SignInModalSheetPresenting`). Override `presentSignInModalForCurrentAccount(completion:)` to record `spy.presentForCurrentAccountCallCount += 1` and fire the completion synchronously.
     2. Construct the test container: `let testContainer = AppContainer.production().withSignInModalSheetPresenter(spy)` (Module B's modifier).
     3. **STOP-if-blocked clause:** `TPPReauthenticator.authenticateIfNeeded` currently reads `AppContainer.production().signInModalSheetPresenter` directly (line 57). If the implementer cannot inject the spy WITHOUT modifying TPPReauthenticator's call to read from an injected container or some kind of injected provider, STOP with BLOCKED 3-option proposal. **Recommended path:** Module A adds an internal-test-seam in TPPReauthenticator that allows the `AppContainer` to be overridden for tests (e.g. `static var _testContainerOverride: AppContainer?` checked first). This is acceptable test scaffolding — pin it in a `#if DEBUG` block if cleanliness is preferred.
     4. Instantiate: `let reauth = TPPReauthenticator()`. Construct a `TPPUserAccountMock`.
   - Act:
     ```swift
     let expectation = expectation(description: "authentication completes")
     reauth.authenticateIfNeeded(userAccount, usingExistingCredentials: true) {
         expectation.fulfill()
     }
     wait(for: [expectation], timeout: 1.0)
     ```
   - Assert:
     - `reauth.authenticateCallCount == 1` (the pre-existing test seam).
     - `spy.presentForCurrentAccountCallCount == 1` (the spy WAS called via the injected container).
     - The completion fired (expectation satisfied).
     - **Critical: the spy WAS the seam, not the production driver.** Pin by asserting the spy's recorded library ID matches the test container's `accountsManager.currentAccountId` AT call time.
   - Kill case: a regression that makes `TPPReauthenticator` bypass the AppContainer-injected presenter (e.g. revert to direct `SignInModalPresenter.presentSignInModalForCurrentAccount` static call) means `spy.presentForCurrentAccountCallCount == 0` — test fails LOUD.
   - **Closes:** wall-failure entry `.forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md`. This is the test the architect required and wave 3 admitted couldn't be built without AppContainer testability changes.

## Files scoped to THIS implementer

**Production MODIFIED:**
- `Palace/AppInfrastructure/DLNavigator.swift` — site #1
- `Palace/Network/TPPNetworkExecutor.swift` — site #2
- `Palace/Holds/HoldsViewModel.swift` — site #3
- `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift` — site #4
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — site #5
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — sites #6, #7
- `Palace/MyBooks/TokenRefreshInterceptor.swift` — site #8
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift` — site #9
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` — sites #10, #11
- `Palace/SignInLogic/SignInModalView.swift` — DELETE `SignInModalHostingController` class (lines 80-118); REPLACE its callsite usage in `SignInModalPresenter.presentSignInModal` with a fileprivate hosting subclass OR an inline closure-based mechanism

**OPTIONAL Production MODIFIED (test-seam for wiring test #4):**
- `Palace/SignInLogic/TPPReauthenticator.swift` — add a test-only AppContainer-override seam (e.g. `static var _testContainerOverride: AppContainer?` guarded by `#if DEBUG`). If implementer determines this is unacceptable scope, STOP with BLOCKED and propose alternative (e.g. inject AppContainer via init, or use a method-level seam).

**Tests MODIFIED:**
- `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` — DELETE 4 `testShouldFireDismissCallback_*` tests (lines 58-108) + section header (line 56)
- `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` — ADD 3 state-transition tests + 1 wiring test

**Tooling:**
- No new files; no pbxproj changes (all modifications are to files already in the project)

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/`, `ios-audiobooktoolkit/`
- `worktree-refactor-saml-auth` contents
- `Palace/Accounts/Library/AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift`
- `Palace/SignInLogic/TPPSAMLHelper.swift`, `TPPSignInBusinessLogic.swift`, `TPPSignInBusinessLogic+SAML.swift`

**Off-limits per Module B ownership:**
- `Palace/AppInfrastructure/AppContainer.swift` — DO NOT modify. Module B owns this file. Module A's wiring test READS from B's `withSignInModalSheetPresenter(_:)` modifier; coordinate via the contract signature.

**Off-limits per Module C ownership:**
- `scripts/check-test-name-vs-body.py`, `.claude/skills/swarm/SKILL.md`, `CLAUDE.md`

**Off-limits per wave-5 deferral:**
- `SignInModalPresenter` class deletion (the public/static class still exists — wave 4 just stops having external callers, leaving only the internal `productionDriver` call from the presenter).
- Async variant of `SignInModalSheetPresenter`.

## Verification criteria (MANDATORY — all 7 DoD checks + self-referential rigor)

1. **SUT instantiation check (CLAUDE.md DoD #1 + Module C method-level extension):**
   ```bash
   # Module C's NEW script — Phase 4.5 gate
   python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
   # MUST exit 0 — every test method whose name embeds a class-noun must instantiate that noun
   python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalPredicateTests.swift
   # MUST exit 0
   ```
   AND the legacy file-level check:
   ```bash
   grep -c "SignInModalSheetPresenter(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥3
   grep -c "TPPReauthenticator(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥1 (wiring test #4)
   grep -c "AppContainer.production()" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥1 (wiring test #4 uses the seam)
   grep -c "withSignInModalSheetPresenter" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥1
   ```

2. **All 11 call sites migrated:**
   ```bash
   grep -rcE "SignInModalPresenter\.presentSignInModal(ForCurrentAccount)?\(" Palace/ --include="*.swift" \
     | grep -v "Packages/PalaceAuth" \
     | grep -v "SignInModalSheetPresenter.swift" \
     | grep -v "SignInModalView.swift:0$" \
     | awk -F: '{sum+=$2} END {print sum}'
   # MUST be 0 — no production caller except the productionDriver inside SignInModalSheetPresenter.swift
   ```
   AND:
   ```bash
   grep -rcE "signInModalSheetPresenter\.presentSignInModal" Palace/ --include="*.swift" | awk -F: '{sum+=$2} END {print sum}'
   # MUST be ≥12 — 11 newly-migrated sites + 1 wave-3 TPPReauthenticator already there + adapter site
   ```

3. **HostingController removed:**
   ```bash
   grep -c "final class SignInModalHostingController" Palace/SignInLogic/SignInModalView.swift  # MUST be 0
   grep -c "SignInModalHostingController" Palace/  # MUST be 0 in production
   grep -c "SignInModalHostingController" PalaceTests/  # MUST be 0 in tests
   ```

4. **Predicate tests deleted:**
   ```bash
   grep -c "testShouldFireDismissCallback" PalaceTests/SignInLogic/SignInModalPredicateTests.swift  # MUST be 0
   grep -c "testShouldAutoDismiss" PalaceTests/SignInLogic/SignInModalPredicateTests.swift  # MUST be 3 (UNCHANGED — these stay)
   ```

5. **State-transition tests added:**
   ```bash
   grep -c "testPresenter_idleToPresenting" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be 1
   grep -c "testPresenter_presentingToDismissed" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be 1
   grep -c "testPresenter_dismissedToIdle" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be 1
   ```

6. **Wiring test added + satisfies wall-failure shape:**
   ```bash
   grep -c "testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam" \
     PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be 1
   # Body checks:
   awk '/testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam/,/^    func test|^}/' \
     PalaceTests/SignInLogic/SignInModalLifecycleTests.swift > /tmp/wiring_test.txt
   grep -c "TPPReauthenticator(" /tmp/wiring_test.txt  # MUST be ≥1
   grep -c "authenticateIfNeeded" /tmp/wiring_test.txt  # MUST be ≥1
   grep -c "withSignInModalSheetPresenter" /tmp/wiring_test.txt  # MUST be ≥1
   grep -c "AppContainer.production" /tmp/wiring_test.txt  # MUST be ≥1
   rm /tmp/wiring_test.txt
   ```

7. **No force unwraps in modified files:**
   ```bash
   for f in Palace/AppInfrastructure/DLNavigator.swift Palace/Network/TPPNetworkExecutor.swift \
            Palace/Holds/HoldsViewModel.swift Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift \
            Palace/Book/UI/BookDetail/BookDetailViewModel.swift Palace/MyBooks/MyBooksDownloadCenter.swift \
            Palace/MyBooks/TokenRefreshInterceptor.swift Palace/MyBooks/MyBooks/MyBooksViewModel.swift \
            Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift Palace/SignInLogic/SignInModalView.swift \
            PalaceTests/SignInLogic/SignInModalLifecycleTests.swift; do
     git diff origin/develop -- "$f" | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
   done
   # MUST return empty
   ```

8. **No `DispatchQueue.main.asyncAfter` introduced:**
   ```bash
   git diff origin/develop -- Palace/ PalaceTests/ | grep -E '^\+.*asyncAfter'
   # MUST be empty for files in this contract
   ```

9. **No new `.shared` reads in production migration code:**
   ```bash
   git diff origin/develop -- 'Palace/MyBooks/MyBooks/MyBooksViewModel.swift' \
                              'Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift' \
                              'Palace/Book/UI/BookDetail/BookDetailViewModel.swift' \
     | grep -E '^\+.*\.shared'
   # MUST be empty (AppContainer.production() is acceptable; system frameworks like NotificationCenter.default are allowed)
   ```

10. **Existing tests still green:**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalPredicateTests test  # 3 shouldAutoDismiss tests pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalLifecycleTests test  # all 5 wave-3 + 4 wave-4 tests pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalSAMLOIDCTests test
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/TPPReauthenticatorTests test
    xcodebuild ... -only-testing:PalaceTests/MyBooks/BorrowOperationTests test  # presenter-closure path
    xcodebuild ... -only-testing:PalaceTests/Book/BookDetailViewModelTests test
    xcodebuild ... -only-testing:PalaceTests/Holds/HoldsViewModelTests test
    ```

11. **Mutation kill-rate (critical path, CLAUDE.md DoD #5):**
    ```bash
    python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalView.swift \
      --tests PalaceTests/SignInLogic/SignInModalPredicateTests --diff-only --diff-base origin/develop
    python3 scripts/palace_mutate.py --file Palace/SignInLogic/TPPReauthenticator.swift \
      --tests PalaceTests/SignInLogic/SignInModalLifecycleTests --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped for each file. Paste `Killed: X / Y (Z%)` lines.

12. **Build + verify-pr (CLAUDE.md DoD #6):**
    ```bash
    scripts/verify-pr.sh --quick
    ```
    MUST PASS. Paste tails.

13. **Multi-step / wiring-claim check (CLAUDE.md DoD #7):**
    ```bash
    # Coverage report MUST show non-zero hits on TPPReauthenticator.authenticateIfNeeded body
    # from the new wiring test
    grep -c "testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam" \
      <coverage-report> # paste line
    ```

## Implementer prompt (one paragraph)

You are Module A implementer for `swarm_d8f11437` (wave 4 of the 3.2.0 close-out). Wave 3 (swarm_18b0d071) landed the `SignInModalSheetPresenter` foundation + AppContainer wiring + migrated ONE caller (`TPPReauthenticator`). Wave 4 finishes the migration: replace 11 `SignInModalPresenter.presentSignInModal*` static calls across 9 files (DLNavigator, TPPNetworkExecutor, HoldsViewModel, SignInModalPresenter+SignInModalPresenting, BookDetailViewModel, MyBooksDownloadCenter ×2, TokenRefreshInterceptor, MyBooksViewModel, BookCellModel ×2) with `AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { ... }` — per the table in the contract. Delete `final class SignInModalHostingController` from `Palace/SignInLogic/SignInModalView.swift:80-118` (wave 3 kept it as a tomb); rewire its callsite inside `SignInModalPresenter.presentSignInModal` with a fileprivate inline hosting subclass that preserves the `viewDidDisappear` + `presentingViewController == nil` once-after-fully-dismissed semantics (HelpSpot 17716 invariant). Delete the 4 `testShouldFireDismissCallback_*` tests in `SignInModalPredicateTests.swift` (lines 58-108); the 3 `testShouldAutoDismiss_*` tests STAY UNCHANGED. Add 3 new state-transition tests + 1 wiring test to `SignInModalLifecycleTests.swift` per the contract — the wiring test `testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam` MUST instantiate `TPPReauthenticator(`, call `authenticateIfNeeded(...)`, and route through Module B's `AppContainer.withSignInModalSheetPresenter(spy)` to verify the production driver hits the spy. This test closes wall-failure cs_9a267b63. Module B's `AppContainer.withSignInModalSheetPresenter(_:)` modifier is a hard dependency — coordinate the signature; do not modify `AppContainer.swift` (Module B owns it). Module C ships `scripts/check-test-name-vs-body.py` which the orchestrator runs at Phase 4.5 against your new test file — every PascalCase class-noun in your test method names MUST be instantiated in the body, or the script BLOCKS. If you cannot inject the spy into TPPReauthenticator without scope creep (the production seam currently reads `AppContainer.production().signInModalSheetPresenter` directly at line 57), the recommended path is a `#if DEBUG`-guarded `static var _testContainerOverride: AppContainer?` checked first; if even that is unacceptable, STOP with BLOCKED 3-option proposal. NO `Palace/Audiobooks/`, NO Module B file (`AppContainer.swift`), NO Module C files (`scripts/check-test-name-vs-body.py`, `SKILL.md`, `CLAUDE.md`), NO removal of the static `SignInModalPresenter` class itself (wave 5). Mutation kill-rate ≥80% diff-scoped on `SignInModalView.swift` and `TPPReauthenticator.swift`.
````

---

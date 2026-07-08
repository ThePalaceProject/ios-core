## Contract B — `.forgeos/swarms/swarm_51f248d5/contracts/B-SignInModal-SwiftUI.md`

```markdown
# Module B — SignInModal full SwiftUI refactor (Option A)

**Critical-path module.** Memory pin: `signin_modal_swiftui_refactor.md`. Handoff from PR #905. Keep `TPPSignInBusinessLogic` underneath; replace the UIKit `SignInModalHostingController` + `TPPPresentationUtils.safelyPresent` plumbing with a SwiftUI-native `.sheet(item:)`-driven presenter.

## Goal

Convert the current SignInModal presentation pipeline from the UIKit `SignInModalHostingController` + `TPPPresentationUtils.safelyPresent` plumbing to a native SwiftUI `.sheet(item:)`-bound presentation managed by a `@MainActor` SwiftUI presenter that lives in `AppContainer`. The `SignInModalView` (already SwiftUI) stays; `TPPSignInBusinessLogic` and `AccountDetailView` underneath stay; what changes is HOW the sheet is presented and dismissed — natively bound to SwiftUI state instead of imperatively pushed onto a UIKit presenter chain.

## Public types/protocols changing

ADD a new public protocol (or move `SignInModalPresenting` from PalaceAuth to this surface — but the simpler path is to keep PalaceAuth's protocol and add a SwiftUI-native peer):

```swift
@MainActor
protocol SignInModalSheetPresenting: ObservableObject {
    /// Triggers presentation of the sign-in sheet for the current library
    /// account. Completion fires AFTER the underlying SwiftUI sheet has
    /// fully dismissed (sheet binding flipped false + animation complete).
    func presentSignInModalForCurrentAccount(completion: @escaping () -> Void)

    /// Triggers presentation for a specific library account (e.g. legacy
    /// presentSignInModal(libraryAccountID:completion:) call sites).
    func presentSignInModal(libraryAccountID: String, completion: @escaping () -> Void)

    /// Published flag bound to the SwiftUI .sheet(isPresented:) modifier
    /// at the AppContainer scene root.
    var presentationState: SignInPresentationState? { get }
}

enum SignInPresentationState: Identifiable {
    case forCurrentAccount(completion: @MainActor () -> Void)
    case forSpecificAccount(libraryAccountID: String, completion: @MainActor () -> Void)
    var id: String { ... }
}
```

KEEP unchanged the static-bridge API `SignInModalPresenter.presentSignInModalForCurrentAccount(...)` and `SignInModalPresenter.presentSignInModal(...)` — they become thin façades that forward to the new SwiftUI presenter via `AppContainer.production().signInModalPresenter`. This means none of the 12 call sites' SIGNATURES change — only the presentation mechanism underneath. Migration is incremental.

KEEP unchanged `SignInModalView` SwiftUI body's contract: presents `AccountDetailView` under a `NavigationView`; auto-dismisses on `authState == .loggedIn`; cancel button dismisses without completion (completion fires from the presenter after sheet binding flips false).

REMOVE `SignInModalHostingController` (UIKit `UIHostingController` subclass) — no longer needed; SwiftUI's native sheet lifecycle replaces `viewDidDisappear`-based "did fully dismiss" detection.

## Internal seams

- `AppContainer` (read-only for Module B unless an additive injection is needed) — add a `signInModalPresenter: any SignInModalSheetPresenting` field, constructed in `AppContainer.production()`.
- Top-level SwiftUI scene root (e.g. `MainTabView` or whichever view hosts the app's root NavigationStack) — gets a `.sheet(item: $appContainer.signInModalPresenter.presentationState)` modifier that renders `SignInModalView` from the binding.
- `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift` adapter (line 33-52) — internal change only: `CoordinatorSignInModalPresenter.presentSignInModalForCurrentAccount()` now awaits on the SwiftUI presenter's completion instead of the static API directly. Signature unchanged.

## Test contracts

1. **EXISTING — must still pass unchanged:**
   - `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` (109 LOC; tests the static `shouldAutoDismiss` predicate) — keep verbatim. The predicate function stays on `SignInModalView`.
   - `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` (182 LOC) — keep verbatim.
   - `PalaceTests/Book/BookDetailViewModelTests.swift::*signInModal*` indirect tests — must still pass.
   - All `PalaceTests/MyBooks/BorrowOperation*Tests.swift` tests that drive `presentSignInModal` closures — must still pass.

2. **NEW — SwiftUI presentation lifecycle (3 tests, mandatory):**
   - `testSwiftUIPresenter_presentedThenBackgrounded_reFireOnForeground_doesNotDoublePresent` — drive `presenter.presentSignInModalForCurrentAccount(completion: ...)`; assert `presentationState != nil`; simulate scene-phase transition `.background` then `.foregrounded`; drive `presenter.presentSignInModalForCurrentAccount(...)` a SECOND time; assert exactly ONE `SignInPresentationState` is active. Kill case: removing the SwiftUI-native single-flight guard would observe two states.
   - `testSwiftUIPresenter_sheetDismissedViaSwipeDown_firesCompletion_oncePerPresentation` — drive `presenter.presentSignInModalForCurrentAccount(completion: { ... })`; flip the binding to nil (simulating SwiftUI swipe-down dismiss); assert completion fires EXACTLY once and `presentationState == nil` after. Kill case: a regression that fires completion on every binding write (e.g. on initial sheet present) would observe ≥2 completions.
   - `testSwiftUIPresenter_userCancelsMidAuth_completionFires_authStateUnchanged` — drive presentation; before `authState` transitions to `.loggedIn`, flip the binding to nil (cancel). Assert completion fires, `authState` stays at the value it had pre-presentation, and `presentationState` is reset. Kill case: a regression that auto-succeeds on cancel would observe `authState == .loggedIn` post-cancel.

3. **NEW — contract test pinning single-flight (1 test):** `testSwiftUIPresenter_concurrentRequests_collapse_toSinglePresentation`. Drive two `presentSignInModalForCurrentAccount` calls in rapid succession (e.g. from a `Task.detached` race). Assert: exactly one `presentationState` set; the second call's completion is queued (or short-circuited per the `isAccountSwitching` guard in `presentSignInModalForCurrentAccount` line 142-145).

4. **Migration regression net.** The 12 call sites listed in `files_scope` must still produce the same observable behavior — sign-in modal presents, user signs in or cancels, completion fires. The lift-and-shift is invisible to callers.

5. **Mutation kill-rate (critical path).** ≥80% diff-scoped on `Palace/SignInLogic/SignInModalView.swift` and the new SwiftUI presenter file. Run:
   ```bash
   python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalView.swift \
     --tests PalaceTests/SignInLogic/SignInModalLifecycleTests --diff-only --diff-base origin/develop
   ```

## Files scoped to THIS implementer

Production:
- `Palace/SignInLogic/SignInModalView.swift` (MODIFIED — keep SwiftUI body; remove `SignInModalHostingController`; rewire static API to forward to the new presenter)
- `Palace/SignInLogic/SignInModalSheetPresenter.swift` (NEW — `@MainActor ObservableObject` conforming to `SignInModalSheetPresenting`; published `presentationState`)
- `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift` (MODIFIED — adapter rewires to the new SwiftUI presenter internally; signature unchanged)
- `Palace/AppInfrastructure/AppContainer.swift` (MODIFIED — add `signInModalPresenter` field; wire `AppContainer.production()` to instantiate `SignInModalSheetPresenter`)
- Top-level scene root view (likely `Palace/AppInfrastructure/MainTabView.swift` or equivalent — verify path via `grep -rn "ContentView\|MainTab\|appContainer:" Palace/AppInfrastructure/` at the start of implementation) — MODIFIED to add `.sheet(item: $appContainer.signInModalPresenter.presentationState)` modifier
- The 12 call-site files — UNCHANGED in signature; ONLY change is that the static `SignInModalPresenter.presentSignInModalForCurrentAccount(...)` body now forwards to the new presenter. The 12 callers see no diff. (If a caller needs to await sheet dismissal explicitly, that's the existing `CoordinatorSignInModalPresenter` adapter's territory.)

Test:
- `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (NEW — the 4 lifecycle tests)
- `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` (UNCHANGED, must still pass)
- `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` (UNCHANGED, must still pass)

Tooling:
- `ruby scripts/pbxproj_add_swift.rb` for `Palace/SignInLogic/SignInModalSheetPresenter.swift` and `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` — Palace + Palace-noDRM targets for the production file, PalaceTests for the test file.

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/`, `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`, `Palace/Audiobooks/PlaybackReadinessGate.swift`, `Palace/Audiobooks/AudiobookSessionManager.swift`
- `ios-audiobooktoolkit/`
- `worktree-refactor-saml-auth` continuation files

**Off-limits per swarm overlap resolution (Module A owns):**
- `Palace/Accounts/Library/Account+State.swift`
- `Palace/Accounts/Library/AccountStateStore.swift`
- `Palace/Accounts/Library/AccountsManager.swift`
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift`
- `PalaceTests/Accounts/AccountStateMachineTests.swift`
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`

**Off-limits per swarm overlap resolution (Module C owns):**
- `CLAUDE.md`, `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md`
- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md`
- `.forgeos/wall-failures/derived-improvements.md`

**Read-only for Module B (these files reference `SignInModalView` via the static API, not direct construction; sign-up does NOT need to be touched unless the static-API signature changes — which it does NOT):**
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift`
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinatorSeams.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorWiringTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthTelemetryEmissionTests.swift`

## Verification criteria (MANDATORY)

1. **New file exists with the expected SUT class name (CLAUDE.md DoD check #1):**
   ```bash
   test -f Palace/SignInLogic/SignInModalSheetPresenter.swift
   grep -c "final class SignInModalSheetPresenter" Palace/SignInLogic/SignInModalSheetPresenter.swift
   ```
   File MUST exist; grep MUST return 1.

2. **New protocol declared:**
   ```bash
   grep -cE "protocol SignInModalSheetPresenting" Palace/SignInLogic/SignInModalSheetPresenter.swift
   grep -cE "enum SignInPresentationState" Palace/SignInLogic/SignInModalSheetPresenter.swift
   ```
   Both MUST return 1.

3. **UIKit hosting controller removed:**
   ```bash
   grep -c "class SignInModalHostingController" Palace/SignInLogic/SignInModalView.swift
   grep -c "SignInModalHostingController" Palace/SignInLogic/
   ```
   First MUST return 0 (class removed). Second MUST return 0 across the SignInLogic directory.

4. **No `TPPPresentationUtils.safelyPresent` in updated SignInModalPresenter:**
   ```bash
   grep -c "TPPPresentationUtils.safelyPresent" Palace/SignInLogic/SignInModalView.swift
   ```
   MUST return 0 (the UIKit imperative present is gone).

5. **AppContainer wiring:**
   ```bash
   grep -c "signInModalPresenter" Palace/AppInfrastructure/AppContainer.swift
   ```
   MUST return ≥1 (the field is declared and initialized).

6. **Top-level scene `.sheet(item:)` modifier added:**
   ```bash
   grep -rnE "\.sheet\(item:.*signInModalPresenter|\.sheet\(item:.*presentationState" Palace/AppInfrastructure/
   ```
   MUST return ≥1.

7. **The 12 call sites compile unchanged (signature-stability check):**
   ```bash
   grep -cE "SignInModalPresenter\.presentSignInModal(ForCurrentAccount)?\(" Palace/ -r --include="*.swift"
   ```
   MUST return 12 (the call-site COUNT is unchanged from baseline — no callers added or removed).

8. **`try await`/`await` boundary clause (from wall-failure fix #1):** for the NEW `await` boundaries inside `CoordinatorSignInModalPresenter.presentSignInModalForCurrentAccount` (the `withCheckedContinuation` flow) AND any new `await presenter.presentSignInModalForCurrentAccount` calls, the contract MUST include a grep showing a test drives that exact line. Example:
   ```bash
   grep -nE "await .+\.presentSignInModalForCurrentAccount\(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
   ```
   MUST return ≥1 line in the body of `testSwiftUIPresenter_sheetDismissedViaSwipeDown_firesCompletion_oncePerPresentation`. If no `await` test boundary exercises the line, STOP with BLOCKED + scope-deferral.

9. **SUT-instantiation grep (CLAUDE.md DoD check #1) — the new test file's name claims to test `SignInModalSheetPresenter`:**
   ```bash
   grep -c "SignInModalSheetPresenter(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
   ```
   MUST return ≥1.

10. **Multi-step test body check (CLAUDE.md DoD check #3) — for `testSwiftUIPresenter_presentedThenBackgrounded_reFireOnForeground_doesNotDoublePresent`:** the test name claims a multi-step path (`presented → backgrounded → re-fire`). Body MUST contain literal calls for each step:
    ```bash
    grep -cE "scenePhase|\.background|\.foreground|presentSignInModalForCurrentAccount" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
    ```
    MUST return ≥3 (one per step). The test body MUST call `presentSignInModalForCurrentAccount` TWICE (the second call simulates the "re-fire" half).

11. **No new `.shared` reads in production:**
    ```bash
    git diff origin/develop -- 'Palace/SignInLogic/*.swift' | grep -E '^\+.*\.shared'
    ```
    MUST return empty (or only documented system-framework `.shared()` calls).

12. **No force unwraps:**
    ```bash
    git diff origin/develop -- 'Palace/SignInLogic/*.swift' 'PalaceTests/SignInLogic/SignInModal*.swift' | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
    ```
    Should return empty.

13. **No `DispatchQueue.main.asyncAfter` workarounds:**
    ```bash
    git diff origin/develop -- 'Palace/SignInLogic/*.swift' | grep -E '^\+.*asyncAfter'
    ```
    MUST be empty.

14. **Existing tests still green (regression net):**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalPredicateTests test 2>&1 | grep -E "Test Suite '.*' passed"
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalSAMLOIDCTests test 2>&1 | grep -E "Test Suite '.*' passed"
    xcodebuild ... -only-testing:PalaceTests/MyBooks/BorrowOperationTests test 2>&1 | grep -E "Test Suite '.*' passed"
    xcodebuild ... -only-testing:PalaceTests/MyBooks/BorrowOperationAuthCoordinatorTests test 2>&1 | grep -E "Test Suite '.*' passed"
    ```
    All MUST report passed.

15. **Mutation kill-rate (critical path):**
    ```bash
    python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalView.swift \
      --tests PalaceTests/SignInLogic/SignInModalLifecycleTests --diff-only --diff-base origin/develop
    python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalSheetPresenter.swift \
      --tests PalaceTests/SignInLogic/SignInModalLifecycleTests --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped. Paste `Killed: X / Y (Z%)` lines.

## Definition of Done evidence (paste before declaring READY — 6 checks)

1. **SUT instantiation check:** `grep -c "SignInModalSheetPresenter(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` ≥1.
2. **Function-result usage check:** the new `CoordinatorSignInModalPresenter.presentSignInModalForCurrentAccount()` MUST return the credential-check result; the call-site at PalaceAuth's `AuthCoordinator.swift:371` ALREADY uses `let success = await modalPresenter.presentSignInModalForCurrentAccount()` — verify nothing in the migration breaks that.
3. **Multi-step test body check:** the 3 new SwiftUI-lifecycle tests with `presentedThenBackgrounded`, `dismissedViaSwipeDown`, `userCancelsMidAuth` names each drive the literal multi-step path.
4. **Scope coverage audit:** all 12 call sites verified compile-clean with no signature change.
5. **Mutation pass:** ≥50% (target ≥80%; critical-path) on `SignInModalView.swift` + `SignInModalSheetPresenter.swift`. Paste output.
6. **Build + verify-pr:** `scripts/verify-pr.sh --quick` PASS. Paste tails.

## Implementer prompt (one paragraph)

You are Module B implementer for `swarm_51f248d5`. The current `SignInModal` pipeline already has a SwiftUI view (`SignInModalView`) but uses a UIKit `SignInModalHostingController` + `TPPPresentationUtils.safelyPresent(vc, ...)` to present it; dismissal uses `viewDidDisappear` + `presentingViewController == nil` to detect "fully dismissed." This is Option A's target for the full SwiftUI refactor: rewire the presentation to a native SwiftUI `.sheet(item: $presenter.presentationState)` modifier on the scene-root view, keep `TPPSignInBusinessLogic` underneath unchanged, and keep all 12 call sites' SIGNATURES unchanged (the static `SignInModalPresenter` API stays as a façade that forwards to the new SwiftUI presenter). Add a new `@MainActor ObservableObject` SignInModalSheetPresenter in `Palace/SignInLogic/SignInModalSheetPresenter.swift`. Remove `SignInModalHostingController`. Add three NEW SwiftUI presentation-lifecycle tests in `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (backgrounded-and-re-foregrounded, swipe-down dismissal, user-cancel-mid-auth). Existing `SignInModalPredicateTests` and `SignInModalSAMLOIDCTests` MUST still pass unchanged. Use `ruby scripts/pbxproj_add_swift.rb` for new Swift files. NO `Palace/Audiobooks/`, NO `Palace/Accounts/Library/`, NO `Palace/AgeCheck/`. NO docs edits (Module C). Critical-path mutation kill-rate ≥80% diff-scoped on `SignInModalView.swift` AND the new presenter file. If you discover the top-level SwiftUI scene root needs deeper changes than a single `.sheet(item:)` modifier (e.g. a UIKit `UINavigationController` is still at the root and there's no SwiftUI scene to attach to), STOP and escalate — full SwiftUI scene-rooting is a separate scope beyond this contract.
```

---

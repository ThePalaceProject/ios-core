## Contract A — `.forgeos/swarms/swarm_18b0d071/contracts/A-SignInModal-SheetPresenter.md`

````markdown
# Module A — SignInModal SwiftUI presenter foundation (wave 3 / part 1 of 2)

**Critical-path module.** Risk: regressions hit users on every sign-in / re-auth / borrow. Architect + SoD (qa_test + clean_code) review required. Wave 4 ships the consumer migration; wave 3 ships the presenter + 1 caller (`TPPReauthenticator`) to prove the pattern.

## Resolved blockers from wave 2

- **Blocker 1 — `SignInModalHostingController` removal vs predicate tests:** RESOLVED Option (a) — DELETE the hosting controller and the 5 `shouldFireDismissCallback` predicate-test bodies, BUT not in wave 3. The deletion is deferred to wave 4 once all callers are migrated. Wave 3 contract: `SignInModalHostingController` STAYS unchanged. The 5 existing predicate tests stay green unchanged. The new 3 SwiftUI-lifecycle tests test the NEW presenter, NOT the old hosting controller.
- **Blocker 2 — Sheet host location:** RESOLVED Option (c) — keep `TPPPresentationUtils.safelyPresent` as the actual presentation mechanism. The new `SignInModalSheetPresenter` exposes a SwiftUI-observable `@Published presentationState` but internally drives `safelyPresent` so HelpSpot 17716's presenter-chain safety net stays intact.
- **Blocker 3 — 600-900 LOC strategy:** RESOLVED Option (b) — two stacked passes. Wave 3 ships the foundation; wave 4 ships the migration.

## Goal

Introduce a `@MainActor ObservableObject SignInModalSheetPresenter` in `Palace/SignInLogic/SignInModalSheetPresenter.swift` that:
1. Exposes `@Published var presentationState: SignInPresentationState?` for SwiftUI consumers to observe presentation lifecycle.
2. Internally routes `presentSignInModalForCurrentAccount(completion:)` and `presentSignInModal(libraryAccountID:completion:)` through the existing `SignInModalPresenter.presentSignInModal(libraryAccountID:appContainer:completion:)` static API, which uses `TPPPresentationUtils.safelyPresent` (HelpSpot 17716 safety net preserved).
3. Sets `presentationState = .forCurrentAccount(...)` before calling the static API; clears `presentationState = nil` from the completion handler **after** dismissal completes (the existing `SignInModalHostingController.onDidFullyDismiss` callback fires it).
4. Wired into `AppContainer.production()` as `signInModalSheetPresenter: SignInModalSheetPresenter`.
5. `TPPReauthenticator` migrates to use `appContainer.signInModalSheetPresenter.presentSignInModalForCurrentAccount(completion:)` instead of the static `SignInModalPresenter.presentSignInModalForCurrentAccount` directly.

The other 9 callers stay on the static API. They will migrate in wave 4.

## Public types/protocols changing

ADD:
```swift
@MainActor
public protocol SignInModalSheetPresenting: ObservableObject {
    var presentationState: SignInPresentationState? { get }
    func presentSignInModalForCurrentAccount(completion: (() -> Void)?)
    func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?)
}

public enum SignInPresentationState: Identifiable, Equatable {
    case forCurrentAccount
    case forSpecificAccount(libraryAccountID: String)

    public var id: String {
        switch self {
        case .forCurrentAccount: return "current"
        case .forSpecificAccount(let id): return "specific:\(id)"
        }
    }
}

@MainActor
public final class SignInModalSheetPresenter: NSObject, SignInModalSheetPresenting, ObservableObject {
    @Published public private(set) var presentationState: SignInPresentationState?
    public init(appContainer: AppContainer)
    public func presentSignInModalForCurrentAccount(completion: (() -> Void)?)
    public func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?)
}
```

ADD to `AppContainer`:
```swift
public let signInModalSheetPresenter: SignInModalSheetPresenter  // wired in production()
```

MODIFY `TPPReauthenticator.authenticateIfNeeded`:
```swift
// BEFORE
SignInModalPresenter.presentSignInModalForCurrentAccount { ... }
// AFTER
AppContainer.production().signInModalSheetPresenter.presentSignInModalForCurrentAccount { ... }
```

UNCHANGED:
- `SignInModalView` SwiftUI body, predicate `shouldAutoDismiss`, cancel button.
- `SignInModalHostingController` — STAYS as-is (wave 4 deletion).
- The static `SignInModalPresenter.presentSignInModalForCurrentAccount` / `presentSignInModal` — STAYS as-is. The new sheet presenter forwards INTO it; callers other than `TPPReauthenticator` keep calling the static API directly.
- `CoordinatorSignInModalPresenter` (PalaceAuth's `SignInModalPresenting` adapter) — UNCHANGED.
- `SignInModalPredicateTests.swift` — UNCHANGED, must still pass.

## Internal seams

- `SignInModalSheetPresenter.init(appContainer:)` holds a weak reference to `appContainer.accountsManager` and reads `currentAccountId` at presentation time.
- `presentationState` published property: set to `.forCurrentAccount` or `.forSpecificAccount(...)` **before** invoking the static API; cleared to `nil` from the completion callback **after** `SignInModalHostingController.onDidFullyDismiss` fires (which currently runs `isPresenting = false; completion?()`).
- Single-flight guard: re-uses the existing `SignInModalPresenter.isPresenting` static guard; the new presenter does NOT add a parallel guard. This means concurrent `presenter.presentSignInModalForCurrentAccount` calls collapse to one presentation just like the static API does today.

## Test contracts

### EXISTING — must still pass unchanged
- `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` — all 7 tests (109 LOC). The 5 `shouldFireDismissCallback` tests stay because `SignInModalHostingController` stays in wave 3.
- `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` — 6 tests (182 LOC).
- All `PalaceTests/MyBooks/BorrowOperation*Tests.swift` indirect tests via `SignInModalPresenter` static API closures.
- `PalaceTests/Book/BookDetailViewModelTests.swift` indirect tests.

### NEW — `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (3 tests, mandatory)

1. `testSheetPresenter_presentsForCurrentAccount_publishesStateThenClearsOnCompletion`
   - **Multi-step claim per CLAUDE.md DoD #3:** "presents → publishes → clears on completion" — body MUST literally drive each step.
   - Arrange: construct `SignInModalSheetPresenter(appContainer:)` with a test container whose `accountsManager.currentAccountId` returns a fixture library ID. Capture `presenter.presentationState` via Combine sink into an array.
   - Act: call `presenter.presentSignInModalForCurrentAccount { ... }`. Then simulate the underlying `SignInModalPresenter.isPresenting = false` reset + completion fire (test seam: re-route the static API through a test double or assert the state-publish ordering via the published property's stream).
   - Assert: the published state stream is `[nil, .forCurrentAccount, nil]` in order; the completion fires exactly once; `presenter.presentationState` is `nil` at the end.
   - Kill case: removing the `presentationState = nil` clear in the completion would observe `[nil, .forCurrentAccount]` (no final nil).

2. `testSheetPresenter_presentSpecificAccount_publishesStateWithLibraryID`
   - Arrange: construct the presenter; capture state sink.
   - Act: call `presenter.presentSignInModal(libraryAccountID: "test-lib-123") { ... }`.
   - Assert: the state stream contains `.forSpecificAccount(libraryAccountID: "test-lib-123")`; the `.id` value is `"specific:test-lib-123"`; completion fires once.
   - Kill case: a regression that swaps the libraryAccountID arg with a hardcoded value would observe a mismatched `id`.

3. `testSheetPresenter_concurrentCallsCollapseToOnePresentation_perSingleFlightGuard`
   - **Multi-step claim per CLAUDE.md DoD #3:** "concurrent calls collapse" — body MUST drive two calls and observe single presentation.
   - Arrange: construct the presenter; capture state sink; mock `currentAccountId` to non-nil.
   - Act: call `presenter.presentSignInModalForCurrentAccount` twice in rapid succession (`Task.detached` + `Task.detached`).
   - Assert: `presentationState` is set exactly once (state stream = `[nil, .forCurrentAccount, nil]`, NOT `[nil, .forCurrentAccount, nil, .forCurrentAccount, nil]`); both completion closures fire (the second one fires immediately because `SignInModalPresenter.isPresenting` was already true so the static API's guard short-circuits and synchronously calls the completion-less path — but the wave-3 presenter MUST handle this case by completing the queued completion off the existing presentation).
   - Kill case: a regression that calls `safelyPresent` twice would observe two `.forCurrentAccount` states.
   - **NOTE:** if the static API's `isPresenting` guard returns early WITHOUT calling completion (current behavior — line 138-141 of `SignInModalView.swift`), this test must verify the presenter handles that case. Implementer should add a presenter-internal queue of pending completions that fires on `presentationState` transition to nil. If implementer determines this requires changes to the static API beyond contract scope, STOP with BLOCKED.

### `try await` / `await` boundary clause

If the implementer needs an `async` variant of the presenter (e.g. `func presentSignInModalForCurrentAccount() async -> Bool` to match `CoordinatorSignInModalPresenter`), that's OUT OF SCOPE for wave 3 — the existing `CoordinatorSignInModalPresenter` already wraps `withCheckedContinuation` and stays as-is. If you find yourself adding `async` to the new presenter, STOP. The whole point of wave-3-as-foundation is to keep the API surface tiny.

If the existing `await modalPresenter.presentSignInModalForCurrentAccount()` call site in `PalaceAuth/AuthCoordinator.swift:371` needs ANY change (it shouldn't — the wrapper class stays unchanged), STOP with BLOCKED.

## Files scoped to THIS implementer

**Production NEW:**
- `Palace/SignInLogic/SignInModalSheetPresenter.swift` (`final class` + `SignInModalSheetPresenting` protocol + `SignInPresentationState` enum)

**Production MODIFIED:**
- `Palace/AppInfrastructure/AppContainer.swift` — add `signInModalSheetPresenter` field; wire in `production()`
- `Palace/SignInLogic/TPPReauthenticator.swift` — replace `SignInModalPresenter.presentSignInModalForCurrentAccount` direct call with `appContainer.signInModalSheetPresenter.presentSignInModalForCurrentAccount`

**Production MODIFIED (minimal — make the existing static API completion observable):**
- `Palace/SignInLogic/SignInModalView.swift` — possibly add a small internal hook so `SignInModalSheetPresenter` can observe completion + dismissal. IF the implementer determines they can implement the presenter purely by passing the completion closure through, no change to this file. IF a hook is needed, it must be a single new `internal` extension method that does NOT alter the existing `presentSignInModal` / `presentSignInModalForCurrentAccount` static API signatures. STOP with BLOCKED if a signature change is required.

**Test NEW:**
- `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (3 tests above)

**Tooling:**
- `ruby scripts/pbxproj_add_swift.rb` for `Palace/SignInLogic/SignInModalSheetPresenter.swift` (Palace + Palace-noDRM targets) and `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (PalaceTests target).

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/`, `ios-audiobooktoolkit/`
- `worktree-refactor-saml-auth` contents
- `CLAUDE.md`, `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md`

**Off-limits per Module B ownership:**
- `Palace/SignInLogic/LegacySAMLAuthAdapter.swift`
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift`
- `Palace/SignInLogic/TPPSignInBusinessLogic+SAML.swift`
- `Palace/Accounts/Library/AccountsManager.swift`
- `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift`

**Off-limits per wave-4 deferral (explicit per Blocker 3 Option b):**
- `Palace/Network/TPPNetworkExecutor.swift`  (caller — wave 4 migrates)
- `Palace/Holds/HoldsViewModel.swift`  (caller — wave 4 migrates)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`  (caller — wave 4 migrates)
- `Palace/MyBooks/MyBooksDownloadCenter.swift`  (caller — wave 4 migrates)
- `Palace/MyBooks/BorrowOperation.swift`  (caller — wave 4 migrates)
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift`  (caller — wave 4 migrates)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift`  (caller — wave 4 migrates)
- `Palace/MyBooks/TokenRefreshInterceptor.swift`  (caller — wave 4 migrates)
- `Palace/AppInfrastructure/DLNavigator.swift`  (caller — wave 4 migrates)
- `Palace/SignInLogic/SignInModalView.swift` — `class SignInModalHostingController` deletion (wave 4)

**Read-only for Module A:**
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` (line 371 `await modalPresenter.presentSignInModalForCurrentAccount()` MUST still work; CoordinatorSignInModalPresenter wraps the static API and is unchanged)

## Verification criteria (MANDATORY — all 7 DoD checks)

1. **SUT instantiation check (CLAUDE.md DoD #1):**
   ```bash
   test -f Palace/SignInLogic/SignInModalSheetPresenter.swift
   grep -c "final class SignInModalSheetPresenter" Palace/SignInLogic/SignInModalSheetPresenter.swift  # MUST be 1
   grep -c "SignInModalSheetPresenter(" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥1
   ```

2. **Protocol + enum declared:**
   ```bash
   grep -cE "protocol SignInModalSheetPresenting" Palace/SignInLogic/SignInModalSheetPresenter.swift  # MUST be 1
   grep -cE "enum SignInPresentationState" Palace/SignInLogic/SignInModalSheetPresenter.swift  # MUST be 1
   ```

3. **AppContainer wired:**
   ```bash
   grep -c "signInModalSheetPresenter" Palace/AppInfrastructure/AppContainer.swift  # MUST be ≥2 (declaration + production() init)
   ```

4. **TPPReauthenticator migrated:**
   ```bash
   grep -c "signInModalSheetPresenter.presentSignInModalForCurrentAccount" Palace/SignInLogic/TPPReauthenticator.swift  # MUST be 1
   grep -c "SignInModalPresenter.presentSignInModalForCurrentAccount" Palace/SignInLogic/TPPReauthenticator.swift  # MUST be 0
   ```

5. **9 other callers UNCHANGED (signature-stability):**
   ```bash
   grep -rcE "SignInModalPresenter\.presentSignInModal(ForCurrentAccount)?\(" Palace/ --include="*.swift" | awk -F: '{sum+=$2} END {print sum}'
   # MUST be 9 (was 10 baseline; TPPReauthenticator's 1 call moved to sheet presenter; the other 9 stayed)
   ```

6. **`try await` boundary clause (PR #1022 contract clause):**
   ```bash
   # Verify NO new try/await boundary in production
   git diff origin/develop -- 'Palace/SignInLogic/SignInModalSheetPresenter.swift' 'Palace/SignInLogic/TPPReauthenticator.swift' | grep -E '^\+.*try await|^\+.*await ' | grep -v '// '
   # SHOULD return empty (wave 3 ships sync API only; async wrapper stays in CoordinatorSignInModalPresenter unchanged)
   ```

7. **Multi-step test body check (CLAUDE.md DoD #3):**
   ```bash
   # testSheetPresenter_presentsForCurrentAccount_publishesStateThenClearsOnCompletion claims "presents → publishes → clears"
   grep -cE "presentSignInModalForCurrentAccount|presentationState" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥6 (2 calls × 3 tests)
   # testSheetPresenter_concurrentCallsCollapseToOnePresentation_perSingleFlightGuard claims "concurrent" — must have TWO Task.detached calls
   grep -cE "Task\.detached|Task \{" PalaceTests/SignInLogic/SignInModalLifecycleTests.swift  # MUST be ≥2
   ```

8. **Function-result usage check (CLAUDE.md DoD #2) — N/A:** the new methods return Void; no result to bind.

9. **No force unwraps:**
   ```bash
   git diff origin/develop -- 'Palace/SignInLogic/SignInModalSheetPresenter.swift' 'Palace/SignInLogic/TPPReauthenticator.swift' 'PalaceTests/SignInLogic/SignInModalLifecycleTests.swift' | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
   # SHOULD return empty
   ```

10. **No `DispatchQueue.main.asyncAfter` workarounds:**
    ```bash
    git diff origin/develop -- 'Palace/SignInLogic/SignInModalSheetPresenter.swift' | grep -E '^\+.*asyncAfter'
    # MUST be empty
    ```

11. **No new `.shared` reads in production:**
    ```bash
    git diff origin/develop -- 'Palace/SignInLogic/SignInModalSheetPresenter.swift' | grep -E '^\+.*\.shared'
    # MUST be empty (system-framework `.shared` like `NotificationCenter.default` are allowed; `AppContainer.production()` is acceptable for the singleton root)
    ```

12. **Existing tests still green:**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalPredicateTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalSAMLOIDCTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/MyBooks/BorrowOperationTests test  # MUST pass
    xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalLifecycleTests test  # MUST pass (the new file)
    ```

13. **Mutation kill-rate (critical path, CLAUDE.md DoD #5):**
    ```bash
    python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalSheetPresenter.swift \
      --tests PalaceTests/SignInLogic/SignInModalLifecycleTests --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped. Paste `Killed: X / Y (Z%)` lines.

14. **Build + verify-pr (CLAUDE.md DoD #6):**
    ```bash
    scripts/verify-pr.sh --quick
    ```
    MUST PASS. Paste tails.

## Implementer prompt (one paragraph)

You are Module A implementer for `swarm_18b0d071` (wave 3, part 1 of 2 of the SignInModal SwiftUI refactor). Wave 2 BLOCKED with 3 architectural questions — the architect has resolved them: Blocker 1 → delete in wave 4 (not this swarm; HostingController stays); Blocker 2 → keep `TPPPresentationUtils.safelyPresent` as the actual presentation mechanism, wrap it in a SwiftUI-observable presenter facade; Blocker 3 → two-pass strategy, this wave ships the foundation only. Add `Palace/SignInLogic/SignInModalSheetPresenter.swift` containing a `final class SignInModalSheetPresenter: NSObject, SignInModalSheetPresenting, ObservableObject` with a `@Published var presentationState: SignInPresentationState?` and two methods (`presentSignInModalForCurrentAccount(completion:)`, `presentSignInModal(libraryAccountID:completion:)`) that route to the existing static `SignInModalPresenter` API while publishing state transitions. Wire it into `AppContainer.production()` as `signInModalSheetPresenter`. Migrate ONE caller — `TPPReauthenticator.swift` line 54 — to use the new presenter via `AppContainer.production().signInModalSheetPresenter`. DO NOT touch the other 9 callers (wave 4). DO NOT remove `SignInModalHostingController` (wave 4). DO NOT change `CoordinatorSignInModalPresenter` (PalaceAuth's adapter — must continue to compile unchanged because `await modalPresenter.presentSignInModalForCurrentAccount()` at AuthCoordinator.swift:371 depends on its async signature). Add 3 new tests in `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` (state-stream, libraryAccountID propagation, concurrent-collapse). Use `ruby scripts/pbxproj_add_swift.rb` for new Swift files. Mutation kill-rate ≥80% diff-scoped on `SignInModalSheetPresenter.swift`. If you discover you need to alter the static `SignInModalPresenter.presentSignInModal` / `presentSignInModalForCurrentAccount` signatures or the SignInModalHostingController completion shape to make state-publish work, STOP with BLOCKED — the architect explicitly chose "wrap, don't rewrite" for wave 3. NO `Palace/Audiobooks/`, NO Module B files (`LegacySAMLAuthAdapter.swift`, `TPPSignInBusinessLogic.swift`, `AccountsManager.swift`, `TPPSAMLFlowTests.swift`).
````

---

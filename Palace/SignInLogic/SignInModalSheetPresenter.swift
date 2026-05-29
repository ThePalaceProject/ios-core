//
//  SignInModalSheetPresenter.swift
//  Palace
//
//  swarm_18b0d071 Module A — SignInModal SwiftUI presenter foundation
//  (wave 3 / part 1 of 2).
//
//  A `@MainActor ObservableObject` facade over the existing static
//  `SignInModalPresenter` API. Exposes `@Published presentationState`
//  for SwiftUI consumers; internally routes through the static API,
//  which uses `TPPPresentationUtils.safelyPresent` to actually mount
//  the modal — preserving the HelpSpot 17716 presenter-chain safety
//  net (Blocker 2 Option c, resolved in the swarm contract).
//
//  Wave 3 ships:
//   - This file (presenter + protocol + state enum + driver typealias).
//   - AppContainer wiring (`signInModalSheetPresenter`).
//   - Migration of ONE caller: `TPPReauthenticator`. The other 9
//     callers stay on the static API; wave 4 migrates them.
//   - `SignInModalHostingController` STAYS in wave 3; deletion is
//     deferred to wave 4 once all callers are migrated.
//
//  Tests: `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift`.
//

import Combine
import Foundation
import SwiftUI
import PalaceLogging

// MARK: - SignInPresentationState

/// SwiftUI-observable representation of the sign-in modal's
/// presentation state. Conforms to `Identifiable` so SwiftUI `.sheet(
/// item:)` bindings can pin the presentation against a stable id —
/// even though wave 3 does NOT yet use a SwiftUI sheet binding for the
/// actual presentation (that's wave 4), the API is shaped to support
/// it without a follow-up source change.
enum SignInPresentationState: Identifiable, Equatable {
    /// Sign-in modal for the currently-selected library account.
    case forCurrentAccount
    /// Sign-in modal for a specific library account, identified by
    /// its `libraryAccountID` (typically a UUID string).
    case forSpecificAccount(libraryAccountID: String)

    var id: String {
        switch self {
        case .forCurrentAccount:
            return "current"
        case .forSpecificAccount(let libraryAccountID):
            return "specific:\(libraryAccountID)"
        }
    }
}

// MARK: - SignInModalPresentationDriver

/// Indirection seam for unit-tests. The production default routes
/// through the existing static `SignInModalPresenter.presentSignInModal`
/// API; tests inject a fake to avoid mounting UIKit. The driver MUST
/// fire the completion exactly once after the underlying modal
/// dismisses fully (production driver wires this through
/// `SignInModalHostingController.onDidFullyDismiss` for free —
/// guarantee preserved).
typealias SignInModalPresentationDriver = (
    _ libraryAccountID: String,
    _ appContainer: AppContainer,
    _ completion: @escaping () -> Void
) -> Void

// MARK: - SignInModalSheetPresenting

/// Protocol surface for SwiftUI consumers. Wave 3 surface is sync
/// (the legacy completion-closure shape — preserves compatibility
/// with the 10 existing call sites the static API has today). Wave 4
/// is expected to layer an async variant if needed.
@MainActor
protocol SignInModalSheetPresenting: ObservableObject {
    var presentationState: SignInPresentationState? { get }
    func presentSignInModalForCurrentAccount(completion: (() -> Void)?)
    func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?)
}

// MARK: - SignInModalSheetPresenter

@MainActor
final class SignInModalSheetPresenter: NSObject, SignInModalSheetPresenting, ObservableObject {

    /// SwiftUI-observable presentation state. `nil` when no modal is
    /// in flight. Set immediately before invoking the driver, cleared
    /// from the driver's completion (which fires after the UIKit
    /// dismissal transition completes — see
    /// `SignInModalHostingController.onDidFullyDismiss`).
    @Published private(set) var presentationState: SignInPresentationState?

    /// Strong reference to the app container. Used so the driver can
    /// receive the same container the presenter was built with (the
    /// static API needs it for `accountsManager.isAccountSwitching`
    /// and the `userAccount(for:)` look-up). Held strongly because
    /// the presenter is itself held by the container — see
    /// `AppContainer._cached`.
    private let appContainer: AppContainer

    /// Resolves the current library account id at present-time.
    /// Reading `accountsManager.currentAccountId` at present-time
    /// (rather than init-time) ensures library switches between
    /// container construction and modal presentation are observed.
    /// Production default: `appContainer.accountsManager.currentAccountId`.
    /// Tests inject a custom closure.
    private let currentAccountIDProvider: () -> String?

    /// Predicate that decides whether a given library account needs
    /// the sign-in form (basic / oauth / saml / oidc / token →
    /// `true`; anonymous / coppa / none → `false`). Mirrors the
    /// `!userAccount.needsAuth` short-circuit at SignInModalView.swift:189.
    /// Production default reads from `accountsManager.userAccount(for:).needsAuth`.
    private let needsAuthProvider: (String) -> Bool

    /// The actual presentation function. Production default forwards
    /// to `SignInModalPresenter.presentSignInModal(libraryAccountID:appContainer:completion:)`
    /// which calls `TPPPresentationUtils.safelyPresent`. Tests inject
    /// a fake.
    private let driver: SignInModalPresentationDriver

    /// In-flight guard. The static API already has its own
    /// `isPresenting` static guard — this guard is the SwiftUI-state
    /// counterpart and prevents duplicate `.forCurrentAccount`
    /// publish-clear cycles when concurrent callers race. Together
    /// they guarantee one UIKit presentation per logical flow.
    private var inFlight: Bool = false

    init(appContainer: AppContainer,
         currentAccountIDProvider: @escaping () -> String?,
         needsAuthProvider: @escaping (String) -> Bool,
         driver: @escaping SignInModalPresentationDriver = SignInModalSheetPresenter.productionDriver) {
        self.appContainer = appContainer
        self.currentAccountIDProvider = currentAccountIDProvider
        self.needsAuthProvider = needsAuthProvider
        self.driver = driver
        super.init()
    }

    /// Production-default convenience initializer used by
    /// `AppContainer.production()`. Wires the providers to the
    /// container's `accountsManager` and the production driver.
    ///
    /// `accountsManager` is held strongly via the closure capture —
    /// matches the static API's existing default-arg pattern
    /// (`accountsManager: AccountsManager = AppContainer.production().accountsManager`),
    /// and the presenter itself is held by AppContainer so a
    /// nilling-out path can't actually occur in production. Eliminating
    /// the `[weak am]` capture also keeps the mutation surface small
    /// (no `guard let else { return false }` fallback to harden).
    convenience init(appContainer: AppContainer) {
        let accountsManager = appContainer.accountsManager
        self.init(
            appContainer: appContainer,
            currentAccountIDProvider: { accountsManager.currentAccountId },
            needsAuthProvider: { libraryID in
                accountsManager.userAccount(for: libraryID).needsAuth
            },
            driver: SignInModalSheetPresenter.productionDriver
        )
    }

    // MARK: SignInModalSheetPresenting

    /// Presents the sign-in modal for the currently-selected library.
    /// Mirrors the static
    /// `SignInModalPresenter.presentSignInModalForCurrentAccount`
    /// short-circuit semantics:
    ///   - `currentAccountId == nil` → fire completion, no presentation.
    ///   - account has no auth form (anonymous/coppa) → fire completion,
    ///     no presentation (SQ-005).
    ///   - otherwise: publish `.forCurrentAccount`, drive the modal,
    ///     clear state and fire completion on dismissal.
    func presentSignInModalForCurrentAccount(completion: (() -> Void)?) {
        guard let libraryID = currentAccountIDProvider() else {
            // No account selected — fire completion and bail without
            // publishing state.
            completion?()
            return
        }
        guard needsAuthProvider(libraryID) else {
            // Anonymous library / COPPA — no form to render. Fire
            // completion synchronously (matches the static API's
            // semantics at SignInModalView.swift:189).
            Log.info(#file, "Skipping sign-in modal — library \(libraryID) does not require authentication")
            completion?()
            return
        }
        present(state: .forCurrentAccount, libraryID: libraryID, completion: completion)
    }

    /// Presents the sign-in modal for a specific library account.
    func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?) {
        present(state: .forSpecificAccount(libraryAccountID: libraryAccountID),
                libraryID: libraryAccountID,
                completion: completion)
    }

    // MARK: Internal

    /// Shared implementation. Guards against concurrent re-entry,
    /// publishes the state, invokes the driver, clears state on
    /// dismissal.
    private func present(state: SignInPresentationState,
                         libraryID: String,
                         completion: (() -> Void)?) {
        guard !inFlight else {
            // Mirror the static API's silent-no-op behavior for
            // concurrent calls. Do NOT fire the user's completion —
            // the static API's contract is that a duplicate is a
            // silent suppression, and downstream callers
            // (TPPReauthenticator, etc.) already handle the
            // "completion never fires" case by re-checking
            // `hasCredentials()` on the next user action.
            Log.debug(#file, "SignInModalSheetPresenter — duplicate presentation suppressed")
            return
        }
        inFlight = true
        presentationState = state
        driver(libraryID, appContainer) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            // Clear state BEFORE firing the user completion so any
            // downstream sheet-presentation triggered by the
            // completion observes a clean presenter chain (same
            // ordering as `SignInModalHostingController.onDidFullyDismiss`
            // already guarantees for the static API).
            self.presentationState = nil
            self.inFlight = false
            completion?()
        }
    }

    // MARK: Default driver

    /// Production driver: routes through the existing static
    /// `SignInModalPresenter.presentSignInModal(libraryAccountID:appContainer:completion:)`,
    /// which in turn calls `TPPPresentationUtils.safelyPresent`. The
    /// hosting controller's `onDidFullyDismiss` fires the completion
    /// AFTER the UIKit dismissal transition has completed — the
    /// presenter's `inFlight = false` reset and user-completion call
    /// are wrapped inside that callback (see `present(...)`).
    static let productionDriver: SignInModalPresentationDriver = { libraryID, appContainer, completion in
        SignInModalPresenter.presentSignInModal(
            libraryAccountID: libraryID,
            appContainer: appContainer,
            completion: completion
        )
    }
}

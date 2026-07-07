//
//  SignInModalView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceLogging

/// SwiftUI sign-in modal that wraps AccountDetailView for use in checkout/borrow flows
struct SignInModalView: View {
    let libraryAccountID: String
    let completion: (() -> Void)?
    private let appContainer: AppContainer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accountPublisher: UserAccountPublisher

    init(libraryAccountID: String, completion: (() -> Void)?, appContainer: AppContainer) {
        self.libraryAccountID = libraryAccountID
        self.completion = completion
        self.appContainer = appContainer
        _accountPublisher = StateObject(wrappedValue: appContainer.userAccountPublisher)
    }

    var body: some View {
        NavigationStack {
            // forceReauthMode: true ensures sign-in form is shown even if user has stale credentials
            // This is needed for re-auth flows (e.g., after 401 from borrow)
            AccountDetailView(libraryAccountID: libraryAccountID, appContainer: appContainer, forceReauthMode: true)
                .navigationTitle(Strings.Generic.signin)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { cancelButton }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(UIColor.systemGroupedBackground), for: .navigationBar)
                .onChange(of: accountPublisher.authState) { _, authState in
                    // Auto-dismiss when user successfully signs in (including re-auth from stale state)
                    //
                    // We deliberately do NOT call `completion?()` here. SwiftUI's `dismiss()` is
                    // non-blocking — it schedules the modal's ~300ms UIKit teardown and returns
                    // immediately. If we fire completion synchronously, downstream UI mutations
                    // (e.g., BookDetailViewModel.startDownloadAfterAuth setting
                    // `showHalfSheet = true`) try to present a NEW sheet on the same presenter
                    // chain while the sign-in modal is still animating away. UIKit refuses, the
                    // half-sheet binding goes into a stuck state, and the user-reported lock-up
                    // appears: book detail view is gesture-locked until app restart.
                    //
                    // The completion is wired through the fileprivate
                    // `SignInModalDismissalHosting.onDidFullyDismiss` (see
                    // SignInModalPresenter below), which fires from
                    // `viewDidDisappear` with `presentingViewController == nil`
                    // — i.e. AFTER the UIKit transition has fully completed.
                    // Downstream sheet presentation then runs on a clean
                    // presenter chain.
                    if Self.shouldAutoDismiss(authState: authState) {
                        dismiss()
                    }
                }
        }
    }

    /// Pure-function predicate for the auto-dismiss-on-loggedIn branch.
    /// Extracted from the body's `onChange` so the mutation gate can verify
    /// callers don't silently regress to "dismiss when NOT logged in".
    static func shouldAutoDismiss(authState: TPPAccountAuthState) -> Bool {
        return authState == .loggedIn
    }

    private var cancelButton: some View {
        Button(Strings.Generic.cancel) {
            // Same race-window argument as the auto-dismiss above — completion fires from
            // SignInModalDismissalHosting.onDidFullyDismiss, not here. Cancel callers
            // (e.g. BookDetailViewModel.ensureAuthAndExecute's outer completion) check
            // `hasCredentials()`/`authState` to decide what to do, so the cancel path
            // works the same regardless of when the completion runs.
            dismiss()
        }
        .accessibilityIdentifier("signInModal.cancel")
        .accessibilityLabel(Strings.Generic.cancel)
    }
}

/// Bridge class to present SignInModalView from Objective-C.
/// @MainActor ensures `isPresenting` reads/writes are serialized — prevents
/// duplicate modals from concurrent 401 responses on different threads.
@MainActor
@objcMembers
class SignInModalPresenter: NSObject {

    /// Guards against presenting multiple sign-in modals simultaneously.
    /// Without this, each 401 response from concurrent network requests
    /// (catalog refresh, bookmark sync, user profile fetch) would stack
    /// another modal, trapping the user in an infinite loop.
    private static var isPresenting = false

    /// Presents the SwiftUI sign-in modal
    /// - Parameters:
    ///   - libraryAccountID: The library account to sign into
    ///   - completion: Called when sign-in completes successfully
    static func presentSignInModal(libraryAccountID: String, appContainer: AppContainer = .production(), completion: (() -> Void)?) {
        guard !isPresenting else {
            Log.debug(#file, "Sign-in modal already presented — suppressing duplicate")
            return
        }
        guard !appContainer.accountsManager.isAccountSwitching else {
            Log.debug(#file, "Account switch in progress — suppressing sign-in modal (F-032)")
            return
        }
        isPresenting = true

        // SignInModalView no longer fires the completion itself (its inline
        // dismiss() is non-blocking and racing the completion against the
        // ~300ms UIKit teardown is what produced the BookDetail nav lock —
        // see comment in SignInModalView.body). Pass nil to the view; the
        // outer caller's completion is wired through the hosting controller's
        // onDidFullyDismiss callback so it fires AFTER the UIKit transition.
        let view = SignInModalView(
            libraryAccountID: libraryAccountID,
            completion: nil,
            appContainer: appContainer
        )

        let vc = SignInModalDismissalHosting(rootView: view) {
            // Order matters: clear the guard BEFORE running completion so
            // anything completion does (e.g. presenting a half-sheet) works
            // against a clean presenter chain. Completion sees isPresenting
            // already false, which is the correct state once dismissal has
            // completed.
            isPresenting = false
            completion?()
        }
        vc.modalPresentationStyle = .formSheet

        TPPPresentationUtils.safelyPresent(vc, animated: true)
    }

    /// Convenience method for current account
    /// - Parameter completion: Called when sign-in completes successfully
    static func presentSignInModalForCurrentAccount(accountsManager: AccountsManager = AppContainer.production().accountsManager, completion: (() -> Void)?) {
        guard let libraryID = accountsManager.currentAccountId else {
            completion?()
            return
        }

        // Anonymous and COPPA libraries (e.g. Palace Bookshelf) have no credential
        // form to render — presenting the modal would show an empty sheet with no
        // fields and no continue button (SQ-005). Skip the modal and call the
        // completion so the calling flow proceeds without sign-in. This is an
        // architectural invariant: the sign-in modal MUST NOT be presented for
        // an auth method that has no form to render.
        let userAccount = accountsManager.userAccount(for: libraryID)
        if !userAccount.needsAuth {
            Log.info(#file, "Skipping sign-in modal — library \(libraryID) does not require authentication")
            completion?()
            return
        }

        presentSignInModal(libraryAccountID: libraryID, completion: completion)
    }
}

/// Fileprivate hosting controller that fires a callback when the
/// underlying UIKit dismissal transition fully completes — used to delay
/// clearing `SignInModalPresenter.isPresenting` until the modal is
/// actually gone, not just when SwiftUI's `dismiss()` was called.
/// SwiftUI's `dismiss()` is non-blocking; without this guard, fast user
/// re-taps race the in-flight dismiss and produce "transitioning already"
/// stuck-modal lock-ups (HelpSpot 17716 SAML re-auth invariant).
///
/// swarm_d8f11437 Module A wave 4 — renamed from the previously-public
/// `SignInModalHostingController` and scoped fileprivate so the type is
/// not test-visible; the once-after-fully-dismissed semantics are now
/// pinned at the presenter level via `SignInModalSheetPresenter`'s
/// state-transition tests (round-trip pattern, CLAUDE.md DoD).
fileprivate final class SignInModalDismissalHosting<Content: View>: UIHostingController<Content> {
    private let onDidFullyDismiss: () -> Void
    private var firedOnce = false

    init(rootView: Content, onDidFullyDismiss: @escaping () -> Void) {
        self.onDidFullyDismiss = onDidFullyDismiss
        super.init(rootView: rootView)
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used; SignInModalDismissalHosting is constructed programmatically")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // viewDidDisappear fires for reasons other than dismissal (e.g. a
        // view controller pushed on top within an embedded nav stack). We
        // only want to fire when this hosting controller is actually torn
        // down — `presentingViewController == nil` is true after dismissal
        // has fully completed.
        guard !firedOnce, presentingViewController == nil else { return }
        firedOnce = true
        onDidFullyDismiss()
    }
}

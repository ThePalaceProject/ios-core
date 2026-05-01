//
//  SignInModalView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// SwiftUI sign-in modal that wraps AccountDetailView for use in checkout/borrow flows
struct SignInModalView: View {
    let libraryAccountID: String
    let completion: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accountPublisher = UserAccountPublisher.shared

    var body: some View {
        NavigationView {
            // forceReauthMode: true ensures sign-in form is shown even if user has stale credentials
            // This is needed for re-auth flows (e.g., after 401 from borrow)
            AccountDetailView(libraryAccountID: libraryAccountID, forceReauthMode: true)
                .navigationTitle(Strings.Generic.signin)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(leading: cancelButton)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(UIColor.systemGroupedBackground), for: .navigationBar)
                .onChange(of: accountPublisher.authState) { authState in
                    // Auto-dismiss when user successfully signs in (including re-auth from stale state)
                    if authState == .loggedIn {
                        dismiss()
                        completion?()
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    private var cancelButton: some View {
        Button(Strings.Generic.cancel) {
            dismiss()
            // Call completion on cancel so callers can clean up UI state (e.g., remove processing spinners)
            // IMPORTANT: Callers MUST check hasCredentials() before proceeding with their action
            completion?()
        }
    }
}

/// UIHostingController subclass that fires a callback when the underlying
/// UIKit dismissal transition fully completes — used to delay clearing
/// `SignInModalPresenter.isPresenting` until the modal is actually gone,
/// not just when SwiftUI's `dismiss()` was called. SwiftUI's dismiss is
/// non-blocking; without this, fast user re-taps race the in-flight
/// dismiss and produce "transitioning already" stuck-modal lock-ups.
private final class SignInModalHostingController<Content: View>: UIHostingController<Content> {
    private let onDidFullyDismiss: () -> Void
    private var firedOnce = false

    init(rootView: Content, onDidFullyDismiss: @escaping () -> Void) {
        self.onDidFullyDismiss = onDidFullyDismiss
        super.init(rootView: rootView)
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used; SignInModalHostingController is constructed programmatically")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // viewDidDisappear fires for reasons other than dismissal (e.g. a
        // view controller pushed on top within an embedded nav stack). We
        // only want to reset isPresenting when this hosting controller is
        // actually torn down — `presentingViewController == nil` is true
        // after dismissal has fully completed.
        guard !firedOnce, presentingViewController == nil else { return }
        firedOnce = true
        onDidFullyDismiss()
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
    static func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?) {
        guard !isPresenting else {
            Log.debug(#file, "Sign-in modal already presented — suppressing duplicate")
            return
        }
        guard !AccountsManager.shared.isAccountSwitching else {
            Log.debug(#file, "Account switch in progress — suppressing sign-in modal (F-032)")
            return
        }
        isPresenting = true

        let view = SignInModalView(
            libraryAccountID: libraryAccountID,
            completion: {
                // CRITICAL: do NOT flip isPresenting here. SwiftUI's dismiss()
                // schedules the UIKit dismissal but returns immediately — the
                // transition itself takes ~300ms. If isPresenting flips false
                // now, a fast user re-tap (e.g. user cancels, then immediately
                // taps Borrow again on book detail) calls present() while the
                // previous modal is still mid-dismiss. UIKit refuses with
                // "trying to dismiss the presentation controller while
                // transitioning already" and the form sheet sticks half-mounted
                // — observed on hotfix-branch device test (HelpSpot 17716
                // follow-up). The reset fires from the hosting controller's
                // own viewDidDisappear instead, which only runs once the UIKit
                // transition has actually completed.
                completion?()
            }
        )

        let vc = SignInModalHostingController(rootView: view) { isPresenting = false }
        vc.modalPresentationStyle = .formSheet

        TPPPresentationUtils.safelyPresent(vc, animated: true)
    }

    /// Convenience method for current account
    /// - Parameter completion: Called when sign-in completes successfully
    static func presentSignInModalForCurrentAccount(accountsManager: AccountsManager = AccountsManager.shared, completion: (() -> Void)?) {
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

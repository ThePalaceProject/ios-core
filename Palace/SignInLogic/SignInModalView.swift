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
        NavigationView {
            // forceReauthMode: true ensures sign-in form is shown even if user has stale credentials
            // This is needed for re-auth flows (e.g., after 401 from borrow)
            AccountDetailView(libraryAccountID: libraryAccountID, appContainer: appContainer, forceReauthMode: true)
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

        let view = SignInModalView(
            libraryAccountID: libraryAccountID,
            completion: {
                isPresenting = false
                completion?()
            },
            appContainer: appContainer
        )

        let vc = UIHostingController(rootView: view)
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

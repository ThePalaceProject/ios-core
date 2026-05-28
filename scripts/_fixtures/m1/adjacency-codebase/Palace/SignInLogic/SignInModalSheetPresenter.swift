//  SignInModalSheetPresenter.swift
//  AppContainer-injected, spy-testable sign-in modal presenter.
//
//  Wave 3 ships:
//   - SignInModalHostingController STAYS in wave 3; deletion deferred.
//   - The driver MUST fire the completion exactly once after the
//     underlying modal dismisses fully (production driver wires this
//     through `SignInModalHostingController.onDidFullyDismiss` for free).

import Foundation

final class SignInModalSheetPresenter: NSObject {
    /// Strong reference to the app container. Used so the driver can
    /// resolve the same SignInModalHostingController.onDidFullyDismiss
    /// instance the static API uses.
    @Published private(set) var presentationState: Int?

    func dismissCleanup() {
        // Clear state BEFORE firing the user completion so any
        // downstream sheet-presentation triggered by the
        // completion observes a clean presenter chain (same
        // ordering as `SignInModalHostingController.onDidFullyDismiss`
        // already guarantees for the static API).
        presentationState = nil
    }
}

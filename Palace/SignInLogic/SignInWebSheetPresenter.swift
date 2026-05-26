//
//  SignInWebSheetPresenter.swift
//  The Palace Project
//
//  Replaces TPPCookiesWebViewController's UUID-keyed `automaticBrowserStorage`
//  static dictionary and the `loadViewIfNeeded()`-then-self-present pattern
//  that lived on the legacy controller.
//
//  Two entry points cover the three legacy call sites:
//    - present(model:from:animated:completion:) — explicit presentation,
//      mirrors LegacySAMLWebViewPresenter.presentSAMLWebView (TPPSAMLHelper).
//    - presentOnTop(model:) — finds the topmost VC and presents the sheet,
//      mirrors the legacy `autoPresentIfNeeded == true` flow used by
//      MyBooksDownloadCenter and BookSignInRedirectHandler.
//

import Foundation
import SwiftUI
import UIKit
import PalaceAuth

@MainActor
final class SignInWebSheetPresenter: NSObject {

    /// Active hosting controllers, keyed by UUID, kept alive while presented
    /// so the underlying SwiftUI view tree and view model don't deallocate
    /// before the modal is dismissed. Replaces the legacy
    /// `TPPCookiesWebViewController.automaticBrowserStorage` keep-alive.
    private static var activeHosts: [String: UIViewController] = [:]

    /// Per-presentation dismissal delegates. Held strongly here because
    /// `UIViewController.presentationController?.delegate` is `weak`, so
    /// without our retain the delegate would be deallocated as soon as
    /// `makeHostingController` returns and swipe-down dismiss would silently
    /// no-op. Mirrors `activeHosts` keying.
    private static var dismissalDelegates: [String: SignInWebSheetDismissalDelegate] = [:]

    // MARK: - Public API

    /// Presents the SwiftUI sign-in web sheet from the given presenter.
    /// Used by TPPSAMLHelper's LegacySAMLWebViewPresenter.
    static func present(
        model: SignInWebSheetViewModel,
        from presenter: UIViewController,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        let host = makeHostingController(model: model)
        present(host: host, from: presenter, animated: animated, completion: completion)
    }

    /// Finds the topmost view controller and presents the sheet from it.
    /// Mirrors the legacy `autoPresentIfNeeded == true` flow that
    /// `MyBooksDownloadCenter` and `BookSignInRedirectHandler` rely on so
    /// the SAML mid-download redirect can drive itself onto the screen.
    static func presentOnTop(model: SignInWebSheetViewModel) {
        guard let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() else {
            return
        }
        present(model: model, from: top)
    }

    /// Returns true when any sign-in web sheet is currently presented.
    /// `BookSignInRedirectHandler` uses this to decide whether to dismiss
    /// the sheet via its own presenter chain after a successful re-auth.
    static var isPresenting: Bool {
        !activeHosts.isEmpty
    }

    /// Dismisses the topmost active sheet, if any, then invokes completion.
    static func dismissTop(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let (uuid, host) = activeHosts.first else {
            completion?()
            return
        }
        let presenter = host.presentingViewController ?? host
        presenter.dismiss(animated: animated) {
            cleanup(uuid: uuid)
            completion?()
        }
    }

    // MARK: - Internal helpers

    /// Single cleanup site so explicit dismiss, swipe-down dismiss, and
    /// future paths can't drift apart. Idempotent.
    fileprivate static func cleanup(uuid: String) {
        activeHosts[uuid] = nil
        dismissalDelegates[uuid] = nil
    }

    private static func makeHostingController(model: SignInWebSheetViewModel) -> UIHostingController<SignInWebSheet> {
        let uuid = UUID().uuidString
        weak var weakHost: UIHostingController<SignInWebSheet>?
        let view = SignInWebSheet(viewModel: model) {
            // Cancel button — dismiss; cleanup runs in the dismiss completion.
            weakHost?.dismiss(animated: true) {
                cleanup(uuid: uuid)
            }
        }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        weakHost = host
        activeHosts[uuid] = host

        // Wire up swipe-down dismiss → recordCancel + cleanup. Without this,
        // the user can swipe the sheet off-screen and we never learn about
        // it — the calling business logic stays waiting for a terminal
        // callback that never arrives, and `isPresenting` stays true forever.
        let delegate = SignInWebSheetDismissalDelegate(model: model, uuid: uuid)
        dismissalDelegates[uuid] = delegate
        host.presentationController?.delegate = delegate

        return host
    }

    private static func present(
        host: UIViewController,
        from presenter: UIViewController,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        // If something is already presented on the requested presenter, walk
        // up to the topmost so the new sheet stacks correctly. This matches
        // the legacy controller's self-present logic.
        var topPresenter = presenter
        while let presented = topPresenter.presentedViewController {
            topPresenter = presented
        }
        topPresenter.present(host, animated: animated, completion: completion)
    }
}

// MARK: - Dismissal delegate

/// `UIAdaptivePresentationControllerDelegate` adapter that surfaces
/// swipe-down dismiss as a `recordCancel()` on the model and tears down
/// the presenter's keep-alive references for this presentation.
@MainActor
final class SignInWebSheetDismissalDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private let model: SignInWebSheetViewModel
    private let uuid: String

    init(model: SignInWebSheetViewModel, uuid: String) {
        self.model = model
        self.uuid = uuid
        super.init()
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in
            self.model.recordCancel()
            SignInWebSheetPresenter.cleanup(uuid: self.uuid)
        }
    }
}

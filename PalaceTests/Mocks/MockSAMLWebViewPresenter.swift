//
//  MockSAMLWebViewPresenter.swift
//  PalaceTests
//
//  Mock for SAMLWebViewPresenting protocol — captures presentation
//  calls so tests can simulate user completing or cancelling login.
//

import Foundation
import PalaceAuth
@testable import Palace

// `@MainActor`: `SAMLWebViewPresenting` (PalaceAuth) becomes a `@MainActor`
// protocol as part of the `TPPSignInBusinessLogic: @MainActor` conversion
// (see RIPPLES.md — SAML-protocol cascade), so its conformers — including this
// test mock — inherit the isolation.
@MainActor
class MockSAMLWebViewPresenter: SAMLWebViewPresenting {

    // MARK: - Present Tracking

    var presentCalled = false
    var presentCallCount = 0
    var presentedURL: URL?
    var presentedCookies: [HTTPCookie]?

    /// Captured so tests can simulate user completing login
    var capturedLoginCompletion: ((URL, [HTTPCookie]) -> Void)?
    /// Captured so tests can simulate user cancelling login
    var capturedLoginCancel: (() -> Void)?

    func presentSAMLWebView(url: URL, cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void) {
        presentCalled = true
        presentCallCount += 1
        presentedURL = url
        presentedCookies = cookies
        capturedLoginCompletion = loginCompletion
        capturedLoginCancel = loginCancel
    }

    // MARK: - Dismiss Tracking

    var dismissCalled = false
    var dismissCallCount = 0
    var dismissAnimated: Bool?

    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?) {
        dismissCalled = true
        dismissCallCount += 1
        dismissAnimated = animated
        completion?()
    }
}

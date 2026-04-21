//
//  MockSAMLAuthContext.swift
//  PalaceTests
//
//  Mock for SAMLAuthContext protocol — used to test TPPSAMLHelper
//  without coupling to TPPSignInBusinessLogic.
//

import Foundation
@testable import Palace

class MockSAMLAuthContext: SAMLAuthContext {
    var selectedIDP: OPDS2SamlIDP?
    var urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider
    var savedCookies: [HTTPCookie] = []

    // MARK: - Call Tracking

    var handleRedirectCalled = false
    var handleRedirectCallCount = 0
    var handleRedirectURL: URL?
    var handleRedirectCookies: [HTTPCookie]?

    // Configurable stub responses
    var handleRedirectError: Error?
    var handleRedirectErrorTitle: String?
    var handleRedirectErrorMessage: String?

    init(urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider = TPPURLSettingsProviderMock()) {
        self.urlSettingsProvider = urlSettingsProvider
    }

    func handleSAMLRedirect(url: URL, cookies: [HTTPCookie],
                            completion: @escaping (Error?, String?, String?) -> Void) {
        handleRedirectCalled = true
        handleRedirectCallCount += 1
        handleRedirectURL = url
        handleRedirectCookies = cookies
        completion(handleRedirectError, handleRedirectErrorTitle, handleRedirectErrorMessage)
    }

    // MARK: - Error Reporting

    var reportErrorCalled = false
    var reportedError: Error?
    var reportedErrorTitle: String?
    var reportedErrorMessage: String?

    func reportError(_ error: Error, title: String, message: String) {
        reportErrorCalled = true
        reportedError = error
        reportedErrorTitle = title
        reportedErrorMessage = message
    }
}

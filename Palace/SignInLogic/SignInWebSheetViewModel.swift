//
//  SignInWebSheetViewModel.swift
//  The Palace Project
//
//  Navigation policy for the SAML/SSO sign-in sheet, as pure decision
//  functions testable without a WKWebView. The view forwards navigation
//  events here; the model decides allow/cancel and fires exactly one
//  terminal callback (loginCompletion, bookFound, problem, or cancel).
//  Events arriving after a terminal event are dropped.
//

import Foundation
import WebKit
import PalaceCatalog

// MARK: - CookieStoreInjecting

/// Test seam for WKHTTPCookieStore so we can verify injection ordering
/// without standing up a real WKWebView.
@MainActor
protocol CookieStoreInjecting: AnyObject {
    func setCookie(_ cookie: HTTPCookie) async
}

// MARK: - WKHTTPCookieStore conformance

extension WKHTTPCookieStore: CookieStoreInjecting {
    func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.setCookie(cookie) { continuation.resume() }
        }
    }
}

// MARK: - SignInWebSheetViewModel

@MainActor
final class SignInWebSheetViewModel: ObservableObject {

    // MARK: Decision

    enum NavigationDecision: Equatable {
        case allow
        case cancel
        case completeLogin(URL)
        case bookFound
        case problemFound
    }

    // MARK: Configuration

    let initialRequest: URLRequest
    let cookies: [HTTPCookie]
    let universalLinksURL: URL
    let supportedBookTypes: Set<String>
    let problemMimeTypes: Set<String>
    let autoPresentIfNeeded: Bool

    // MARK: Callbacks

    private let loginCompletionHandler: ((URL, [HTTPCookie]) -> Void)?
    private let loginCancelHandler: (() -> Void)?
    private let bookFoundHandler: ((URLRequest?, [HTTPCookie]) -> Void)?
    private let problemFoundHandler: ((TPPProblemDocument?) -> Void)?

    // MARK: State

    @Published private(set) var isLoading: Bool = true

    private(set) var previousRequest: URLRequest?
    private(set) var wasBookFound: Bool = false

    /// Tracks whether a terminal event has been recorded. Once `true`, no
    /// further callback dispatch occurs — extra late events are dropped.
    private var didRecordTerminal: Bool = false

    // MARK: Init

    init(
        cookies: [HTTPCookie],
        request: URLRequest,
        universalLinksURL: URL,
        supportedBookTypes: Set<String> = TPPOPDSAcquisitionPath.supportedTypes(),
        problemMimeTypes: Set<String> = ["application/problem+json", "application/api-problem+json"],
        autoPresentIfNeeded: Bool = false,
        loginCompletionHandler: ((URL, [HTTPCookie]) -> Void)? = nil,
        loginCancelHandler: (() -> Void)? = nil,
        bookFoundHandler: ((URLRequest?, [HTTPCookie]) -> Void)? = nil,
        problemFoundHandler: ((TPPProblemDocument?) -> Void)? = nil
    ) {
        self.cookies = cookies
        self.initialRequest = request
        self.universalLinksURL = universalLinksURL
        self.supportedBookTypes = supportedBookTypes
        self.problemMimeTypes = problemMimeTypes
        self.autoPresentIfNeeded = autoPresentIfNeeded
        self.loginCompletionHandler = loginCompletionHandler
        self.loginCancelHandler = loginCancelHandler
        self.bookFoundHandler = bookFoundHandler
        self.problemFoundHandler = problemFoundHandler
    }

    // MARK: - Navigation policy decisions (pure)

    /// Decides whether a navigation action should proceed, and whether it
    /// represents the universal-links login-completion redirect.
    /// Always records `previousRequest` for later bookFound dispatch.
    func decideAction(for request: URLRequest) -> NavigationDecision {
        previousRequest = request

        guard let url = request.url else { return .allow }

        if url.absoluteString.hasPrefix(universalLinksURL.absoluteString) {
            return .completeLogin(url)
        }
        return .allow
    }

    /// Decides response policy from a MIME type string.
    /// Returns `.bookFound` for any supported acquisition mime; `.problemFound`
    /// for an OPDS problem document; otherwise `.allow`.
    func decideResponse(mimeType: String?) -> NavigationDecision {
        guard let mime = mimeType else { return .allow }
        if supportedBookTypes.contains(mime) { return .bookFound }
        if problemMimeTypes.contains(mime) { return .problemFound }
        return .allow
    }

    // MARK: - Terminal callback dispatch (idempotent)

    func recordLoginCompletion(destinationURL: URL, cookies: [HTTPCookie]) {
        guard !didRecordTerminal else { return }
        didRecordTerminal = true
        loginCompletionHandler?(destinationURL, cookies)
    }

    func recordBookFound(cookies: [HTTPCookie]) {
        guard !didRecordTerminal else { return }
        didRecordTerminal = true
        wasBookFound = true
        bookFoundHandler?(previousRequest, cookies)
    }

    func recordProblem(document: TPPProblemDocument?) {
        guard !didRecordTerminal else { return }
        didRecordTerminal = true
        problemFoundHandler?(document)
    }

    func recordCancel() {
        guard !didRecordTerminal else { return }
        didRecordTerminal = true
        loginCancelHandler?()
    }

    // MARK: - Loading state

    func didStartProvisionalNavigation() {
        isLoading = true
    }

    func didFinishNavigation() {
        isLoading = false
    }

    func didFailNavigation() {
        isLoading = false
    }

    // MARK: - Cookie injection

    /// Injects this view model's cookies into the given store, then calls
    /// `loadHandler` with `initialRequest` exactly once. If there are no
    /// cookies, fires `loadHandler` immediately without any injection.
    func injectCookiesAndLoad(
        into injector: CookieStoreInjecting,
        loadHandler: (URLRequest) -> Void
    ) async {
        for cookie in cookies {
            await injector.setCookie(cookie)
        }
        loadHandler(initialRequest)
    }
}

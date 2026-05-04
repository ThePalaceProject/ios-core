//
//  SignInWebSheetViewModelTests.swift
//  PalaceTests
//
//  Unit tests for SignInWebSheetViewModel — the pure-decision navigation
//  policy + callback dispatcher that replaces TPPCookiesWebViewController's
//  inline WKNavigationDelegate logic. No WKWebView, no UIKit; tests
//  exercise the model in isolation using value-type inputs.
//
//  Critical-path sign-in coverage per CLAUDE.md mandate. Each test is
//  designed to kill at least one mutant under palace_mutate.py.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class SignInWebSheetViewModelTests: XCTestCase {

    // MARK: - Test fixtures

    private let universalLinks = URL(string: "https://librarysimplified.org/callbacks/SimplyE")!
    private let bookTypes: Set<String> = [
        "application/epub+zip",
        "application/pdf",
        "application/audiobook+json",
    ]
    private let problemMimes: Set<String> = [
        "application/problem+json",
        "application/api-problem+json",
    ]

    private func makeViewModel(
        cookies: [HTTPCookie] = [],
        request: URLRequest = URLRequest(url: URL(string: "https://idp.example.com/login")!),
        autoPresentIfNeeded: Bool = false,
        loginCompletion: ((URL, [HTTPCookie]) -> Void)? = nil,
        loginCancel: (() -> Void)? = nil,
        bookFound: ((URLRequest?, [HTTPCookie]) -> Void)? = nil,
        problemFound: ((TPPProblemDocument?) -> Void)? = nil
    ) -> SignInWebSheetViewModel {
        SignInWebSheetViewModel(
            cookies: cookies,
            request: request,
            universalLinksURL: universalLinks,
            supportedBookTypes: bookTypes,
            problemMimeTypes: problemMimes,
            autoPresentIfNeeded: autoPresentIfNeeded,
            loginCompletionHandler: loginCompletion,
            loginCancelHandler: loginCancel,
            bookFoundHandler: bookFound,
            problemFoundHandler: problemFound
        )
    }

    // MARK: - decideAction (navigation action policy)

    func test_decideAction_navigationToUniversalLinksURL_returnsCompleteLogin() {
        let vm = makeViewModel()
        let target = universalLinks.appendingPathComponent("token=abc")
        let decision = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(decision, .completeLogin(target))
    }

    func test_decideAction_navigationToUniversalLinksHostButDifferentPath_doesNotMatch() {
        // Defensive: matching is hasPrefix on the FULL absoluteString, not just host.
        // A page on the same host that isn't the SimplyE callback must NOT trigger
        // login completion — otherwise we'd hand cookies to the wrong destination.
        let vm = makeViewModel()
        let target = URL(string: "https://librarysimplified.org/about")!
        let decision = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(decision, .allow)
    }

    func test_decideAction_navigationToOtherURL_returnsAllow() {
        let vm = makeViewModel()
        let target = URL(string: "https://idp.example.com/saml/sso")!
        let decision = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(decision, .allow)
    }

    func test_decideAction_recordsPreviousRequestForLaterBookFound() {
        // The bookFound callback hands the caller the *previous* request — i.e., the
        // navigation that produced the book response. Each decideAction must store
        // its request so we can return it later.
        let vm = makeViewModel()
        let r1 = URLRequest(url: URL(string: "https://cdn.example/book.epub")!)
        _ = vm.decideAction(for: r1)
        XCTAssertEqual(vm.previousRequest?.url, r1.url)

        let r2 = URLRequest(url: URL(string: "https://cdn.example/other.epub")!)
        _ = vm.decideAction(for: r2)
        XCTAssertEqual(vm.previousRequest?.url, r2.url, "previousRequest should be the most recent action")
    }

    func test_decideAction_loginCompletionURL_isStillRecordedAsPreviousRequest() {
        // Even when we're about to fire loginCompletion, we still record the URL
        // for previousRequest. Today this is benign; locking it in prevents a
        // future "skip recording on terminal action" optimization from breaking
        // a downstream caller that reads previousRequest in a completion handler.
        let vm = makeViewModel()
        let target = universalLinks.appendingPathComponent("?token=x")
        _ = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(vm.previousRequest?.url, target)
    }

    // MARK: - decideResponse (navigation response policy)

    func test_decideResponse_supportedBookMime_returnsBookFound() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: "application/epub+zip"), .bookFound)
        XCTAssertEqual(vm.decideResponse(mimeType: "application/pdf"), .bookFound)
        XCTAssertEqual(vm.decideResponse(mimeType: "application/audiobook+json"), .bookFound)
    }

    func test_decideResponse_problemJsonMime_returnsProblemFound() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: "application/problem+json"), .problemFound)
        XCTAssertEqual(vm.decideResponse(mimeType: "application/api-problem+json"), .problemFound)
    }

    func test_decideResponse_htmlMime_returnsAllow() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: "text/html"), .allow)
        XCTAssertEqual(vm.decideResponse(mimeType: "application/json"), .allow)
    }

    func test_decideResponse_nilMime_returnsAllow() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: nil), .allow)
    }

    func test_decideResponse_unsupportedTypeNotInBookList_returnsAllow() {
        // Negate the supportedBookTypes list to ensure the contains check is
        // actually checked (mutation: changing `contains` to `!contains` would
        // pass a permissive test that only checked positive cases).
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: "application/octet-stream-but-not-on-list"), .allow)
    }

    // MARK: - Callback dispatch — terminal events fire once

    func test_recordLoginCompletion_invokesHandlerOnceWithURLAndCookies() {
        var calls: [(URL, [HTTPCookie])] = []
        let vm = makeViewModel(loginCompletion: { url, cookies in calls.append((url, cookies)) })
        let cookie = HTTPCookie(properties: [.domain: "idp", .path: "/", .name: "s", .value: "v"])!

        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [cookie])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, universalLinks)
        XCTAssertEqual(calls.first?.1.first?.name, "s")
    }

    func test_recordLoginCompletion_secondCallIgnored() {
        var count = 0
        let vm = makeViewModel(loginCompletion: { _, _ in count += 1 })
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        XCTAssertEqual(count, 1, "Terminal events must be idempotent — extra fires from late callbacks must not double-dispatch")
    }

    func test_recordBookFound_invokesHandlerOnceWithPreviousRequestAndCookies() {
        var got: (URLRequest?, [HTTPCookie])?
        let vm = makeViewModel(bookFound: { req, cookies in got = (req, cookies) })
        let r = URLRequest(url: URL(string: "https://cdn.example/book.epub")!)
        _ = vm.decideAction(for: r)
        let cookie = HTTPCookie(properties: [.domain: "cdn", .path: "/", .name: "k", .value: "v"])!
        vm.recordBookFound(cookies: [cookie])
        XCTAssertEqual(got?.0?.url, r.url)
        XCTAssertEqual(got?.1.count, 1)
        XCTAssertTrue(vm.wasBookFound)
    }

    func test_recordBookFound_secondCallIgnored() {
        var count = 0
        let vm = makeViewModel(bookFound: { _, _ in count += 1 })
        vm.recordBookFound(cookies: [])
        vm.recordBookFound(cookies: [])
        XCTAssertEqual(count, 1)
    }

    func test_recordProblem_invokesHandlerOnce() {
        var count = 0
        let vm = makeViewModel(problemFound: { _ in count += 1 })
        vm.recordProblem(document: nil)
        vm.recordProblem(document: nil)
        XCTAssertEqual(count, 1)
    }

    func test_recordCancel_invokesHandlerOnce() {
        var count = 0
        let vm = makeViewModel(loginCancel: { count += 1 })
        vm.recordCancel()
        vm.recordCancel()
        XCTAssertEqual(count, 1, "Cancel callbacks must be idempotent — sheet onDismiss can fire multiple times in some teardown paths")
    }

    // MARK: - Mutual exclusion across terminal events

    func test_loginCompletionThenCancel_doesNotFireCancel() {
        // After login succeeds, programmatic dismissal must not fire cancel.
        // Today the production code achieves this implicitly because
        // presentationControllerDidDismiss is only called for interactive
        // dismissals. We make this contract explicit in the view model so the
        // SwiftUI port (which uses sheet onDismiss) doesn't double-fire.
        var loginCount = 0
        var cancelCount = 0
        let vm = makeViewModel(
            loginCompletion: { _, _ in loginCount += 1 },
            loginCancel: { cancelCount += 1 }
        )
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        vm.recordCancel()
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(cancelCount, 0, "cancel must not fire after a terminal success event")
    }

    func test_bookFoundThenCancel_doesNotFireCancel() {
        var bookCount = 0
        var cancelCount = 0
        let vm = makeViewModel(
            loginCancel: { cancelCount += 1 },
            bookFound: { _, _ in bookCount += 1 }
        )
        vm.recordBookFound(cookies: [])
        vm.recordCancel()
        XCTAssertEqual(bookCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func test_problemThenCancel_doesNotFireCancel() {
        var problemCount = 0
        var cancelCount = 0
        let vm = makeViewModel(
            loginCancel: { cancelCount += 1 },
            problemFound: { _ in problemCount += 1 }
        )
        vm.recordProblem(document: nil)
        vm.recordCancel()
        XCTAssertEqual(problemCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func test_cancelThenLoginCompletion_doesNotFireLogin() {
        // After explicit cancel, late-arriving login callback (e.g., a slow
        // network response that resolved post-dismiss) must not retroactively
        // log the user in. This lock-in matches the semantics callers like
        // BookSignInRedirectHandler rely on.
        var loginCount = 0
        var cancelCount = 0
        let vm = makeViewModel(
            loginCompletion: { _, _ in loginCount += 1 },
            loginCancel: { cancelCount += 1 }
        )
        vm.recordCancel()
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(loginCount, 0)
    }

    // MARK: - wasBookFound observable flag (used by autoPresent self-dismiss path)

    func test_wasBookFound_falseInitially() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.wasBookFound)
    }

    func test_wasBookFound_trueAfterRecordBookFound() {
        let vm = makeViewModel()
        vm.recordBookFound(cookies: [])
        XCTAssertTrue(vm.wasBookFound)
    }

    func test_wasBookFound_falseAfterOnlyLoginCompletion() {
        let vm = makeViewModel()
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        XCTAssertFalse(vm.wasBookFound, "loginCompletion must not flip the bookFound flag")
    }

    // MARK: - Loading state

    func test_isLoading_trueByDefault() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.isLoading, "Overlay should be visible until first navigation finishes")
    }

    func test_didFinishNavigation_setsLoadingFalse() {
        let vm = makeViewModel()
        vm.didFinishNavigation()
        XCTAssertFalse(vm.isLoading)
    }

    func test_didStartProvisionalNavigation_resetsLoadingTrue() {
        // After the first load completes, subsequent navigations (e.g., IDP-side
        // redirect) should re-show the overlay. Mirrors didStartProvisionalNavigation
        // delegate path in the legacy controller.
        let vm = makeViewModel()
        vm.didFinishNavigation()
        XCTAssertFalse(vm.isLoading)
        vm.didStartProvisionalNavigation()
        XCTAssertTrue(vm.isLoading)
    }

    // MARK: - Cookie injection ordering (uses fake injector)

    func test_cookieInjection_emptyCookies_loadsRequestImmediately() async {
        let injector = FakeCookieInjector()
        let vm = makeViewModel()
        let initial = URLRequest(url: URL(string: "https://idp.example.com/login")!)
        await vm.injectCookiesAndLoad(into: injector, loadHandler: { req in
            XCTAssertEqual(req.url, initial.url)
        })
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func test_cookieInjection_loadHandlerOnlyFiresAfterAllCookiesInjected() async {
        let injector = FakeCookieInjector()
        let cookie1 = HTTPCookie(properties: [.domain: "a", .path: "/", .name: "c1", .value: "v"])!
        let cookie2 = HTTPCookie(properties: [.domain: "a", .path: "/", .name: "c2", .value: "v"])!
        let vm = makeViewModel(cookies: [cookie1, cookie2])

        var loadFireCount = 0
        await vm.injectCookiesAndLoad(into: injector, loadHandler: { _ in
            loadFireCount += 1
        })

        XCTAssertEqual(injector.injectionCount, 2, "Both cookies must be injected")
        XCTAssertEqual(loadFireCount, 1, "Load handler must fire exactly once after all cookies inject")
    }

    func test_cookieInjection_orderPreserved() async {
        let injector = FakeCookieInjector()
        let cookie1 = HTTPCookie(properties: [.domain: "a", .path: "/", .name: "c1", .value: "v1"])!
        let cookie2 = HTTPCookie(properties: [.domain: "a", .path: "/", .name: "c2", .value: "v2"])!
        let vm = makeViewModel(cookies: [cookie1, cookie2])
        await vm.injectCookiesAndLoad(into: injector, loadHandler: { _ in })
        XCTAssertEqual(injector.injectedNames, ["c1", "c2"])
    }

    // MARK: - autoPresentIfNeeded passthrough

    func test_autoPresentIfNeeded_defaultsToFalse() {
        XCTAssertFalse(makeViewModel().autoPresentIfNeeded)
    }

    func test_autoPresentIfNeeded_canBeTrue() {
        XCTAssertTrue(makeViewModel(autoPresentIfNeeded: true).autoPresentIfNeeded)
    }
}

// MARK: - FakeCookieInjector

/// Captures cookie injection calls so tests can verify ordering and count
/// without touching a real WKHTTPCookieStore.
@MainActor
final class FakeCookieInjector: CookieStoreInjecting {
    var injectionCount = 0
    var injectedNames: [String] = []

    func setCookie(_ cookie: HTTPCookie) async {
        injectionCount += 1
        injectedNames.append(cookie.name)
    }
}

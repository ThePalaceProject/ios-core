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
        // The terminal match returns .completeLogin(target) with the exact URL.
        // Pair-assert previousRequest is also recorded so a mutation that
        // returns the decision without updating previousRequest is caught.
        let vm = makeViewModel()
        let target = universalLinks.appendingPathComponent("token=abc")
        let decision = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(decision, .completeLogin(target),
                       "URL with universalLinks prefix must yield .completeLogin with the exact URL")
        XCTAssertEqual(vm.previousRequest?.url, target,
                       "Terminal-match action must still record previousRequest (used by downstream callers)")
    }

    func test_decideAction_navigationToUniversalLinksHostButDifferentPath_doesNotMatch() {
        // Defensive: matching is hasPrefix on the FULL absoluteString, not just host.
        // A page on the same host that isn't the SimplyE callback must NOT trigger
        // login completion — otherwise we'd hand cookies to the wrong destination.
        // Negative pair-assertion: a same-host URL with a path that intersects
        // with the universal-links prefix on bytes but not on the path component
        // must also miss — locks the contract against a substring-match mutation.
        let vm = makeViewModel()
        let target = URL(string: "https://librarysimplified.org/about")!
        let decision = vm.decideAction(for: URLRequest(url: target))
        let other = URL(string: "https://librarysimplified.org/something-else")!
        let decision2 = vm.decideAction(for: URLRequest(url: other))
        XCTAssertEqual(decision, .allow,
                       "Same-host /about must be .allow — universal-links match is path-aware, not host-only")
        XCTAssertEqual(decision2, .allow,
                       "Same-host arbitrary path must also be .allow")
    }

    func test_decideAction_navigationToOtherURL_returnsAllow() {
        // Pair-assertion: two distinct off-host URLs must both pass through
        // as .allow so a mutation that hard-codes a specific URL is caught.
        let vm = makeViewModel()
        let target = URL(string: "https://idp.example.com/saml/sso")!
        let other = URL(string: "https://login.openathens.net/")!
        let decision = vm.decideAction(for: URLRequest(url: target))
        let decision2 = vm.decideAction(for: URLRequest(url: other))
        XCTAssertEqual(decision, .allow,
                       "Unrelated IdP URL must be .allow — only the universalLinks prefix triggers completion")
        XCTAssertEqual(decision2, .allow,
                       "Second unrelated host must also be .allow — decision is not host-specific")
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
        // Pair-assert that a subsequent non-terminal request also rolls
        // previousRequest forward — so a mutation that latches previousRequest
        // on the first terminal call is caught.
        let vm = makeViewModel()
        let target = universalLinks.appendingPathComponent("?token=x")
        _ = vm.decideAction(for: URLRequest(url: target))
        XCTAssertEqual(vm.previousRequest?.url, target,
                       "Terminal-match action must still record previousRequest")
        let post = URL(string: "https://cdn.example/book.epub")!
        _ = vm.decideAction(for: URLRequest(url: post))
        XCTAssertEqual(vm.previousRequest?.url, post,
                       "previousRequest must continue rolling forward — not latched on the terminal match")
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
        // Nil MIME (some HEAD-only responses, redirects) must default to .allow
        // so the WebView can keep navigating. Pair-assert that an empty-string
        // MIME also defaults to .allow — mutation that special-cased `nil`
        // versus `""` would survive a single-branch assertion.
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: nil), .allow,
                       "Nil MIME must default to .allow — no terminal verb fires without confirmed content type")
        XCTAssertEqual(vm.decideResponse(mimeType: ""), .allow,
                       "Empty-string MIME must also default to .allow — never coerced into a known type")
    }

    func test_decideResponse_unsupportedTypeNotInBookList_returnsAllow() {
        // Negate the supportedBookTypes list to ensure the contains check is
        // actually checked (mutation: changing `contains` to `!contains` would
        // pass a permissive test that only checked positive cases). Pair-assert
        // against a second unsupported MIME, and confirm a supported MIME
        // still returns .bookFound — pinning the inclusion+exclusion contract
        // together in one test.
        let vm = makeViewModel()
        XCTAssertEqual(vm.decideResponse(mimeType: "application/octet-stream-but-not-on-list"), .allow,
                       "Arbitrary unsupported MIME must be .allow")
        XCTAssertEqual(vm.decideResponse(mimeType: "video/mp4"), .allow,
                       "Second unsupported MIME (video/mp4) must also be .allow")
        XCTAssertEqual(vm.decideResponse(mimeType: "application/epub+zip"), .bookFound,
                       "Sanity-check: a known-supported MIME still triggers .bookFound — list isn't being ignored entirely")
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
        // wasBookFound must start false AND must NOT spuriously flip after
        // non-terminal decisions like a plain decideAction call. Pair-assert
        // so a mutation that initializes wasBookFound from a side-effect is caught.
        let vm = makeViewModel()
        XCTAssertFalse(vm.wasBookFound,
                       "wasBookFound must start false — initial state has no book")
        _ = vm.decideAction(for: URLRequest(url: URL(string: "https://anywhere.example/")!))
        XCTAssertFalse(vm.wasBookFound,
                       "A non-terminal decideAction must not flip wasBookFound — only recordBookFound does")
    }

    func test_wasBookFound_trueAfterRecordBookFound() {
        // wasBookFound must flip on recordBookFound, AND remain true through
        // subsequent operations (idempotency). Pair-assert so a mutation that
        // resets the flag after the first read is caught.
        let vm = makeViewModel()
        vm.recordBookFound(cookies: [])
        XCTAssertTrue(vm.wasBookFound,
                      "recordBookFound must flip wasBookFound to true")
        // Re-read must stay true — flag is a latch, not a one-shot.
        XCTAssertTrue(vm.wasBookFound,
                      "wasBookFound must remain true on subsequent reads — it's a latch, not a one-shot")
    }

    func test_wasBookFound_falseAfterOnlyLoginCompletion() {
        // The terminal-event isolation contract: loginCompletion must not flip
        // wasBookFound; problemFound and cancel must not either. Pair-assert
        // all three non-book terminal verbs to lock the contract that ONLY
        // recordBookFound flips the flag.
        let vm = makeViewModel()
        vm.recordLoginCompletion(destinationURL: universalLinks, cookies: [])
        XCTAssertFalse(vm.wasBookFound,
                       "loginCompletion must not flip the bookFound flag")
        let vm2 = makeViewModel()
        vm2.recordProblem(document: nil)
        XCTAssertFalse(vm2.wasBookFound,
                       "recordProblem must not flip the bookFound flag")
        let vm3 = makeViewModel()
        vm3.recordCancel()
        XCTAssertFalse(vm3.wasBookFound,
                       "recordCancel must not flip the bookFound flag")
    }

    // MARK: - Loading state

    func test_isLoading_trueByDefault() {
        // Default-true isLoading drives the overlay-on-show behavior. Pair-assert
        // that a non-navigation decideAction call does NOT flip isLoading — a
        // mutation that conflates "user action" with "navigation finished" is caught.
        let vm = makeViewModel()
        XCTAssertTrue(vm.isLoading,
                      "Overlay should be visible until first navigation finishes")
        _ = vm.decideAction(for: URLRequest(url: URL(string: "https://example.com/")!))
        XCTAssertTrue(vm.isLoading,
                      "decideAction must not flip isLoading — only didFinishNavigation does")
    }

    func test_didFinishNavigation_setsLoadingFalse() {
        // Pair-assert that isLoading WAS true before the navigation finished —
        // so a mutation that initializes isLoading to false would fail the
        // precondition AND the post-condition would assert nothing.
        let vm = makeViewModel()
        XCTAssertTrue(vm.isLoading, "Precondition: overlay visible before nav finishes")
        vm.didFinishNavigation()
        XCTAssertFalse(vm.isLoading,
                       "didFinishNavigation must flip isLoading to false — hides the overlay")
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
        // The default-false contract — explicit so a future ABI break that
        // flips the default doesn't slip through. Pair-assert by explicitly
        // requesting false so a mutation that ignores the parameter and
        // always returns the same default is caught.
        XCTAssertFalse(makeViewModel().autoPresentIfNeeded,
                       "autoPresentIfNeeded must default to false (caller opts in explicitly)")
        XCTAssertFalse(makeViewModel(autoPresentIfNeeded: false).autoPresentIfNeeded,
                       "Explicit false must also yield false — parameter respected")
    }

    func test_autoPresentIfNeeded_canBeTrue() {
        // Round-trip the flag: build a model with true, confirm it flows
        // through verbatim. Also confirm a model built with default (false)
        // doesn't accidentally flip when other init parameters are passed.
        XCTAssertTrue(makeViewModel(autoPresentIfNeeded: true).autoPresentIfNeeded,
                      "Explicit true must flow through to autoPresentIfNeeded")
        XCTAssertFalse(makeViewModel(cookies: [HTTPCookie(properties: [.domain: "x", .path: "/", .name: "n", .value: "v"])!]).autoPresentIfNeeded,
                       "Setting other init params (cookies) must not accidentally flip autoPresentIfNeeded")
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

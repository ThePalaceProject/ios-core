//
//  SignInWebSheetIntegrationTests.swift
//  PalaceTests
//
//  Integration tests that drive a real WKWebView through SignInWebViewCoordinator
//  to verify the end-to-end navigation policy pipeline:
//
//    WKNavigationDelegate -> SignInWebSheetViewModel.decideAction(...) ->
//    decisionHandler(.cancel) -> async cookie store query ->
//    SignInWebSheetViewModel.recordLoginCompletion(...)
//
//  These complement SignInWebSheetViewModelTests (which exercise the
//  decision logic in pure isolation) by catching wiring regressions —
//  e.g., a deadlock between the WKWebView's decisionHandler timeout and
//  the Coordinator's async cookie fetch, or the coordinator being
//  deallocated mid-flight.
//
//  CI-safe: uses XCTestExpectation + data: URL fixtures, no sleeps,
//  no network access. The data: URL fixture redirects to a fake
//  universal-links URL via JavaScript so WebKit invokes the navigation
//  policy delegate without us having to construct WKNavigationAction
//  manually (it has no public initializer).
//

import XCTest
import WebKit
import Combine
@testable import Palace

@MainActor
final class SignInWebSheetIntegrationTests: XCTestCase {

    // Use a non-real domain we can control. The view model's
    // universalLinksURL is configurable in init, so we don't have to
    // hit the real librarysimplified.org callback URL.
    private let universalLinks = URL(string: "https://palace.test/callback/SimplyE")!
    private let initialPage = URL(string: "https://idp.test.local/login")!

    private var window: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        // WKWebView won't fully wire up navigation delegate calls without a
        // window, so attach one for the test's lifetime.
        window = UIWindow(frame: UIScreen.main.bounds)
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        try await super.tearDown()
    }

    // MARK: - End-to-end: navigation to universal-links triggers loginCompletion

    func test_navigatingToUniversalLinksURL_firesLoginCompletionWithCookies() async throws {
        // ARRANGE: build a coordinator wrapping a view model whose loginCompletion
        // fulfills our expectation. Stand up a real WKWebView whose data:
        // initial page contains an auto-redirect to the universal-links URL.
        let loginExpectation = expectation(description: "loginCompletion fires")
        var capturedURL: URL?

        let viewModel = SignInWebSheetViewModel(
            cookies: [],
            request: URLRequest(url: initialPage),
            universalLinksURL: universalLinks,
            loginCompletionHandler: { url, _ in
                capturedURL = url
                loginExpectation.fulfill()
            }
        )

        let coordinator = SignInWebViewCoordinator(viewModel: viewModel)
        let webView = WKWebView(frame: window.bounds)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        window.addSubview(webView)

        // The HTML page does a JavaScript-driven location change to the
        // universal-links URL. WebKit will fire decidePolicyFor:navigationAction
        // for that nav, which the Coordinator forwards to the view model.
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body>
        <script>
        setTimeout(function() {
            window.location.href = '\(universalLinks.absoluteString)?token=test123';
        }, 50);
        </script>
        </body></html>
        """

        // ACT
        webView.loadHTMLString(html, baseURL: URL(string: "https://idp.test.local"))

        // ASSERT — wait up to 30s for the redirect navigation to be intercepted.
        // 5s wasn't enough on shared GH macOS runners; 15s still intermittently
        // missed (run 26108544964 timed out at 15.0s, 37.97s elapsed). WKWebView
        // cold-starts three helper processes (WebContent, GPU, Networking) and
        // on memory-pressured CI nodes (the same runs report "Skipping image
        // cache due to low memory (49 MB available)") the JS-setTimeout + nav
        // IPC pipeline can stretch into 20s+. 30s tolerates that without making
        // a wedged delegate hide forever.
        await fulfillment(of: [loginExpectation], timeout: 30.0) // FLAKE-003-OK: real WKWebView cold-start (WebContent + GPU + Networking helpers) + JS-setTimeout + nav IPC under memory-pressured CI nodes.
        XCTAssertEqual(capturedURL?.absoluteString, "\(universalLinks.absoluteString)?token=test123")
    }

    // MARK: - End-to-end: cookies are injected before load fires

    func test_initialLoad_injectsCookiesBeforeLoadingRequest() async throws {
        // ARRANGE: prime two cookies; verify both end up in the WKWebView's
        // cookie store when the initial request fires. This covers the
        // injectCookiesAndLoad seam that replaces the legacy "cookiesLeft"
        // counter loop.
        let cookie1 = HTTPCookie(properties: [
            .domain: "idp.test.local",
            .path: "/",
            .name: "session",
            .value: "v1",
        ])!
        let cookie2 = HTTPCookie(properties: [
            .domain: "idp.test.local",
            .path: "/",
            .name: "csrf",
            .value: "v2",
        ])!

        let viewModel = SignInWebSheetViewModel(
            cookies: [cookie1, cookie2],
            request: URLRequest(url: initialPage),
            universalLinksURL: universalLinks
        )

        let webView = WKWebView(frame: window.bounds)
        let injector = webView.configuration.websiteDataStore.httpCookieStore

        var loadFired = false
        await viewModel.injectCookiesAndLoad(into: injector) { _ in
            loadFired = true
        }

        // ASSERT: load fired exactly once after both cookies were placed
        XCTAssertTrue(loadFired)
        let allCookies = await injector.allCookies()
        let cookieNames = Set(allCookies.map { $0.name })
        XCTAssertTrue(cookieNames.contains("session"))
        XCTAssertTrue(cookieNames.contains("csrf"))
    }

    // MARK: - End-to-end: loading state transitions during a real navigation

    func test_loadingOverlay_startsTrueAndBecomesFalseOnNavigationFinish() async throws {
        // ARRANGE
        let viewModel = SignInWebSheetViewModel(
            cookies: [],
            request: URLRequest(url: initialPage),
            universalLinksURL: universalLinks
        )

        let coordinator = SignInWebViewCoordinator(viewModel: viewModel)
        let webView = WKWebView(frame: window.bounds)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        window.addSubview(webView)

        XCTAssertTrue(viewModel.isLoading, "Pre-load: overlay must be visible")

        // ACT: load a trivial page; observe @Published isLoading until it flips to false
        let exp = expectation(description: "isLoading flips to false after didFinish")
        let cancellable = viewModel.$isLoading.sink { isLoading in
            if !isLoading { exp.fulfill() }
        }
        webView.loadHTMLString("<html><body>OK</body></html>", baseURL: URL(string: "https://idp.test.local"))

        // ASSERT — 15s for the same WebKit cold-start reason as the test above.
        await fulfillment(of: [exp], timeout: 15.0) // FLAKE-003-OK: real WKWebView cold-start (WebContent + GPU + Networking helpers) under CI load.
        XCTAssertFalse(viewModel.isLoading, "Post-load: overlay must be hidden")
        cancellable.cancel()
    }
}

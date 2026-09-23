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
        //
        // KNOWN FLAKY, DELIBERATELY NOT "FIXED". This failed at 10.770s in run
        // 32988283084 (PR #1422), and the failing line was a cookie assertion,
        // not `loadFired` — `injectCookiesAndLoad` calls `loadHandler`
        // synchronously after awaiting every `setCookie`, so `loadFired` is
        // deterministic by construction.
        //
        // That means the ordering did not hold in that run. At least three
        // candidate causes, with very different stakes:
        //
        //   1. WebKit's store lagging behind an honest continuation — test-only.
        //   2. `allCookies()` is a SEPARATE round trip, so a stale READ can
        //      report absence for a cookie that is committed — also test-only.
        //   3. `WKHTTPCookieStore.setCookie`'s `withCheckedContinuation` bridge
        //      resuming BEFORE the cookie is committed — a real sign-in-path
        //      race, in which the initial SAML request goes out uncredentialed.
        //
        // Do NOT read the 10.770s duration as "a contended machine". This class
        // is in xcode-test-optimized.sh's ISOLATED_SERIAL_TESTS, so every CI
        // result for it comes from the SERIAL pass with
        // `-parallel-testing-enabled NO` — there were no competing clones.
        //
        // THE SHARPEST DATUM, and the one that narrows the space: in run
        // 32988283084 the `contains("session")` assertion errored and the
        // `contains("csrf")` one did not. So `session` — written FIRST — was
        // absent while `csrf`, written second, was present. (Cited by assertion
        // rather than by line number: this comment block itself moved those
        // lines from 148/149 to 200/201, so a line citation was stale the
        // moment it was written.)
        //
        // That is not consistent with everything:
        //   * a read that snapshotted before both writes would miss BOTH;
        //   * a uniformly lagging store would not preferentially miss the
        //     EARLIER write.
        // It IS consistent with per-cookie commit lag — which (1) and (3) BOTH
        // produce, so it narrows the space without picking a winner. The
        // earlier "nothing separates them" was wrong; "points at the expensive
        // cause" would be equally wrong in the other direction.
        //
        // A fourth candidate is live and worth naming: this test uses the
        // shared `.default()` persistent data store and neither setUp nor
        // tearDown clears cookies, so cross-test residue can populate or
        // shadow the store independently of this seam.
        //
        // A local probe over 25 iterations found the loaded page's
        // document.cookie carrying both cookies every time (storeMisses=0,
        // pageMisses=0). That FAILS TO REPRODUCE on a quiet machine; it does
        // not refute (3), and should not be cited as if it did.
        //
        // An earlier version of this branch made the read wait until the cookies
        // appeared. That removes the flake and ALSO removes the signal: a bridge
        // that resumes early and lands 50ms later would then pass. Since this
        // test cannot fully separate them, it is left asserting strictly and
        // flaking rather than made quiet. Deliberately NOT switched to a
        // `.nonPersistent()` data store either: that would remove cross-test
        // leakage, but if the commit lag is a property of the persistent store
        // it would also remove the phenomenon — the same
        // `deflake-destroys-the-signal` trap in a subtler form.
        //
        // Do not "de-flake" this by waiting. Answer which cause it is first.
        // Registered as `deflake-destroys-the-signal` in
        // docs/regressions/recurrence-classes.md — cite that id when fixing it.
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

        // ASSERT — 30s, matching the test above rather than half of it.
        //
        // This read 15s under a comment saying "the same WebKit cold-start
        // reason as the test above", while that test uses 30s after a recorded
        // history of 5s and then 15s both proving insufficient. It cited the
        // right reason and then took half the budget that reason justifies —
        // and duly failed at 27.836s in run 32875518211 — in that run's SERIAL
        // isolated pass, with `-parallel-testing-enabled NO`. So 15s was
        // inadequate with no clone contention at all, which is a stronger case
        // for the bump than "under CI load" suggests. Note that run's
        // conclusion is SUCCESS: the failure was masked by retry, so opening
        // the run page shows green and the per-iteration scan
        // (`ci-test-history.py --scan --run 32875518211`) is what shows it.
        //
        // A second datum makes the margin concrete: run 33009253108 PASSED this
        // test at 14.291s, again in the serial pass. Note the arithmetic that
        // does NOT follow — 14.291s is the case duration, so it bounds the wait
        // at AT MOST 14.291s and the slack at AT LEAST 0.7s, not exactly 0.7s.
        // (Subtracting a deadline from a duration is the very step the
        // paragraph above says is invalid; in the 27.836s run the non-wait
        // overhead was ~12.8s.) The conclusion survives on the device-clock
        // trace rather than the arithmetic: that run's test spans 20:39:51.566
        // to 20:40:05.859 with the WebContent/GPU launches inside the window
        // and ~0.03s of teardown, so the wait itself consumed ~14.2s of a 15.0s
        // budget — or more precisely, somewhere in [~10.25s, ~14.29s]: the
        // trace bounds the CASE, and the wait is a sub-interval of it. (The
        // 27.836s run shows why the tighter reading is unsafe: ~12.8s of its
        // duration sat BEFORE the wait.) Either bound leaves 15s marginal.
        //
        // What the evidence actually bounds: the recorded 27.836s is xcodebuild's
        // per-test-case DURATION, not the fulfillment latency, so it includes
        // setUp and ARRANGE around a wait that consumed exactly its 15.0s
        // budget. (The reported duration ends at teardown's START — measured
        // at 9ms and 3ms in the two runs — so the overhead is entirely
        // pre-wait, which only strengthens the point.) It therefore proves ">15s needed" and nothing sharper.
        // 30s is chosen for parity with the sibling above, not because 27.836s
        // was measured inside it. (CI's own run also passes
        // `-default-test-execution-time-allowance 120`, which caps a wedged
        // test regardless — but that is one branch of
        // xcode-test-optimized.sh, not a global default: verify-pr.sh passes no
        // allowance at all.)
        //
        // Deliberately still `fulfillment(of:)` rather than a polling helper. A
        // poll is also a fixed wall-clock deadline, just one STARVE-001 cannot
        // see — `STARVE_PATTERNS` matches `wait(for:` / `fulfillment(of:` /
        // `waitForExpectations(` and nothing else. Swapping to a poll would have
        // moved this wait out of the lint's view while leaving it exactly as
        // load-sensitive.
        await fulfillment(of: [exp], timeout: 30.0) // STARVE-001-OK: not a fire-and-forget Task wait — it waits on a real WKWebView navigation, which is the bounded-dependency case the rule's own escape hatch describes. CI additionally runs this class in xcode-test-optimized.sh's serial-isolation list (BUILD_CONTEXT=ci only; the local path still runs 4 parallel workers, so that is a mitigation, not an exemption). // FLAKE-003-OK: real WKWebView cold-start (WebContent + GPU + Networking helpers); 15s observed insufficient with parallelism OFF, so this is not a contention allowance. See the block comment for what the timings do and do not bound.
        XCTAssertFalse(viewModel.isLoading, "Post-load: overlay must be hidden")
        cancellable.cancel()
    }
}

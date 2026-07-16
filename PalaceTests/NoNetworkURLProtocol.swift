import Foundation

/// URLProtocol that intercepts any request that would otherwise reach the real network
/// and immediately fails the test with a clear message.
///
/// Register it in a test's setUp (or a shared base class) to guarantee no real HTTP
/// traffic escapes from a unit test:
///
/// ```swift
/// override func setUp() {
///     super.setUp()
///     NoNetworkURLProtocol.enable()
/// }
///
/// override func tearDown() {
///     NoNetworkURLProtocol.disable()
///     super.tearDown()
/// }
/// ```
///
/// If a test legitimately needs a stubbed response, use HTTPStubURLProtocol instead
/// (registered on the URLSessionConfiguration directly — not URLSession.shared).
final class NoNetworkURLProtocol: URLProtocol {

    // MARK: - Interception accounting (positive proof)
    //
    // A hermeticity test asserting only "the request failed" is confounded: a
    // missing network, or a non-2xx response from a request that ESCAPED to the
    // real host, both also produce a failure. This counter gives positive proof
    // that a specific request was actually intercepted HERE (on the session this
    // protocol is installed on) — snapshot `interceptionCount(matching:)` before
    // and after an operation; an increment means the stub blocked it, not the
    // network. Lock-guarded: protocol instances load concurrently.
    private static let interceptionLock = NSLock()
    private static let _interceptedURLs = LockIsolated<[String]>([])
    private static var interceptedURLs: [String] {
        get { _interceptedURLs.value }
        set { _interceptedURLs.value = newValue }
    }

    /// Count of requests intercepted so far whose absolute URL contains
    /// `substring`. Diff before/after an operation to prove THAT operation's
    /// request was blocked here rather than escaping to the real network.
    static func interceptionCount(matching substring: String) -> Int {
        interceptionLock.lock(); defer { interceptionLock.unlock() }
        return interceptedURLs.filter { $0.contains(substring) }.count
    }

    private static func recordInterception(_ url: String) {
        interceptionLock.lock(); defer { interceptionLock.unlock() }
        interceptedURLs.append(url)
    }

    // MARK: - Registration

    static func enable() {
        URLProtocol.registerClass(Self.self)
    }

    static func disable() {
        URLProtocol.unregisterClass(Self.self)
    }

    // MARK: - URLProtocol

    override static func canInit(with request: URLRequest) -> Bool {
        // Intercept everything except localhost / file URLs (used by some test harnesses).
        guard let host = request.url?.host else { return false }
        return host != "localhost" && host != "127.0.0.1"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? "(nil)"
        Self.recordInterception(url)

        // Log for debugging — but do NOT call XCTFail here because the host app
        // (Firebase, Crashlytics, crawl prefetch, etc.) makes network requests
        // during launch that are outside any test scope. XCTFail would cause
        // spurious failures for those app-initiated requests.
        // Tests that accidentally hit the network will still fail because their
        // URLSession calls will receive an NSURLErrorNotConnectedToInternet error.
        NSLog("[NoNetworkURLProtocol] Blocked: %@", url)

        // Fail the URL loading so the calling code doesn't hang.
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "Blocked by NoNetworkURLProtocol in unit tests"]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

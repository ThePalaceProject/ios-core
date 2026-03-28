import Foundation
import XCTest

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
        let message = """
        NoNetworkURLProtocol intercepted a real network request to:
          \(url)

        Unit tests must not make real network calls.
        • Use HTTPStubURLProtocol on a custom URLSessionConfiguration.
        • Inject a mock network layer via the type's initializer.
        • If this is an integration test, skip it in unit-test runs with XCTSkipUnless.
        """
        XCTFail(message)

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

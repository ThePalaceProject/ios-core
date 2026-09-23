//
//  CoverSourceBadResponseCacheTests.swift
//  PalaceTests
//
//  Pins what `TPPBookCoverRegistry.sourceData(for:)` is allowed to remember.
//
//  The decode helper is already covered — `downsampleImage` returns nil for
//  empty data, garbage data and bad dimensions (TPPBookCoverRegistryTests).
//  What was NOT covered is the PRODUCER: the fetch discards its URLResponse
//  into `_` and caches whatever body came back, so a 200-with-no-body or an
//  error page is stored under the cover's URL key. Every later request for that
//  cover then serves the same unusable bytes from cache, and the generated
//  TenPrint placeholder becomes permanent for the process lifetime instead of
//  recovering on the next scroll.
//
//  These tests assert the recovery property a patron actually experiences: a bad
//  response must not poison the cover. The third test is the control — a GOOD
//  response must still be cached, so "never cache" is not a passing fix.
//

import XCTest
@testable import Palace

/// Serves a scripted (status, body) per URL and counts requests, so a test can
/// prove whether a second fetch re-requested or was served from cache.
final class ScriptedCoverURLProtocol: URLProtocol {

    struct Response {
        let status: Int
        let body: Data
    }

    private static let state = LockIsolated<[String: Response]>([:])
    private static let counts = LockIsolated<[String: Int]>([:])

    static func script(_ url: URL, status: Int, body: Data) {
        state.withValue { $0[url.absoluteString] = Response(status: status, body: body) }
    }

    static func requestCount(for url: URL) -> Int {
        counts.value[url.absoluteString] ?? 0
    }

    static func reset() {
        state.withValue { $0.removeAll() }
        counts.withValue { $0.removeAll() }
    }

    /// A session that actually consults this protocol. `URLProtocol.registerClass`
    /// does NOT reach a session built from a configuration — only
    /// `configuration.protocolClasses` does — so the stub has to be installed on
    /// the configuration and injected through the registry's `urlSession` seam.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        return state.value[url] != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let scripted = Self.state.value[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.counts.withValue { $0[url.absoluteString, default: 0] += 1 }

        let response = HTTPURLResponse(
            url: url,
            statusCode: scripted.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !scripted.body.isEmpty {
            client?.urlProtocol(self, didLoad: scripted.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CoverSourceBadResponseCacheTests: XCTestCase {

    private var registry: TPPBookCoverRegistry!

    override func setUp() {
        super.setUp()
        ScriptedCoverURLProtocol.reset()
        registry = TPPBookCoverRegistry(
            imageCache: MockImageCache(),
            urlSession: ScriptedCoverURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        ScriptedCoverURLProtocol.reset()
        registry = nil
        super.tearDown()
    }

    /// A real, decodable JPEG — generated rather than checked in, because these
    /// tests are about the fetch, not about any particular image's bytes.
    private func validJPEG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    /// A 200 with a zero-length body is the ONE condition that makes the decode
    /// fail (truncated JPEGs still decode). It must not be remembered: when the
    /// host next serves the real image, the cover must appear.
    func testEmptyBodyResponse_isNotCached_soALaterFetchRecovers() async throws {
        let url = try XCTUnwrap(URL(string: "https://covers.test/empty-body.jpg"))

        ScriptedCoverURLProtocol.script(url, status: 200, body: Data())
        let first = await registry.fetchImageByURL(url, identifier: "empty-body", isCover: true)
        XCTAssertNil(first, "A zero-length body cannot decode, so no image should come back")
        XCTAssertEqual(ScriptedCoverURLProtocol.requestCount(for: url), 1)

        // The host recovers and now serves the real cover.
        ScriptedCoverURLProtocol.script(url, status: 200, body: try validJPEG())
        let second = await registry.fetchImageByURL(url, identifier: "empty-body", isCover: true)

        XCTAssertEqual(
            ScriptedCoverURLProtocol.requestCount(for: url), 2,
            "The empty body must not be cached — the second fetch has to go back to the host"
        )
        XCTAssertNotNil(second, "Once the host serves real bytes the cover must appear")
    }

    /// A 404/500 body is non-empty garbage. It decodes to nil and, because the
    /// response is discarded, is treated as a successful fetch and cached.
    func testErrorStatusResponse_isNotCached_soALaterFetchRecovers() async throws {
        let url = try XCTUnwrap(URL(string: "https://covers.test/error-page.jpg"))
        let errorPage = Data("<html><body>404 Not Found</body></html>".utf8)

        ScriptedCoverURLProtocol.script(url, status: 404, body: errorPage)
        let first = await registry.fetchImageByURL(url, identifier: "error-page", isCover: true)
        XCTAssertNil(first, "An HTML error page is not an image")
        XCTAssertEqual(ScriptedCoverURLProtocol.requestCount(for: url), 1)

        ScriptedCoverURLProtocol.script(url, status: 200, body: try validJPEG())
        let second = await registry.fetchImageByURL(url, identifier: "error-page", isCover: true)

        XCTAssertEqual(
            ScriptedCoverURLProtocol.requestCount(for: url), 2,
            "A non-2xx body must not be cached — the second fetch has to go back to the host"
        )
        XCTAssertNotNil(second, "Once the host serves real bytes the cover must appear")
    }

    /// CONTROL. A good response MUST still be cached, otherwise "never cache
    /// anything" would pass the two tests above while making every scroll refetch
    /// every cover.
    func testSuccessfulResponse_isStillCached_soASecondFetchDoesNotRefetch() async throws {
        let url = try XCTUnwrap(URL(string: "https://covers.test/good.jpg"))
        ScriptedCoverURLProtocol.script(url, status: 200, body: try validJPEG())

        let first = await registry.fetchImageByURL(url, identifier: "good", isCover: true)
        XCTAssertNotNil(first)
        XCTAssertEqual(ScriptedCoverURLProtocol.requestCount(for: url), 1)

        let second = await registry.fetchImageByURL(url, identifier: "good-second-key", isCover: true)
        XCTAssertNotNil(second)
        XCTAssertEqual(
            ScriptedCoverURLProtocol.requestCount(for: url), 1,
            "A good body must be cached by URL — a second fetch must not re-request it"
        )
    }
}

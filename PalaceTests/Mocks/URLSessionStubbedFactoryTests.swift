//
//  URLSessionStubbedFactoryTests.swift
//  PalaceTests
//
//  Wave 2 (swarm_b503a876 Module A) — pins the per-call factory
//  `URLSession.stubbed(handlers:)` that returns a FRESH `URLSession`
//  per call (no caching). The legacy `URLSession.stubbedSession()`
//  process-wide singleton stays for backward compatibility; the new
//  factory exists so new tests can own their session's lifetime and
//  avoid the cross-test handler stacking documented in transcript D of
//  swarm_f88ae9e3.
//

import Foundation
import XCTest
@testable import Palace

final class URLSessionStubbedFactoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.removeAllHandlers()
    }

    override func tearDown() {
        HTTPStubURLProtocol.removeAllHandlers()
        super.tearDown()
    }

    // MARK: - 1. Per-call freshness

    func testStubbed_yieldsDistinctSessionInstancePerCall() {
        let first = URLSession.stubbed()
        let second = URLSession.stubbed()
        defer {
            first.finishTasksAndInvalidate()
            second.finishTasksAndInvalidate()
        }
        XCTAssertFalse(
            first === second,
            "stubbed() must return a fresh URLSession per call — no caching, " +
            "so callers can own their session's lifetime independently."
        )
    }

    // MARK: - 2. Independent invalidation

    func testStubbed_invalidatingOneSession_doesNotAffectAnother() throws {
        // Setup: register a stub that returns 200 to a known URL. Both
        // sessions should be able to satisfy a request before either is
        // invalidated.
        HTTPStubURLProtocol.registerHandler(
            matching: { $0.path == "/factory-test" },
            response: HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: nil,
                body: Data("ok".utf8)
            )
        )

        let sessionA = URLSession.stubbed()
        let sessionB = URLSession.stubbed()
        defer { sessionB.finishTasksAndInvalidate() }

        let url = try XCTUnwrap(URL(string: "https://example.com/factory-test"))

        // Invalidate A; B must still complete a fresh request.
        sessionA.finishTasksAndInvalidate()

        let completed = expectation(description: "session B completes after A invalidated")
        sessionB.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, Data("ok".utf8))
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 5.0)
    }

    // MARK: - 3. Custom handlers prepend ahead of HTTPStubURLProtocol

    func testStubbed_withAdditionalHandler_prependsItAheadOfHTTPStub() {
        // Pin the order so callers know a handlers parameter inserts
        // BEFORE the stub protocol — gives the additional handler first
        // crack at any request.
        let session = URLSession.stubbed(handlers: [HighPriorityProbeProtocol.self])
        defer { session.finishTasksAndInvalidate() }

        let protocolClasses = session.configuration.protocolClasses ?? []
        guard protocolClasses.count >= 2 else {
            return XCTFail("expected at least two URLProtocol entries, got \(protocolClasses.count)")
        }

        // The handler-supplied protocol should be ahead of
        // HTTPStubURLProtocol in iteration order.
        let probeIdx = protocolClasses.firstIndex { $0 == HighPriorityProbeProtocol.self }
        let stubIdx = protocolClasses.firstIndex { $0 == HTTPStubURLProtocol.self }
        XCTAssertNotNil(probeIdx)
        XCTAssertNotNil(stubIdx)
        if let p = probeIdx, let s = stubIdx {
            XCTAssertLessThan(p, s, "additional handlers must precede HTTPStubURLProtocol")
        }
    }
}

/// Test-local URLProtocol used solely to verify the handler-order
/// contract of `URLSession.stubbed(handlers:)`. Never registered into
/// any session that actually serves traffic.
private final class HighPriorityProbeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { return false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() {}
    override func stopLoading() {}
}

//
//  HTTPStubURLProtocolPredicateMatchingTests.swift
//  PalaceTests
//
//  Wave 2 (swarm_b503a876 Module A) — pins the predicate-handler
//  registry on `HTTPStubURLProtocol`. The new API was introduced to
//  narrow the protocol's `canInit(with:)` from unconditional `true` to
//  URL-gated interception, eliminating the "intercept everything"
//  cross-class-pollution surface documented in transcript D of
//  swarm_f88ae9e3. These tests prove:
//
//   1. With NO handlers registered, `canInit` returns false — the
//      protocol does not intercept arbitrary URLs out of the box.
//   2. With ONLY predicate handlers registered, `canInit` returns true
//      only for URLs that match a predicate.
//   3. Legacy `register(_:)` and new `registerHandler(matching:response:)`
//      coexist: legacy callers keep unconditional interception, and
//      predicate matches take precedence in `handler(for:)` resolution.
//

import Foundation
import XCTest
@testable import Palace

final class HTTPStubURLProtocolPredicateMatchingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.removeAllHandlers()
    }

    override func tearDown() {
        HTTPStubURLProtocol.removeAllHandlers()
        super.tearDown()
    }

    // MARK: - 1. Empty registry — canInit returns false

    func testCanInit_withNoHandlersRegistered_returnsFalse() {
        guard let url = URL(string: "https://example.com/anything") else {
            return XCTFail("URL construction failed")
        }
        let request = URLRequest(url: url)
        XCTAssertFalse(
            HTTPStubURLProtocol.canInit(with: request),
            "canInit must return false when no handlers (legacy or predicate) are registered, " +
            "so the request falls through to the next URLProtocol cleanly."
        )
    }

    // MARK: - 2. Predicate match — canInit returns true only on match

    func testCanInit_withPredicateMatchingURL_returnsTrue() {
        HTTPStubURLProtocol.registerHandler(
            matching: { $0.absoluteString.hasPrefix("https://api.example.com/") },
            response: HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        )

        guard let matching = URL(string: "https://api.example.com/v1/users") else {
            return XCTFail("URL construction failed")
        }
        XCTAssertTrue(
            HTTPStubURLProtocol.canInit(with: URLRequest(url: matching)),
            "canInit must return true for a URL the predicate accepts"
        )
    }

    func testCanInit_withPredicateNotMatchingURL_returnsFalse() {
        HTTPStubURLProtocol.registerHandler(
            matching: { $0.absoluteString.hasPrefix("https://api.example.com/") },
            response: HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        )

        guard let nonMatching = URL(string: "https://other.example.com/v1/users") else {
            return XCTFail("URL construction failed")
        }
        XCTAssertFalse(
            HTTPStubURLProtocol.canInit(with: URLRequest(url: nonMatching)),
            "canInit must return false when no predicate matches — request falls through cleanly"
        )
    }

    func testCanInit_withRegexLikePredicate_matchesOnExpectedShape() {
        // Predicate-based registration accepts an arbitrary closure, so
        // regex-shaped matching works without API changes — the closure
        // is the only seam.
        let pattern: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"^https://[a-z]+\.cdn\.example\.com/.*\.json$"#
        )
        guard let regex = pattern else {
            return XCTFail("regex compile failed")
        }
        HTTPStubURLProtocol.registerHandler(
            matching: { url in
                let str = url.absoluteString
                let range = NSRange(str.startIndex..<str.endIndex, in: str)
                return regex.firstMatch(in: str, range: range) != nil
            },
            response: HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        )

        guard let matching = URL(string: "https://east.cdn.example.com/catalog.json"),
              let nonMatching = URL(string: "https://east.cdn.example.com/catalog.html") else {
            return XCTFail("URL construction failed")
        }
        XCTAssertTrue(HTTPStubURLProtocol.canInit(with: URLRequest(url: matching)))
        XCTAssertFalse(HTTPStubURLProtocol.canInit(with: URLRequest(url: nonMatching)))
    }

    // MARK: - 3. Legacy + new API coexist

    func testCanInit_withLegacyHandlerRegistered_returnsTrueForArbitraryURL() {
        // Legacy callers (33 existing files) expect unconditional
        // interception. Registering a legacy handler MUST keep canInit
        // returning true for any URL, even one no predicate would match.
        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        }

        guard let url = URL(string: "https://nothing-matches-this-host.example/") else {
            return XCTFail("URL construction failed")
        }
        XCTAssertTrue(
            HTTPStubURLProtocol.canInit(with: URLRequest(url: url)),
            "Legacy handler presence preserves unconditional-true canInit for backward compatibility"
        )
    }

    func testHandlerResolution_predicateMatchTakesPrecedenceOverLegacy() throws {
        // When both APIs are in play, predicate matches should win over
        // legacy fall-through so new callers can carve out URL-specific
        // responses without disturbing legacy handlers. We exercise this
        // through the end-to-end `URLSession` path: a legacy handler
        // claims everything with 500; a predicate handler claims one URL
        // with 200. The predicate-matched request must get 200.
        let legacyResponseBody = Data("LEGACY".utf8)
        let predicateResponseBody = Data("PREDICATE".utf8)

        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(
                statusCode: 500,
                headers: nil,
                body: legacyResponseBody
            )
        }
        HTTPStubURLProtocol.registerHandler(
            matching: { $0.absoluteString == "https://predicate.example.com/specific" },
            response: HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: nil,
                body: predicateResponseBody
            )
        )

        let session = URLSession.stubbed()
        defer { session.finishTasksAndInvalidate() }

        // Predicate-matched URL — must get the 200 response.
        let predicateURL = try XCTUnwrap(URL(string: "https://predicate.example.com/specific"))
        let predicateExp = expectation(description: "predicate URL completes")
        session.dataTask(with: predicateURL) { data, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, predicateResponseBody)
            predicateExp.fulfill()
        }.resume()

        // Non-matching URL — legacy fallback gives 500.
        let legacyURL = try XCTUnwrap(URL(string: "https://other.example.com/path"))
        let legacyExp = expectation(description: "legacy URL completes")
        session.dataTask(with: legacyURL) { data, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
            XCTAssertEqual(data, legacyResponseBody)
            legacyExp.fulfill()
        }.resume()

        wait(for: [predicateExp, legacyExp], timeout: 5.0)
    }
}

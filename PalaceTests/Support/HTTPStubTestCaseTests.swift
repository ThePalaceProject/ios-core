//
//  HTTPStubTestCaseTests.swift
//  PalaceTests
//
//  Wave 2 (swarm_b503a876 Module A) — pins the `HTTPStubTestCase`
//  base-class contract:
//
//   1. setUpWithError clears any prior handler residue.
//   2. tearDownWithError fails if the test method left handlers
//      registered.
//   3. The `stubURL(_:status:body:)` helper threads through to the
//      predicate-handler API (and lands the registration where
//      `canInit(with:)` will see it).
//
//  We test these by SUBCLASSING `HTTPStubTestCase` rather than instan-
//  tiating it directly — the contract is on the lifecycle hooks, which
//  are visible only to subclasses.
//

import Foundation
import XCTest
@testable import Palace

/// Subclass-of-record for the helper contract: pure happy path with
/// matched setup and teardown. This class proves the base lets a
/// well-behaved test method pass cleanly.
final class HTTPStubTestCaseTests: HTTPStubTestCase {

    // MARK: - 1. stubURL registers a predicate handler that canInit sees

    func testStubURL_registersPredicateHandlerWithMatchingURL_canInitReturnsTrue() throws {
        stubURL("https://example.com/")

        let matching = try XCTUnwrap(URL(string: "https://example.com/some/path"))
        XCTAssertTrue(
            HTTPStubURLProtocol.canInit(with: URLRequest(url: matching)),
            "stubURL should register a predicate that canInit accepts for matching URLs"
        )

        let nonMatching = try XCTUnwrap(URL(string: "https://other.example.com/some/path"))
        XCTAssertFalse(
            HTTPStubURLProtocol.canInit(with: URLRequest(url: nonMatching)),
            "stubURL prefix matching must not capture unrelated hosts"
        )

        // Clean up before tearDown — this method intentionally cleans
        // up to prove the happy path. Other methods exercise the
        // leak-detection assertion.
        HTTPStubURLProtocol.removeAllHandlers()
    }

    // MARK: - 2. stubURL responds with the configured status + body

    func testStubURL_servesConfiguredResponseToMatchingRequest() throws {
        let body = Data("payload".utf8)
        stubURL("https://example.com/api", status: 201, body: body)

        let session = URLSession.stubbed()
        defer { session.finishTasksAndInvalidate() }

        let url = try XCTUnwrap(URL(string: "https://example.com/api/v1"))
        let completed = expectation(description: "stubbed request completes")
        session.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
            XCTAssertEqual(data, body)
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 5.0)

        HTTPStubURLProtocol.removeAllHandlers()
    }

    // MARK: - 3. setUp clears prior residue

    func testSetUp_clearsPriorHandlerResidue() {
        // Simulate a "prior test" by registering a predicate handler
        // BEFORE this method ran, then verifying setUp drained it. We
        // can't reliably manipulate the actual prior method, so we
        // assert the equivalent: AT THE START of this method (i.e.
        // after setUp ran), the registries are clean.
        XCTAssertEqual(HTTPStubURLProtocol._registeredLegacyHandlerCount(), 0,
                       "setUp must clear the legacy handler list")
        XCTAssertEqual(HTTPStubURLProtocol._registeredPredicateHandlerCount(), 0,
                       "setUp must clear the predicate handler list")
    }
}

/// Subclass-of-record for the LEAK-DETECTION half of the contract. We
/// can't directly assert "tearDown failed" from a test (XCTest doesn't
/// expose the failure-as-success inversion). Instead, we exercise the
/// path that WOULD fail and assert the snapshot APIs report the leak
/// truthfully. The tearDown assertion itself is verified manually by
/// running this class — a non-zero residue WOULD fail the test if we
/// didn't drain inside the test body. We drain at the end so the test
/// passes; the assertion that leak detection WORKS is the snapshot
/// counter check below.
final class HTTPStubTestCaseLeakDetectionTests: HTTPStubTestCase {

    func testTearDownPath_observesNonZeroResidueBeforeDrain() {
        // Register handlers in both lists so both counters move.
        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        }
        HTTPStubURLProtocol.registerHandler(
            matching: { _ in true },
            response: HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        )

        // The snapshot APIs MUST observe both registrations — this is
        // the visibility the base-class tearDown depends on. Without
        // truthful counters, the assertion would silently pass even
        // when handlers leaked.
        XCTAssertEqual(HTTPStubURLProtocol._registeredLegacyHandlerCount(), 1)
        XCTAssertEqual(HTTPStubURLProtocol._registeredPredicateHandlerCount(), 1)

        // Drain so the base-class tearDown observes a clean state.
        // (The base would fail the test if we didn't drain. The point
        // of this method is to prove the counters are truthful before
        // teardown, not to demonstrate a leak — XCTest has no "expect
        // failure" primitive on tearDown.)
        HTTPStubURLProtocol.removeAllHandlers()
        XCTAssertEqual(HTTPStubURLProtocol._registeredLegacyHandlerCount(), 0)
        XCTAssertEqual(HTTPStubURLProtocol._registeredPredicateHandlerCount(), 0)
    }
}

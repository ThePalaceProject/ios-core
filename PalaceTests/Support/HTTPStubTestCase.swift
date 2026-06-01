//
//  HTTPStubTestCase.swift
//  PalaceTests
//
//  Base class for new tests that exercise URLSession via
//  `HTTPStubURLProtocol`. Wave 2, swarm_b503a876 Module A.
//
//  Closes the "forgot to reset" failure mode documented in
//  `.forgeos/swarms/swarm_f88ae9e3/transcripts/D-network-stub-race.md`.
//  The base class drains the predicate-handler list (and the legacy
//  array, defensively) on every `setUpWithError` and asserts on
//  `tearDownWithError` that the test method removed everything it
//  registered. Either guarantee on its own would catch most leaks;
//  together they make the failure mode structurally impossible to
//  reintroduce in tests that adopt this base.
//
//  The existing 33 callers do NOT migrate this PR — they keep using
//  the legacy `HTTPStubURLProtocol.register(_:)` array path and the
//  process-shared `URLSession.stubbedSession()` singleton. New tests
//  authored AFTER Wave 2 should subclass `HTTPStubTestCase` and call
//  `stubURL(_:status:body:)` for predicate-based stubbing.
//
//  Test-target-only.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

/// Base class for new tests using the predicate-based
/// `HTTPStubURLProtocol` API. Inherit from this rather than `XCTestCase`
/// directly so:
///
///  - `setUpWithError` clears any handler residue left by a prior test
///    that mis-tore-down (defensive — the post-test `XCTestObservation`
///    in `PalaceTestSetup` also fires `HTTPStubURLProtocol.removeAllHandlers`,
///    but pre-clearing on setUp closes the window where a test method
///    constructs its own session BEFORE its first observable transition).
///  - `tearDownWithError` asserts that the test removed every handler
///    it registered. A non-zero count on teardown means the test left
///    state that could pollute the next class — that's a real bug; we
///    fail loudly rather than silently swallowing.
///
/// Subclasses keep their own setUp/tearDown logic — they MUST call
/// `super` to inherit these guarantees.
class HTTPStubTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Defensive clear. The Wave 1 `PalaceSingletonResetObserver`
        // already fires `HTTPStubURLProtocol.removeAllHandlers` after
        // every test — this is belt-and-braces for the case where a
        // prior bundle (or this class's own first method) ran before
        // the observer was installed.
        HTTPStubURLProtocol.removeAllHandlers()
    }

    override func tearDownWithError() throws {
        // Snapshot the residual counts BEFORE we drain so a failing
        // assertion carries the leak count for diagnostics. The drain
        // itself is unconditional — even on assertion failure we leave
        // the next test starting from zero.
        let leakedLegacy = HTTPStubURLProtocol._registeredLegacyHandlerCount()
        let leakedPredicate = HTTPStubURLProtocol._registeredPredicateHandlerCount()
        HTTPStubURLProtocol.removeAllHandlers()

        XCTAssertEqual(
            leakedLegacy, 0,
            "HTTPStubTestCase: legacy handler list was non-empty at tearDown. " +
            "The test method registered \(leakedLegacy) handler(s) without calling " +
            "HTTPStubURLProtocol.removeAllHandlers — that state would leak into the " +
            "next test in the same class."
        )
        XCTAssertEqual(
            leakedPredicate, 0,
            "HTTPStubTestCase: predicate handler list was non-empty at tearDown. " +
            "The test method registered \(leakedPredicate) predicate handler(s) without " +
            "calling HTTPStubURLProtocol.removeAllHandlers — that state would leak into the " +
            "next test in the same class."
        )

        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Register a predicate-based handler that matches by URL absolute
    /// string prefix. Common case for tests that want to stub a few
    /// well-known URLs without re-implementing the URL-match boilerplate.
    ///
    /// - Parameters:
    ///   - pattern: The URL prefix to match. A request whose URL's
    ///     `absoluteString` starts with this pattern routes to the
    ///     supplied response.
    ///   - status: HTTP status code to return. Defaults to 200.
    ///   - body: Response body bytes. Defaults to empty `Data`.
    func stubURL(_ pattern: String, status: Int = 200, body: Data = Data()) {
        HTTPStubURLProtocol.registerHandler(
            matching: { url in url.absoluteString.hasPrefix(pattern) },
            response: HTTPStubURLProtocol.StubbedResponse(
                statusCode: status,
                headers: nil,
                body: body
            )
        )
    }
}

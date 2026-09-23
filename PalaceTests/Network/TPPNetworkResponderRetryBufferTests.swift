//
//  TPPNetworkResponderRetryBufferTests.swift
//  PalaceTests
//
//  PP-5065.
//

import XCTest
@testable import Palace

/// Pins that a token-refresh retry starts with an EMPTY response buffer.
///
/// PP-5065: `TPPNetworkResponder` accumulates each task's response body in
/// `TPPNetworkTaskInfo.progressData`. On a 401 it refreshes the token and remaps
/// the preserved completion onto the retry task via `updateCompletionId`, which
/// MOVES the whole info struct — carrying the 401's body with it. The retry's
/// bytes were then appended to the 401 problem document, and the caller was
/// handed the concatenation as `.success`.
///
/// Observed on device (Moes Max, 2026-09-02), body delivered to the OPDS parser:
///
///     {"type": ".../auth/recoverable/token/expired", "status": 401, ...}<feed xmlns=...>
///
/// which is not well-formed XML, so the feed failed to parse, the borrow failed
/// with "Invalid username or password", and Palace re-prompted for sign-in on a
/// perfectly valid session. Shipped since 3.2.x.
///
/// The completion handler must survive the move; the accumulated bytes must not.
@MainActor
final class TPPNetworkResponderRetryBufferTests: XCTestCase {

    private var responder: TPPNetworkResponder!
    private var session: URLSession!

    private let problemDocument = Data(#"{"type":"http://palaceproject.io/terms/problem/auth/recoverable/token/expired","title":"Access token expired","status":401}"#.utf8)
    private let feedXML = Data(#"<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Loans</title></feed>"#.utf8)

    override func setUp() {
        super.setUp()
        responder = TPPNetworkResponder(credentialsProvider: nil, useFallbackCaching: false)
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        responder = nil
        super.tearDown()
    }

    // MARK: - The invariant

    /// The defect, expressed directly: bytes accumulated on the 401 task must not
    /// be visible to the retry task. Asserted on the buffer rather than on a
    /// delivered result because the delivery path additionally requires a real
    /// `URLResponse`, which a non-resumed `URLSessionDataTask` does not carry —
    /// that seam is what kept this bug untested for four months.
    func testRetryTaskDoesNotInheritThe401Body() {
        let original = session.dataTask(with: URL(string: "https://minotaur.dev.palaceproject.io/icarus-test-library/loans/")!)
        let retry = session.dataTask(with: URL(string: "https://minotaur.dev.palaceproject.io/icarus-test-library/loans/")!)
        XCTAssertNotEqual(original.taskIdentifier, retry.taskIdentifier,
                          "precondition: the two tasks must have distinct identifiers")

        responder.addCompletion({ _ in }, taskID: original.taskIdentifier)

        // 1. the 401 body arrives on the original task
        responder.urlSession(session, dataTask: original, didReceive: problemDocument)
        waitForResponderQueue()
        XCTAssertEqual(responder.accumulatedBytesForTesting(taskID: original.taskIdentifier), problemDocument,
                       "precondition: the 401 body must actually be buffered, else this test proves nothing")

        // 2. token refresh succeeds; the completion is remapped onto the retry task
        responder.updateCompletionId(original.taskIdentifier, newId: retry.taskIdentifier)
        waitForResponderQueue()

        XCTAssertEqual(responder.accumulatedBytesForTesting(taskID: retry.taskIdentifier), Data(),
                       "the retry task must start with an EMPTY buffer — carrying the 401 body forward is PP-5065")
    }

    /// The symptom, stated as the property that actually broke: what the caller
    /// receives after a retry must be the retry's body verbatim, not a
    /// concatenation. This is the assertion that fails loudly if someone
    /// reintroduces the move-with-buffer.
    func testBodyAfterRetryIsTheRetryBodyVerbatim() {
        let original = session.dataTask(with: URL(string: "https://example.com/loans/")!)
        let retry = session.dataTask(with: URL(string: "https://example.com/loans/")!)

        responder.addCompletion({ _ in }, taskID: original.taskIdentifier)
        responder.urlSession(session, dataTask: original, didReceive: problemDocument)
        waitForResponderQueue()

        responder.updateCompletionId(original.taskIdentifier, newId: retry.taskIdentifier)
        responder.urlSession(session, dataTask: retry, didReceive: feedXML)
        waitForResponderQueue()

        let body = responder.accumulatedBytesForTesting(taskID: retry.taskIdentifier)
        XCTAssertEqual(body, feedXML,
                       "the accumulated body must be exactly the retry's bytes")
        XCTAssertFalse(body.map { $0.starts(with: problemDocument) } ?? false,
                       "the body must not be prefixed by the 401 problem document — that prefix is what breaks XML parsing")
    }

    /// A chunked retry response must still exclude the stale prefix: the reset
    /// happens once at remap time, not on every chunk (which would discard all
    /// but the last chunk of a large feed).
    func testChunkedRetryBodyAccumulatesFullyWithoutStalePrefix() {
        let original = session.dataTask(with: URL(string: "https://example.com/loans/")!)
        let retry = session.dataTask(with: URL(string: "https://example.com/loans/")!)

        responder.addCompletion({ _ in }, taskID: original.taskIdentifier)
        responder.urlSession(session, dataTask: original, didReceive: problemDocument)
        waitForResponderQueue()
        responder.updateCompletionId(original.taskIdentifier, newId: retry.taskIdentifier)

        let half = feedXML.count / 2
        responder.urlSession(session, dataTask: retry, didReceive: feedXML.prefix(half))
        responder.urlSession(session, dataTask: retry, didReceive: feedXML.suffix(from: half))
        waitForResponderQueue()

        XCTAssertEqual(responder.accumulatedBytesForTesting(taskID: retry.taskIdentifier), feedXML,
                       "both chunks must accumulate, and neither may carry the 401 prefix")
    }

    /// The move must still MOVE: the old id must not keep serving a completion,
    /// or the double-completion bug that `updateCompletionId` was written to fix
    /// (51107cbe8) comes back. Resetting the buffer must not weaken that.
    func testOldTaskIdIsVacatedByTheMove() {
        let original = session.dataTask(with: URL(string: "https://example.com/loans/")!)
        let retry = session.dataTask(with: URL(string: "https://example.com/loans/")!)

        responder.addCompletion({ _ in }, taskID: original.taskIdentifier)
        responder.urlSession(session, dataTask: original, didReceive: problemDocument)
        waitForResponderQueue()

        responder.updateCompletionId(original.taskIdentifier, newId: retry.taskIdentifier)
        waitForResponderQueue()

        XCTAssertNil(responder.accumulatedBytesForTesting(taskID: original.taskIdentifier),
                     "the old task id must hold no info at all after the move")
        XCTAssertNotNil(responder.accumulatedBytesForTesting(taskID: retry.taskIdentifier),
                        "the retry task id must hold the moved info")
    }

    /// A remap for an id that was never registered must be a silent no-op — a
    /// retry whose original completion already fired must not conjure an entry.
    func testRemapOfUnknownIdCreatesNothing() {
        let retry = session.dataTask(with: URL(string: "https://example.com/loans/")!)
        responder.updateCompletionId(987_654, newId: retry.taskIdentifier)
        waitForResponderQueue()

        XCTAssertNil(responder.accumulatedBytesForTesting(taskID: retry.taskIdentifier),
                     "remapping an unregistered id must not create an entry for the retry task")
    }

    // MARK: - Helpers

    /// `didReceive data:` dispatches async onto the responder's serial queue;
    /// the read seam is a `sync` on that same queue, so a no-op sync barrier
    /// after each drive is enough to order the assertions behind the writes.
    private func waitForResponderQueue() {
        _ = responder.accumulatedBytesForTesting(taskID: -1)
    }
}

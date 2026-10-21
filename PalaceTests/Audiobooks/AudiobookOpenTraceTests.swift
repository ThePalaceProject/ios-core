//
//  AudiobookOpenTraceTests.swift
//  PalaceTests
//
//  The open trace names the step a stalled open reached, and only for the
//  current open, so a superseded open is never reported (PP-4973).
//

import XCTest
@testable import Palace

final class AudiobookOpenTraceTests: XCTestCase {

    func testStall_afterAStep_namesTheBookOriginAndStep() {
        var trace = AudiobookOpenTrace()
        let id = trace.begin(bookId: "book-a", distributor: "Palace Marketplace", origin: .patron)
        _ = trace.enter(.loading, for: id)

        XCTAssertEqual(trace.stall(of: id),
                       AudiobookOpenStall(bookId: "book-a", distributor: "Palace Marketplace", origin: .patron, step: .loading))
    }

    func testEnter_returnsTheLogLineForTheCurrentOpen() {
        var trace = AudiobookOpenTrace()
        let id = trace.begin(bookId: "book-a", distributor: nil, origin: .reopen(.coldLoad))

        XCTAssertEqual(trace.enter(.checkingAccess, for: id),
                       "Audiobook open book-a (cold-load re-open): checking sign-in and content")
    }

    /// A newer open replaces the trace; the older open can neither move it nor
    /// be reported.
    func testSupersededOpen_isIgnored() {
        var trace = AudiobookOpenTrace()
        let first = trace.begin(bookId: "book-a", distributor: nil, origin: .patron)
        let second = trace.begin(bookId: "book-a", distributor: nil, origin: .reopen(.coldLoad))
        _ = trace.enter(.loading, for: second)

        XCTAssertNil(trace.enter(.checkingAccess, for: first))
        XCTAssertNil(trace.stall(of: first))
        XCTAssertEqual(trace.step, .loading)
        trace.finish(first)
        XCTAssertEqual(trace.stall(of: second)?.origin, .reopen(.coldLoad), "the older open's finish leaves the newer one")
    }

    func testFinishedOpen_isNotAStall() {
        var trace = AudiobookOpenTrace()
        let id = trace.begin(bookId: "book-a", distributor: nil, origin: .patron)
        _ = trace.enter(.loading, for: id)

        trace.finish(id)

        XCTAssertNil(trace.stall(of: id))
    }

    /// A content download shows its own progress and has its own bound.
    func testAwaitingContent_isNotAStall() {
        var trace = AudiobookOpenTrace()
        let id = trace.begin(bookId: "book-a", distributor: nil, origin: .patron)
        _ = trace.enter(.awaitingContent, for: id)

        XCTAssertNil(trace.stall(of: id))
    }

    // MARK: - The report
    //
    // A hung open leaves no crash report, so this event is the only count of
    // it. Nothing else would show a renamed key or a dropped send.

    @MainActor
    func testStallPayload_carriesExactlyTheOpenKeysAndTheStep() {
        let payload = AudiobookOpenMonitor.stallReportPayload(
            for: AudiobookOpenStall(bookId: "book-a",
                                    distributor: "Palace Marketplace",
                                    origin: .reopen(.coldLoad),
                                    step: .loading))

        XCTAssertEqual(payload.code, .audiobookOpenStalled)
        XCTAssertEqual(Set(payload.metadata.keys), ["bookId", "distributor", "origin", "step"])
        XCTAssertEqual(payload.metadata["bookId"] as? String, "book-a")
        XCTAssertEqual(payload.metadata["distributor"] as? String, "Palace Marketplace")
        XCTAssertEqual(payload.metadata["origin"] as? String, "cold-load re-open")
        XCTAssertEqual(payload.metadata["step"] as? String, AudiobookOpenStep.loading.rawValue)
        XCTAssertEqual(payload.summary,
                       "Audiobook open stalled: \(AudiobookOpenStep.loading.rawValue)",
                       "the summary groups the reports by step")
    }

    /// A book with no distributor still has to be countable, so the field is
    /// filled rather than dropped.
    @MainActor
    func testStallPayload_namesAnUnknownDistributor() {
        let payload = AudiobookOpenMonitor.stallReportPayload(
            for: AudiobookOpenStall(bookId: "book-a", distributor: nil, origin: .patron, step: .checkingAccess))

        XCTAssertEqual(payload.metadata["distributor"] as? String, "unknown")
        XCTAssertEqual(payload.metadata["step"] as? String, AudiobookOpenStep.checkingAccess.rawValue,
                       "the step must be the one reached, not a fixed value")
    }

    @MainActor
    func testRecord_sendsThePayloadOnce() {
        var sent: [(TPPErrorCode, String, [String: Any]?)] = []
        let stall = AudiobookOpenStall(bookId: "book-a", distributor: nil, origin: .patron, step: .loading)

        AudiobookOpenMonitor.record(stall) { sent.append(($0, $1, $2)) }

        XCTAssertEqual(sent.count, 1, "the stall report is the only count of a hung open")
        XCTAssertEqual(sent.first?.0, .audiobookOpenStalled)
        XCTAssertEqual(sent.first?.2?["step"] as? String, AudiobookOpenStep.loading.rawValue)
    }

    /// The deadline is the router's own lock release, read rather than copied:
    /// a shorter one reports opens the lock still allows to finish.
    func testStallDeadline_isTheRoutersOpenLockRelease() {
        XCTAssertEqual(AudiobookOpenTrace.stallDeadline, BookOpenRouter.openLockSafetyRelease)
    }
}

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
}

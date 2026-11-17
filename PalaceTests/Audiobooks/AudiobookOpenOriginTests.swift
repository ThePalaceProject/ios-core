//
//  AudiobookOpenOriginTests.swift
//  PalaceTests
//
//  Which opens the session admits, and what each origin means for the
//  recovery bounds, the loader and the content gate (PP-4973).
//

import XCTest
@testable import Palace

final class AudiobookOpenOriginTests: XCTestCase {

    private let book = "book-a"
    private let reopens: [AudiobookOpenOrigin] = [.reopen(.coldLoad), .reopen(.freshManifest), .reopen(.recovery)]

    /// Every state × origin cell. Only a patron open of the book already
    /// loading is refused; a re-open of that book is how a recovery proceeds.
    func testAdmitsOpen_overEveryStateAndOrigin() {
        let states: [(AudiobookSessionState, patronAdmitted: Bool)] = [
            (.idle, true),
            (.loading(bookId: book), false),
            (.loading(bookId: "book-b"), true),
            (.playing(bookId: book), true),
            (.paused(bookId: book), true),
            (.error(bookId: book, message: "Playback failed"), true),
        ]
        for (state, patronAdmitted) in states {
            XCTAssertEqual(AudiobookOpenOrigin.patron.admitsOpen(of: book, whileIn: state), patronAdmitted,
                           "patron open in \(state)")
            for origin in reopens {
                XCTAssertTrue(origin.admitsOpen(of: book, whileIn: state), "\(origin) in \(state)")
            }
        }
    }

    /// Only a patron open re-arms the recovery bounds; a re-open that did
    /// could let a failing book recover without end.
    func testIsPatron_onlyForPatronOpens() {
        XCTAssertTrue(AudiobookOpenOrigin.patron.isPatron)
        for origin in reopens {
            XCTAssertFalse(origin.isPatron, "\(origin)")
        }
    }

    /// Only the fresh-manifest re-open bypasses the manifest on disk.
    func testFetchesFreshManifest_onlyForFreshManifestReopen() {
        XCTAssertEqual(([AudiobookOpenOrigin.patron] + reopens).map(\.fetchesFreshManifest),
                       [false, false, true, false])
    }

    /// Only the cold-load re-open skips the upfront content gate.
    func testSkipsContentGate_onlyForColdLoadReopen() {
        XCTAssertEqual(([AudiobookOpenOrigin.patron] + reopens).map(\.skipsContentGate),
                       [false, true, false, false])
    }
}

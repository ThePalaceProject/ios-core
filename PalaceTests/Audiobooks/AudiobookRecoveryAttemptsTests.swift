//
//  AudiobookRecoveryAttemptsTests.swift
//  PalaceTests
//
//  The per-book bounds on the automatic playback recoveries, as a transition
//  table. Every (state, event) cell for the OverDrive re-fulfilment is asserted,
//  plus the re-arm rules for the bearer-token and cold-load bounds (PP-4967).
//
//  OverDrive re-fulfilment states: available, inFlight, spent.
//  Events: begin, finish, patron open. An automatic re-open is not an event on
//  the bounds at all; `isPatronOpen` decides which opens reach `notePatronOpen`.
//

import XCTest
@testable import Palace

final class AudiobookRecoveryAttemptsTests: XCTestCase {

    private let book = "urn:book:1"
    private let other = "urn:book:2"

    private func attempts(in state: AudiobookRecoveryAttempts.OverdriveRefulfill) -> AudiobookRecoveryAttempts {
        var attempts = AudiobookRecoveryAttempts()
        switch state {
        case .available:
            break
        case .inFlight:
            attempts.beginOverdriveRefulfill(for: book)
        case .spent:
            attempts.beginOverdriveRefulfill(for: book)
            attempts.finishOverdriveRefulfill(for: book)
        }
        XCTAssertEqual(attempts.overdriveRefulfill(for: book), state, "arrange")
        return attempts
    }

    // MARK: - available

    func testAvailable_begin_isInFlight() {
        var a = attempts(in: .available)
        a.beginOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .inFlight)
    }

    func testAvailable_finish_staysAvailable() {
        var a = attempts(in: .available)
        a.finishOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available,
            "finishing a re-fulfilment that never began must not spend the attempt")
    }

    func testAvailable_patronOpen_staysAvailable() {
        var a = attempts(in: .available)
        a.notePatronOpen(of: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available)
    }

    // MARK: - inFlight

    func testInFlight_begin_staysInFlight() {
        var a = attempts(in: .inFlight)
        a.beginOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .inFlight)
    }

    func testInFlight_finish_isSpent() {
        var a = attempts(in: .inFlight)
        a.finishOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .spent)
    }

    func testInFlight_patronOpen_isAvailable() {
        var a = attempts(in: .inFlight)
        a.notePatronOpen(of: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available)
    }

    // MARK: - spent

    func testSpent_begin_staysSpent() {
        var a = attempts(in: .spent)
        a.beginOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .spent,
            "the bound is one re-fulfilment per patron open; a second begin must not re-enter flight")
    }

    func testSpent_finish_staysSpent() {
        var a = attempts(in: .spent)
        a.finishOverdriveRefulfill(for: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .spent)
    }

    func testSpent_patronOpen_isAvailable() {
        var a = attempts(in: .spent)
        a.notePatronOpen(of: book)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available,
            "a patron tapping the book again is a new attempt and may re-fulfil once more")
    }

    // MARK: - Book isolation

    func testPatronOpenOfAnotherBook_doesNotReArmThisBook() {
        var a = attempts(in: .spent)
        a.notePatronOpen(of: other)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .spent)
    }

    func testBeginForAnotherBook_leavesThisBookAvailable() {
        var a = attempts(in: .available)
        a.beginOverdriveRefulfill(for: other)
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available)
        XCTAssertEqual(a.overdriveRefulfill(for: other), .inFlight)
    }

    // MARK: - Bearer-token and cold-load bounds

    func testBearerToken_recorded_thenPatronOpen_isReArmed() {
        var a = AudiobookRecoveryAttempts()
        a.recordBearerTokenRefulfill(for: book)
        XCTAssertTrue(a.hasAttemptedBearerTokenRefulfill(for: book))
        a.notePatronOpen(of: book)
        XCTAssertFalse(a.hasAttemptedBearerTokenRefulfill(for: book))
    }

    func testColdLoad_recorded_thenPatronOpen_isReArmed() {
        var a = AudiobookRecoveryAttempts()
        a.recordColdLoadReopen(for: book)
        XCTAssertTrue(a.hasAttemptedColdLoadReopen(for: book))
        a.notePatronOpen(of: book)
        XCTAssertFalse(a.hasAttemptedColdLoadReopen(for: book))
    }

    func testBounds_areIndependent() {
        var a = AudiobookRecoveryAttempts()
        a.recordBearerTokenRefulfill(for: book)
        XCTAssertFalse(a.hasAttemptedColdLoadReopen(for: book))
        XCTAssertEqual(a.overdriveRefulfill(for: book), .available)
    }

    // MARK: - Which opens re-arm the bounds

    /// Only a patron-initiated open re-arms. Each automatic re-open passes one
    /// of the three flags; a re-open that re-armed its own bound would let a
    /// persistently failing book loop (fail → recover → re-open → fail …).
    func testIsPatronOpen_overEveryFlagCombination() {
        for force in [false, true] {
            for coldLoad in [false, true] {
                for recovery in [false, true] {
                    let expected = !force && !coldLoad && !recovery
                    XCTAssertEqual(
                        AudiobookRecoveryAttempts.isPatronOpen(
                            forceRefulfill: force, isColdLoadRecovery: coldLoad, isRecoveryReopen: recovery),
                        expected,
                        "forceRefulfill=\(force) coldLoad=\(coldLoad) recoveryReopen=\(recovery)")
                }
            }
        }
    }
}

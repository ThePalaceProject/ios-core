//
//  ButtonTapDebounceTests.swift
//  PalaceTests
//
//  PP-5063.
//

import XCTest
@testable import Palace

/// Pins the debounce window that stops one press becoming several.
///
/// PP-5063: the book action buttons never debounced. Five quick taps on Borrow
/// started five borrows; three on Remove sent three returns. `isProcessing`
/// drove a spinner but never disabled the control, and it only flips *after*
/// the action is dispatched — so every press inside that window was delivered.
///
/// The decision is a pure function so the boundaries can be asserted directly.
/// A test that drove SwiftUI would exercise the framework, not this rule.
final class ButtonTapDebounceTests: XCTestCase {

    private let window = ButtonTapDebounce.window

    // MARK: - The rule

    func testFirstPressIsAlwaysAccepted() {
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: 0, lastAccepted: nil),
                      "with no previous press there is nothing to debounce against")
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: 12_345.678, lastAccepted: nil),
                      "the rule must not depend on the absolute clock value")
    }

    func testRepeatPressInsideTheWindowIsSwallowed() {
        let first = 100.0
        XCTAssertFalse(ButtonTapDebounce.shouldAccept(now: first + 0.05, lastAccepted: first),
                       "a 50ms repeat is the burst this exists to stop")
        XCTAssertFalse(ButtonTapDebounce.shouldAccept(now: first + window / 2, lastAccepted: first),
                       "half a window is still the same press as far as the patron is concerned")
    }

    func testPressAfterTheWindowIsAccepted() {
        let first = 100.0
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: first + window + 0.01, lastAccepted: first),
                      "a deliberate second press must still work — this must not make a button feel dead")
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: first + 5.0, lastAccepted: first),
                      "seconds later is unambiguously a new intent")
    }

    /// The boundary is inclusive: exactly one window later is a new press.
    /// Pinned because an off-by-one here either drops a real press or lets a
    /// burst through, and both failures look like flakiness rather than a bug.
    func testExactWindowBoundaryIsAccepted() {
        let first = 100.0
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: first + window, lastAccepted: first),
                      "at exactly one window the press is delivered")
    }

    // MARK: - Properties that must hold

    /// A five-tap burst must produce exactly one delivered action — this is the
    /// reported symptom ("five quick taps on Borrow put the patron inside the
    /// book"), expressed as a sequence rather than a single comparison.
    func testFiveTapBurstDeliversExactlyOnePress() {
        var lastAccepted: TimeInterval?
        var delivered = 0
        // five presses 80ms apart, the cadence an impatient patron produces
        for i in 0..<5 {
            let now = 100.0 + (Double(i) * 0.08)
            if ButtonTapDebounce.shouldAccept(now: now, lastAccepted: lastAccepted) {
                delivered += 1
                lastAccepted = now
            }
        }
        XCTAssertEqual(delivered, 1, "a five-tap burst inside the window must borrow once, not five times")
    }

    /// Held-down or very long bursts must not accumulate a backlog that fires
    /// later: each accepted press resets the window from the press that was
    /// actually delivered, not from the most recent attempt.
    func testWindowResetsFromTheDeliveredPressNotTheSuppressedOnes() {
        var lastAccepted: TimeInterval? = 100.0
        // suppressed attempts at +0.1 and +0.2 must not push the window out
        _ = ButtonTapDebounce.shouldAccept(now: 100.1, lastAccepted: lastAccepted)
        _ = ButtonTapDebounce.shouldAccept(now: 100.2, lastAccepted: lastAccepted)
        XCTAssertTrue(ButtonTapDebounce.shouldAccept(now: 100.0 + window, lastAccepted: lastAccepted),
                      "suppressed attempts must not extend the window; that would make a control progressively harder to press")
        lastAccepted = 100.0 + window
        XCTAssertFalse(ButtonTapDebounce.shouldAccept(now: 100.0 + window + 0.01, lastAccepted: lastAccepted),
                       "after a delivered press the window restarts from it")
    }

    /// The window has to be long enough to catch a real burst and short enough
    /// not to swallow intent. Asserted so a future tweak is a deliberate choice.
    func testWindowIsWithinAUsableRange() {
        XCTAssertGreaterThanOrEqual(window, 0.25, "shorter than 250ms and a genuine double-tap burst still gets through")
        XCTAssertLessThanOrEqual(window, 0.75, "longer than 750ms and a deliberate second press starts to feel ignored")
    }
}

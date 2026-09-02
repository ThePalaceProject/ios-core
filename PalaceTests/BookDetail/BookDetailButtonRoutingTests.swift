//
//  BookDetailButtonRoutingTests.swift
//  PalaceTests
//
//  PP-5059.
//

import XCTest
@testable import Palace

/// Pins which book-detail buttons open content.
///
/// PP-5059: `.read` and `.listen` sat in the same `switch` arm as the
/// half-sheet-local actions (`.retry` / `.cancel` / `.returning` / `.close`),
/// so tapping them only toggled `showHalfSheet`. On iPhone that was survivable
/// — the toggle presents the half-sheet, whose own Read/Listen calls
/// `handleAction`, so the book opened one tap later. On iPad `isFullSize` is
/// true, the half-sheet is not that path, and Read did nothing at all: no
/// reader, no error, no state change. It shipped that way and was found by
/// hand during the 3.3.0 release regression.
///
/// The switch already carried an exhaustiveness guard whose comment said it
/// stopped a button being "silently funneled into the half-sheet-toggle
/// fallback". It could not: exhaustiveness catches a *new* case, never an
/// existing case sitting in the *wrong* arm. That is the gap this test closes.
final class BookDetailButtonRoutingTests: XCTestCase {

    func testReadAndListenOpenContent() {
        XCTAssertTrue(BookDetailView.opensContentDirectly(.read),
                      "Read must open the reader, not toggle the half-sheet — on iPad there is no half-sheet, so a toggle is a no-op")
        XCTAssertTrue(BookDetailView.opensContentDirectly(.listen),
                      "Listen must open the player for the same reason")
    }

    func testHalfSheetLocalActionsDoNotOpenContent() {
        for button: BookButtonType in [.retry, .cancel, .returning, .close] {
            XCTAssertFalse(BookDetailView.opensContentDirectly(button),
                           "\(button) acts on the half-sheet itself and must not be routed to content presentation")
        }
    }

    /// The two sets must not overlap. Written as a set operation rather than
    /// case-by-case so the assertion is about the partition, which is the thing
    /// that was actually wrong — `.read` was in both roles at once.
    func testContentOpenersAndHalfSheetActionsAreDisjoint() {
        let contentOpeners: Set<String> = Set(
            ([.read, .listen] as [BookButtonType])
                .filter { BookDetailView.opensContentDirectly($0) }
                .map(String.init(describing:))
        )
        let halfSheetLocal: Set<String> = Set(
            ([.retry, .cancel, .returning, .close] as [BookButtonType])
                .filter { BookDetailView.opensContentDirectly($0) }
                .map(String.init(describing:))
        )
        XCTAssertEqual(contentOpeners.count, 2, "both .read and .listen must classify as content openers")
        XCTAssertTrue(halfSheetLocal.isEmpty,
                      "no half-sheet-local action may classify as a content opener; found \(halfSheetLocal)")
    }

    /// Acquisition and lifecycle buttons are routed by their own arms and must
    /// not be swept into content presentation.
    func testAcquisitionButtonsDoNotOpenContent() {
        for button: BookButtonType in [.download, .get, .reserve, .remove, .return,
                                       .sample, .audiobookSample, .cancelHold, .manageHold] {
            XCTAssertFalse(BookDetailView.opensContentDirectly(button),
                           "\(button) is an acquisition/lifecycle action, not a content-opening one")
        }
    }
}

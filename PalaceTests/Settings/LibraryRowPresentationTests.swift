//
//  LibraryRowPresentationTests.swift
//  PalaceTests
//
//  Covers the row model for the dedicated Libraries screen (PP-5098). The
//  screen's rows carry TWO independent tap targets — a selection control that
//  switches the active library and a row body that opens that library's own
//  settings — so the split between them, and the VoiceOver labels that make
//  the split perceivable, are the behavior worth pinning.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class LibraryRowPresentationTests: XCTestCase {

    private func makePresentation(
        name: String = "Palace Bookshelf",
        subtitle: String? = "Popular books free to download and keep.",
        isCurrent: Bool
    ) -> LibraryRowPresentation {
        LibraryRowPresentation(libraryName: name, subtitle: subtitle, isCurrentLibrary: isCurrent)
    }

    // MARK: - Selection control glyph

    /// The active library is the ONLY row that gets the filled checkmark. If
    /// this inverted, every inactive library would read as selected and the
    /// patron would have no way to see which library they are actually in.
    func test_selectionSymbol_isFilledCheckmarkOnlyForTheCurrentLibrary() {
        XCTAssertEqual(makePresentation(isCurrent: true).selectionSymbolName,
                       "checkmark.circle.fill")
        XCTAssertEqual(makePresentation(isCurrent: false).selectionSymbolName,
                       "circle")
    }

    // MARK: - Which control does what

    /// `isSelectionActionable` is what the view renders off — a live `Button`
    /// or an inert `Image` — so it has to agree with the table's
    /// selection-control column. Asserted separately from the table because a
    /// derivation that drifted would silently render a dead button.
    func test_selectionControl_isInertOnTheCurrentLibrary_andActionableOnEveryOther() {
        XCTAssertFalse(makePresentation(isCurrent: true).isSelectionActionable,
                       "Tapping the checkmark on the active library must not open a switch prompt.")
        XCTAssertTrue(makePresentation(isCurrent: false).isSelectionActionable,
                      "The empty circle is how a patron switches libraries.")
    }

    // MARK: - The full state × tap table

    /// Every reachable (library state, tap target) pair, asserted as a table
    /// rather than as scenarios. Two states × two tap targets is four cells and
    /// all four are here — the row used to have ONE target, so every cell in
    /// the right-hand column is new behavior with nothing to inherit from.
    ///
    /// The bottom-right cell is the deliberate change from the Settings-inline
    /// list: an INACTIVE row's body used to open the switch confirmation, and
    /// only the ACTIVE row navigated. Now the row body opens library details on
    /// both, and switching lives exclusively on the selection control.
    func test_tapOutcomeTable_coversEveryLibraryStateAndTapTarget() {
        let table: [(isCurrent: Bool, tap: LibraryRowTap, expected: LibraryRowOutcome)] = [
            (true,  .selectionControl, .none),
            (true,  .rowBody,          .openLibraryDetails),
            (false, .selectionControl, .confirmSwitch),
            (false, .rowBody,          .openLibraryDetails),
        ]

        for cell in table {
            let sut = makePresentation(isCurrent: cell.isCurrent)
            XCTAssertEqual(sut.outcome(of: cell.tap), cell.expected,
                           "isCurrentLibrary=\(cell.isCurrent), tap=\(cell.tap)")
        }
    }

    /// The cell most easily lost to a well-meaning "restore the old behavior"
    /// edit, called out on its own so a regression names itself.
    func test_inactiveRowBody_opensLibraryDetails_notTheSwitchConfirmation() {
        XCTAssertEqual(makePresentation(isCurrent: false).outcome(of: .rowBody),
                       .openLibraryDetails,
                       "Switching moved to the selection control; the row body navigates on every row.")
    }

    /// The selection control is the ONLY thing that switches libraries. If the
    /// row body could switch too, a patron opening a library's settings would
    /// be yanked to the Catalog tab instead.
    func test_noTapOnAnyRowSwitchesLibrariesExceptTheSelectionControl() {
        for isCurrent in [true, false] {
            XCTAssertNotEqual(makePresentation(isCurrent: isCurrent).outcome(of: .rowBody),
                              .confirmSwitch)
        }
    }

    // MARK: - Swipe-to-delete guard

    /// Removing the library you are currently reading in is not supported —
    /// the swipe action must not even be offered on that row.
    func test_swipeToDelete_isOfferedOnlyOnLibrariesThePatronIsNotIn() {
        XCTAssertFalse(makePresentation(isCurrent: true).allowsDelete)
        XCTAssertTrue(makePresentation(isCurrent: false).allowsDelete)
    }

    // MARK: - VoiceOver

    /// The selection control is a separate accessibility element from the row,
    /// so it must say what it IS (on the active library) or what it DOES (on
    /// every other one). "Palace Bookshelf" alone on both would leave a
    /// VoiceOver patron unable to tell the active library from the rest.
    func test_selectionAccessibilityLabel_announcesSelectionOnCurrent_andTheSwitchActionOnOthers() {
        let current = makePresentation(name: "Palace Bookshelf", isCurrent: true)
        XCTAssertTrue(current.selectionAccessibilityLabel.contains("Palace Bookshelf"),
                      "Label must name the library it belongs to; rows are otherwise indistinguishable in the rotor.")
        XCTAssertTrue(current.selectionAccessibilityLabel.contains(Strings.Generic.selected),
                      "The active library's control must announce that it is the selected one.")

        let other = makePresentation(name: "Main Street City Library", isCurrent: false)
        XCTAssertTrue(other.selectionAccessibilityLabel.contains("Main Street City Library"))
        XCTAssertFalse(other.selectionAccessibilityLabel.contains(Strings.Generic.selected),
                       "An inactive library must not announce itself as selected.")
        XCTAssertNotEqual(other.selectionAccessibilityLabel, current.selectionAccessibilityLabel)
    }

    /// The row body's label carries the library's identity — name plus the
    /// description shown underneath it — so a VoiceOver patron gets the same
    /// information a sighted one reads off the row.
    func test_rowAccessibilityLabel_carriesNameAndSubtitle() {
        let row = makePresentation(name: "Main Street City Library",
                                   subtitle: "serving Lyrasis Town, USA",
                                   isCurrent: false)

        XCTAssertTrue(row.rowAccessibilityLabel.contains("Main Street City Library"))
        XCTAssertTrue(row.rowAccessibilityLabel.contains("serving Lyrasis Town, USA"))
    }

    /// A library with no description must not have an empty fragment (a
    /// stray ". ") read out after its name.
    func test_rowAccessibilityLabel_isJustTheName_whenThereIsNoSubtitle() {
        XCTAssertEqual(makePresentation(name: "Alpha Library", subtitle: nil, isCurrent: false)
                        .rowAccessibilityLabel, "Alpha Library")
        XCTAssertEqual(makePresentation(name: "Alpha Library", subtitle: "", isCurrent: false)
                        .rowAccessibilityLabel, "Alpha Library",
                       "An empty-string subtitle is the same as none — the server sends both.")
    }

    /// Selection now lives on its own element. If the row body ALSO announced
    /// it, VoiceOver would say "Selected" twice while moving through one
    /// library — the regression you get by pasting the old combined label in.
    func test_rowAccessibilityLabel_doesNotRepeatTheSelectionState() {
        let current = makePresentation(name: "Palace Bookshelf", isCurrent: true)
        XCTAssertFalse(current.rowAccessibilityLabel.contains(Strings.Generic.selected),
                       "Selection is announced by the selection control, not the row body.")
        XCTAssertEqual(current.rowAccessibilityLabel,
                       makePresentation(name: "Palace Bookshelf", isCurrent: false).rowAccessibilityLabel,
                       "The row body reads identically whether or not the library is the active one.")
    }
}

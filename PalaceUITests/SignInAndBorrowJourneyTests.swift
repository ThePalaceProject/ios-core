//
//  SignInAndBorrowJourneyTests.swift
//  PalaceUITests
//
//  A patron signs in with a library card and borrows one book. Runs against
//  the `journey_sign_in_and_borrow` fixture scenario, so it covers the app's
//  own sign-in, borrow and shelf wiring, not a real circulation manager or any
//  external identity provider.
//

import XCTest

final class SignInAndBorrowJourneyTests: JourneyTestCase {

    /// Signed-in state shows in Settings, and one borrow puts exactly that
    /// book, and nothing else, on the patron's shelf.
    func testSignInThenBorrow_PutsExactlyOneBookOnTheShelf() {
        launch(scenario: FixtureLibrary.scenario, resetState: true)

        step("Catalog lists the fixture library's book") {
            waitFor(app.buttons[AccessibilityID.BookList.cell(FixtureLibrary.bookID)],
                    "the catalog never showed \(FixtureLibrary.bookTitle)")
        }

        step("Shelf starts empty") {
            openTab(AccessibilityID.TabBar.myBooksTab)
            waitFor(app.descendants(matching: .any)[AccessibilityID.MyBooks.emptyStateView],
                    "My Books is not empty on a clean launch")
        }

        signInWithLibraryCard()
        borrowFixtureBookFromDetailPage()

        step("The shelf holds exactly the borrowed book") {
            openTab(AccessibilityID.TabBar.myBooksTab)
            let shelf = app.descendants(matching: .any)[AccessibilityID.MyBooks.gridView]
            waitFor(shelf, "My Books shows no shelf after the borrow")
            let rows = shelf.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                          AccessibilityID.BookList.cellPrefix))
            waitUntil(NSPredicate(format: "count == 1"), on: rows, "the shelf does not hold exactly one book")
            XCTAssertEqual(rows.firstMatch.identifier, AccessibilityID.BookList.cell(FixtureLibrary.bookID))
            XCTAssertTrue(rows.firstMatch.label.contains(FixtureLibrary.bookTitle),
                          "the shelf row is labelled '\(rows.firstMatch.label)'")
        }
    }
}

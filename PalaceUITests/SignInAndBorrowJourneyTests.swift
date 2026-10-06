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

    private let libraryID = "urn:uuid:7f1d8a52-3b0e-4c86-9a5e-1f2a3b4c5d6e"
    private let libraryName = "Fixture Public Library"
    private let bookID = "urn:palace-fixtures:book:quiet-harbors"
    private let bookTitle = "A Field Guide to Quiet Harbors"

    /// Signed-in state shows in Settings, and one borrow puts exactly that
    /// book, and nothing else, on the patron's shelf.
    func testSignInThenBorrow_PutsExactlyOneBookOnTheShelf() {
        launch(scenario: "journey_sign_in_and_borrow", resetState: true)

        step("Catalog lists the fixture library's book") {
            waitFor(app.buttons[AccessibilityID.BookList.cell(bookID)],
                    "the catalog never showed \(bookTitle)")
        }

        step("Shelf starts empty") {
            openTab(AccessibilityID.TabBar.myBooksTab)
            waitFor(app.descendants(matching: .any)[AccessibilityID.MyBooks.emptyStateView],
                    "My Books is not empty on a clean launch")
        }

        step("Sign in with a library card") {
            openTab(AccessibilityID.TabBar.settingsTab)
            waitFor(app.descendants(matching: .any)[AccessibilityID.Settings.manageLibrariesButton],
                    "Settings has no Libraries row").tap()
            waitFor(app.descendants(matching: .any)["\(AccessibilityID.Libraries.row).\(libraryID)"],
                    "the fixture library is not in the Libraries list")
            app.staticTexts[libraryName].firstMatch.tap()

            let barcode = waitFor(app.textFields[AccessibilityID.SignIn.barcodeField], "no barcode field")
            barcode.tap()
            barcode.typeText("23333000000001")
            let pin = app.secureTextFields[AccessibilityID.SignIn.pinField]
            waitFor(pin, "no PIN field").tap()
            pin.typeText("1234")
            app.buttons[AccessibilityID.SignIn.signInButton].tap()
        }

        step("Settings shows the patron as signed in") {
            let signInButton = app.buttons[AccessibilityID.SignIn.signInButton]
            waitUntil(NSPredicate(format: "label == %@", "Sign out"), on: signInButton,
                      "the account never reached the signed-in state")
            XCTAssertFalse(app.textFields[AccessibilityID.SignIn.barcodeField].isEnabled,
                           "a signed-in account locks the barcode field")
        }

        step("Borrow the book from its detail page") {
            openTab(AccessibilityID.TabBar.catalogTab)
            // The row's centre holds its Get button; the title opens the detail page.
            let row = waitFor(app.buttons[AccessibilityID.BookList.cell(bookID)], "the catalog lost the book")
            row.staticTexts[bookTitle].tap()
            waitFor(app.staticTexts[AccessibilityID.BookDetail.title], "the book detail page did not open")
            XCTAssertEqual(app.staticTexts[AccessibilityID.BookDetail.title].label, bookTitle)
            // The catalog row underneath has its own Get button; tap the one on screen.
            let get = app.buttons.matching(identifier: AccessibilityID.BookDetail.getButton)
            waitFor(get.firstMatch, "the book offers no Get button")
            hittable(get, "the detail page's Get button is not on screen").tap()
            waitFor(app.buttons[AccessibilityID.BookDetail.readButton],
                    "the borrowed book never became readable", timeout: 60)
        }

        step("The loan sheet confirms the borrow") {
            waitFor(sheetText("Borrowed until"), "no loan confirmation after the borrow")
            XCTAssertTrue(sheetText(bookTitle).exists, "the loan sheet names a different book")
            let sheetTitle = sheetText(bookTitle).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            sheetTitle.press(forDuration: 0.1,
                             thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            waitUntil(NSPredicate(format: "exists == false"), on: sheetText("Borrowed until"),
                      "the loan sheet did not dismiss")
        }

        step("The shelf holds exactly the borrowed book") {
            openTab(AccessibilityID.TabBar.myBooksTab)
            let shelf = app.descendants(matching: .any)[AccessibilityID.MyBooks.gridView]
            waitFor(shelf, "My Books shows no shelf after the borrow")
            let rows = shelf.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                          AccessibilityID.BookList.cellPrefix))
            waitUntil(NSPredicate(format: "count == 1"), on: rows, "the shelf does not hold exactly one book")
            XCTAssertEqual(rows.firstMatch.identifier, AccessibilityID.BookList.cell(bookID))
            XCTAssertTrue(rows.firstMatch.label.contains(bookTitle),
                          "the shelf row is labelled '\(rows.firstMatch.label)'")
        }
    }

    /// The loan sheet's elements carry its identifier themselves.
    private func sheetText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                             AccessibilityID.BookDetail.halfSheet, label)).firstMatch
    }
}

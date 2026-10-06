//
//  FixtureLibrarySteps.swift
//  PalaceUITests
//
//  The fixture library from `journey_sign_in_and_borrow` and the steps that
//  several journeys share: signing in and borrowing its one book.
//

import XCTest

enum FixtureLibrary {
    static let scenario = "journey_sign_in_and_borrow"
    static let libraryID = "urn:uuid:7f1d8a52-3b0e-4c86-9a5e-1f2a3b4c5d6e"
    static let libraryName = "Fixture Public Library"
    static let bookID = "urn:palace-fixtures:book:quiet-harbors"
    static let bookTitle = "A Field Guide to Quiet Harbors"
    static let barcode = "23333000000001"
    static let pin = "1234"
}

extension JourneyTestCase {

    /// Signs in from Settings and waits until the account shows as signed in.
    func signInWithLibraryCard() {
        step("Sign in with a library card") {
            openTab(AccessibilityID.TabBar.settingsTab)
            waitFor(app.descendants(matching: .any)[AccessibilityID.Settings.manageLibrariesButton],
                    "Settings has no Libraries row").tap()
            waitFor(app.descendants(matching: .any)["\(AccessibilityID.Libraries.row).\(FixtureLibrary.libraryID)"],
                    "the fixture library is not in the Libraries list")
            app.staticTexts[FixtureLibrary.libraryName].firstMatch.tap()

            let barcode = waitFor(app.textFields[AccessibilityID.SignIn.barcodeField], "no barcode field")
            barcode.tap()
            barcode.typeText(FixtureLibrary.barcode)
            let pin = app.secureTextFields[AccessibilityID.SignIn.pinField]
            waitFor(pin, "no PIN field").tap()
            pin.typeText(FixtureLibrary.pin)
            app.buttons[AccessibilityID.SignIn.signInButton].tap()
        }

        step("Settings shows the patron as signed in") {
            let signInButton = app.buttons[AccessibilityID.SignIn.signInButton]
            waitUntil(NSPredicate(format: "label == %@", "Sign out"), on: signInButton,
                      "the account never reached the signed-in state")
            XCTAssertFalse(app.textFields[AccessibilityID.SignIn.barcodeField].isEnabled,
                           "a signed-in account locks the barcode field")
        }
    }

    /// Borrows the book from its detail page, checks the loan sheet, and dismisses it.
    func borrowFixtureBookFromDetailPage() {
        step("Borrow the book from its detail page") {
            openTab(AccessibilityID.TabBar.catalogTab)
            // The row's centre holds its Get button; the title opens the detail page.
            let row = waitFor(app.buttons[AccessibilityID.BookList.cell(FixtureLibrary.bookID)],
                              "the catalog does not list the book")
            row.staticTexts[FixtureLibrary.bookTitle].tap()
            waitFor(app.staticTexts[AccessibilityID.BookDetail.title], "the book detail page did not open")
            XCTAssertEqual(app.staticTexts[AccessibilityID.BookDetail.title].label, FixtureLibrary.bookTitle)
            // The catalog row underneath has its own Get button; tap the one on screen.
            let get = app.buttons.matching(identifier: AccessibilityID.BookDetail.getButton)
            waitFor(get.firstMatch, "the book offers no Get button")
            hittable(get, "the detail page's Get button is not on screen").tap()
            waitFor(app.buttons[AccessibilityID.BookDetail.readButton],
                    "the borrowed book never became readable", timeout: 60)
        }

        step("The loan sheet confirms the borrow") {
            waitFor(loanSheetText("Borrowed until"), "no loan confirmation after the borrow")
            XCTAssertTrue(loanSheetText(FixtureLibrary.bookTitle).exists, "the loan sheet names a different book")
            let title = loanSheetText(FixtureLibrary.bookTitle).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            title.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            waitUntil(NSPredicate(format: "exists == false"), on: loanSheetText("Borrowed until"),
                      "the loan sheet did not dismiss")
        }
    }

    /// The loan sheet's elements carry its identifier themselves.
    private func loanSheetText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                             AccessibilityID.BookDetail.halfSheet, label)).firstMatch
    }
}

//
//  ResumeReadingJourneyTests.swift
//  PalaceUITests
//
//  A patron reads to a later chapter, the app is terminated, and reopening the
//  book resumes where they left off. Uses the open-licence EPUB from the
//  `journey_sign_in_and_borrow` fixtures, so it runs on either app target.
//

import XCTest

final class ResumeReadingJourneyTests: JourneyTestCase {

    private let firstChapter = "Chapter One: The Breakwater"
    private let lastChapter = "Chapter Three: The Slipway"

    /// The reading position survives a relaunch: the reader reopens on the
    /// chapter the patron left, not at the start of the book.
    func testReadingPosition_SurvivesRelaunch() {
        launch(scenario: FixtureLibrary.scenario, resetState: true)
        signInWithLibraryCard()
        borrowFixtureBookFromDetailPage()

        step("Open the book and jump to the last chapter") {
            openBookFromShelf()
            openTableOfContents()
            waitFor(app.staticTexts[lastChapter], "the table of contents does not list \(lastChapter)").tap()
            waitForPage(showing: lastChapter, "the reader did not move to \(lastChapter)")
        }

        step("Close the book") {
            // Closing the reader stores the position; terminating straight from
            // the reader could race the asynchronous registry write.
            revealReaderChrome()
            waitFor(app.buttons["Go back"], "the reader has no back button").tap()
            waitFor(app.descendants(matching: .any)[AccessibilityID.MyBooks.gridView], "closing the book did not return to My Books")
        }

        step("Relaunch the app without resetting it") {
            app.terminate()
            launch(scenario: FixtureLibrary.scenario, resetState: false)
        }

        step("Reopening the book resumes in the last chapter") {
            openBookFromShelf()
            waitForPage(showing: lastChapter, "the reader reopened somewhere other than \(lastChapter)")
        }
    }

    // MARK: - Reader

    private func openBookFromShelf() {
        openTab(AccessibilityID.TabBar.myBooksTab)
        let shelf = waitFor(app.descendants(matching: .any)[AccessibilityID.MyBooks.gridView], "My Books shows no shelf")
        let read = shelf.buttons.matching(identifier: AccessibilityID.BookDetail.readButton).firstMatch
        waitFor(read, "the shelf offers no Read button").tap()
    }

    /// Waits until the reader has `chapter`'s heading loaded and checks the
    /// opening chapter is not: Readium preloads neighbours, so the heading
    /// alone does not prove which chapter is on screen.
    private func waitForPage(showing chapter: String, _ message: String) {
        let heading = app.webViews.staticTexts[chapter].firstMatch
        waitFor(heading, message)
        XCTAssertFalse(app.webViews.staticTexts[firstChapter].exists,
                       "the reader still shows \(firstChapter)")
    }

    private func openTableOfContents() {
        revealReaderChrome()
        waitFor(app.buttons["Table of contents"], "the reader has no table of contents button").tap()
    }

    /// The reader hides its chrome while reading; a tap in the middle shows it.
    private func revealReaderChrome() {
        if !app.buttons["Table of contents"].isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}

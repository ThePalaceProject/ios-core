//
//  AudiobookCloseMidLoadJourneyTests.swift
//  PalaceUITests
//
//  A patron opens an audiobook and closes the player while it is still loading
//  (PP-5302). The `journey_audiobook_close_mid_load` scenario holds the first
//  open's bearer-token fulfil request, so the close always lands mid-load.
//

import XCTest

private enum FixtureAudiobook {
    static let scenario = "journey_audiobook_close_mid_load"
    static let bookID = "urn:palace-fixtures:book:still-water"
    static let title = "Still Water"
    /// The scenario holds the first open's fulfil request this long.
    static let holdSeconds: TimeInterval = 15
}

final class AudiobookCloseMidLoadJourneyTests: JourneyTestCase {

    /// Closing the player mid-load returns the patron to a usable shelf with
    /// no spinner or error left behind, also after a second open. In Debug,
    /// `openAudiobook`'s local `loader` outlives the await, so the released-loader
    /// exit is out of reach here; `AudiobookLoaderReleasedMidLoadTests` covers it.
    func testClosingThePlayerWhileItLoads_LeavesTheBookReadyToOpenAgain() {
        // The loading shell and its close button belong to the in-app player.
        // The override is read `as? Bool`, so it must arrive as a plist boolean,
        // not the string "YES"; without it the remote config decides.
        launch(scenario: FixtureAudiobook.scenario, resetState: true,
               arguments: ["-RemoteFeatureFlags.inAppPlaybackNavLocalOverride", "<true/>"])
        signInWithLibraryCard()
        borrowAudiobookFromDetailPage()

        step("Open the audiobook from My Books; it is still loading") {
            openTab(AccessibilityID.TabBar.myBooksTab)
            waitUntil(NSPredicate(format: "enabled == true"), on: listenButton(), "the shelf's Listen button is not ready")
            listenButton().tap()
            waitFor(app.descendants(matching: .any)[playerLoadingLabel], "the player never showed its loading state")
        }

        step("Close the player while it loads") {
            let close = app.buttons["Close"].firstMatch
            waitFor(close, "the loading player offers no Close button").tap()
            // Well inside the hold, so the player can only have gone because of the close.
            waitUntil(NSPredicate(format: "exists == false"), on: app.descendants(matching: .any)[playerLoadingLabel],
                      "Close did not dismiss the loading player", timeout: 5)
        }

        step("My Books is usable again, with no spinner or error") {
            let listen = listenButton()
            waitUntil(NSPredicate(format: "enabled == true"), on: listen,
                      "the Listen button stayed busy after the player closed",
                      timeout: FixtureAudiobook.holdSeconds + Self.defaultTimeout)
            XCTAssertEqual(listen.activityIndicators.count, 0, "the Listen button still shows a spinner")
            XCTAssertFalse(app.descendants(matching: .any)[playerLoadingLabel].exists, "the player's loading state is still on screen")
            assertNoLoadErrorShown()
        }

        // This step shows the shelf stays usable with no error after a second
        // open; it cannot tell a finished load from a quietly cancelled one.
        // AudiobookSessionManagerStopDuringLoadTests covers those late results.
        step("Opening the book again leaves a usable shelf with no error") {
            listenButton().tap()
            // The scenario holds this open briefly too, so the loading player is
            // reliably on screen and proves the tap started an open.
            let loading = app.descendants(matching: .any)[playerLoadingLabel]
            waitFor(loading, "the second open never showed the loading player")
            waitUntil(NSPredicate(format: "exists == false"), on: loading, "the second open's loading player never cleared")
            dismissAudiobookUnavailableAlerts()
            waitUntil(NSPredicate(format: "enabled == true"), on: listenButton(), "the Listen button stayed busy after the second open")
            XCTAssertEqual(listenButton().activityIndicators.count, 0, "the Listen button still shows a spinner")
            assertNoLoadErrorShown()
        }
    }

    // MARK: - Steps

    private let playerLoadingLabel = "Loading…"

    /// The shelf row's Listen button. The open starts here rather than on the
    /// detail page, which in the DRM build first activates Adobe DRM and stops
    /// when the fixture library cannot.
    private func listenButton() -> XCUIElement {
        let shelf = waitFor(app.descendants(matching: .any)[AccessibilityID.MyBooks.gridView], "My Books shows no shelf")
        let listen = shelf.buttons.matching(identifier: AccessibilityID.BookDetail.listenButton).firstMatch
        return waitFor(listen, "the shelf offers no Listen button")
    }

    /// Test artefact, not the behaviour under test: AVPlayer cannot fetch the
    /// fixture audio, so the bound player fails. That ends in zero or more
    /// "Audiobook Unavailable" alerts, depending on whether AVPlayer reported
    /// playing first; only that alert is dismissed here.
    private func dismissAudiobookUnavailableAlerts() {
        let unavailable = app.alerts["Audiobook Unavailable"]
        var dismissed = 0
        while dismissed < 5, unavailable.waitForExistence(timeout: 3) {
            unavailable.buttons["OK"].tap()
            dismissed += 1
            // A queued copy can replace it at once, so this wait may time out.
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                                 object: unavailable)], timeout: 2)
        }
        XCTAssertFalse(unavailable.exists, "the Audiobook Unavailable alert kept coming back")
    }

    private func assertNoLoadErrorShown() {
        XCTAssertEqual(app.alerts.count, 0, "an alert is on screen: \(app.alerts.firstMatch.label)")
        for text in ["Load cancelled", "Playback failed"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists,
                           "the screen reports '\(text)'")
        }
    }

    private func borrowAudiobookFromDetailPage() {
        step("Borrow the audiobook from its detail page") {
            openTab(AccessibilityID.TabBar.catalogTab)
            dismissSavePasswordPromptIfShown()
            let row = waitFor(app.buttons[AccessibilityID.BookList.cell(FixtureAudiobook.bookID)],
                              "the catalog does not list the audiobook")
            // An audiobook row reads its title as "Still Water. Audiobook."
            row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", FixtureAudiobook.title)).firstMatch.tap()
            waitFor(app.staticTexts[AccessibilityID.BookDetail.title], "the book detail page did not open")
            XCTAssertTrue(app.staticTexts[AccessibilityID.BookDetail.title].label.hasPrefix(FixtureAudiobook.title),
                          "the detail page shows '\(app.staticTexts[AccessibilityID.BookDetail.title].label)'")
            let get = app.buttons.matching(identifier: AccessibilityID.BookDetail.getButton)
            waitFor(get.firstMatch, "the audiobook offers no Get button")
            hittable(get, "the detail page's Get button is not on screen").tap()
            waitFor(app.buttons[AccessibilityID.BookDetail.listenButton],
                    "the borrowed audiobook never became listenable", timeout: 60)
        }

        step("Dismiss the loan sheet") {
            let borrowedUntil = loanSheetText("Borrowed until")
            waitFor(borrowedUntil, "no loan confirmation after the borrow")
            let title = loanSheetText(FixtureAudiobook.title).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            title.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            waitUntil(NSPredicate(format: "exists == false"), on: borrowedUntil, "the loan sheet did not dismiss")
        }
    }

    private func loanSheetText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                             AccessibilityID.BookDetail.halfSheet, label)).firstMatch
    }
}

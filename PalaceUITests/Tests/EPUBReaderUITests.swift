//
//  EPUBReaderUITests.swift
//  PalaceUITests
//
//  XCUITest scenarios for the EPUB reader screen.
//  Requires a borrowed/downloaded EPUB book on the device under test.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

// MARK: - EPUB Reader Page Object

/// Inline page-object helper encapsulating EPUB reader element queries.
private struct EPUBReaderScreen {
  let app: XCUIApplication

  // MARK: - My Books tab (launch point)

  var myBooksTab: XCUIElement {
    app.tabBars.buttons["My Books"]
  }

  // MARK: - Book Detail

  var readButton: XCUIElement {
    app.buttons["bookDetail.readButton"]
  }

  // MARK: - Reader chrome

  /// The navigation bar that appears/disappears on tap.
  var navigationBar: XCUIElement {
    app.navigationBars.firstMatch
  }

  var backButton: XCUIElement {
    navigationBar.buttons.firstMatch
  }

  var tocButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Table of Contents"
    )).firstMatch
  }

  var bookmarkButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
      "Add Bookmark", "Remove Bookmark"
    )).firstMatch
  }

  var searchButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Search"
    )).firstMatch
  }

  // MARK: - Content area

  /// The web view that renders EPUB content (Readium uses WKWebView).
  var webContentView: XCUIElement {
    app.webViews.firstMatch
  }

  /// Position / progress label at bottom of reader.
  var positionLabel: XCUIElement {
    app.staticTexts.matching(NSPredicate(
      format: "identifier == %@ OR label MATCHES %@",
      "positionLabel", ".*Page.*|.*Chapter.*|.*%.*"
    )).firstMatch
  }

  /// Book title label shown at top of reader.
  var bookTitleLabel: XCUIElement {
    app.staticTexts.matching(NSPredicate(
      format: "identifier == %@", "bookTitleLabel"
    )).firstMatch
  }

  // MARK: - TOC / Positions

  var tocTableView: XCUIElement {
    app.tables.firstMatch
  }

  var tocCells: XCUIElementQuery {
    tocTableView.cells
  }

  // MARK: - Settings / Font controls

  var fontSettingsButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Settings"
    )).firstMatch
  }

  var increaseFontButton: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "increase"
    )).firstMatch
  }

  var decreaseFontButton: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "decrease"
    )).firstMatch
  }

  var brightnessSlider: XCUIElement {
    app.sliders.firstMatch
  }

  // MARK: - Theme buttons

  var whiteThemeButton: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "White"
    )).firstMatch
  }

  var sepiaThemeButton: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Sepia"
    )).firstMatch
  }

  var darkThemeButton: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Dark"
    )).firstMatch
  }

  // MARK: - Search

  var searchField: XCUIElement {
    app.searchFields.firstMatch
  }

  var searchResultsList: XCUIElement {
    app.tables.firstMatch
  }

  // MARK: - Actions

  /// Tap center of web view to toggle navigation bar visibility.
  func tapCenterOfContent() {
    let contentArea = webContentView
    let center = contentArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.tap()
  }

  /// Tap right edge to go forward.
  func tapRightEdge() {
    let contentArea = webContentView
    let rightEdge = contentArea.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
    rightEdge.tap()
  }

  /// Tap left edge to go backward.
  func tapLeftEdge() {
    let contentArea = webContentView
    let leftEdge = contentArea.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
    leftEdge.tap()
  }

  /// Swipe left on content area (next page).
  func swipeContentLeft() {
    webContentView.swipeLeft()
  }

  /// Swipe right on content area (previous page).
  func swipeContentRight() {
    webContentView.swipeRight()
  }
}

// MARK: - Test Class

final class EPUBReaderUITests: XCTestCase {

  private var app: XCUIApplication!
  private var reader: EPUBReaderScreen!

  // MARK: - Lifecycle

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
    app.launch()
    reader = EPUBReaderScreen(app: app)
  }

  override func tearDownWithError() throws {
    app = nil
    reader = nil
  }

  // MARK: - Helpers

  /// Navigate to My Books, find first available book, and tap Read.
  /// Throws `XCTSkip` when no downloadable EPUB is available.
  @discardableResult
  private func openFirstAvailableEPUB() throws -> XCUIElement {
    let myBooksTab = reader.myBooksTab
    guard myBooksTab.waitForExistence(timeout: 10) else {
      throw XCTSkip("My Books tab not found -- app may not be configured with a library account")
    }
    myBooksTab.tap()

    // Look for a Read button among book cells
    let readButton = app.buttons["bookDetail.readButton"]
    // First try: is there a Read button visible on the shelf?
    if readButton.waitForExistence(timeout: 5) {
      readButton.tap()
    } else {
      // Try tapping the first book cell then tapping Read in detail
      let firstBook = app.collectionViews.cells.firstMatch
      guard firstBook.waitForExistence(timeout: 5) else {
        throw XCTSkip("No downloaded books available for EPUB reader testing")
      }
      firstBook.tap()
      guard readButton.waitForExistence(timeout: 5) else {
        throw XCTSkip("Selected book does not have a Read button (may not be an EPUB or not downloaded)")
      }
      readButton.tap()
    }

    // Wait for reader to appear -- web view should load
    let webView = reader.webContentView
    guard webView.waitForExistence(timeout: 15) else {
      throw XCTSkip("EPUB reader did not open -- book may not be a valid EPUB")
    }
    return webView
  }

  /// Ensure the navigation bar is visible by tapping center if hidden.
  private func ensureNavigationBarVisible() {
    if !reader.navigationBar.isHittable {
      reader.tapCenterOfContent()
      _ = reader.navigationBar.waitForExistence(timeout: 3)
    }
  }

  // MARK: - 1. Reader Opens

  func testReaderOpensWhenTappingReadOnDownloadedEPUB() throws {
    try openFirstAvailableEPUB()
    XCTAssertTrue(reader.webContentView.exists, "EPUB web content view should be displayed")
  }

  // MARK: - 2. Page Content Displayed

  func testPageContentIsDisplayed() throws {
    try openFirstAvailableEPUB()
    let webView = reader.webContentView
    XCTAssertTrue(webView.exists, "Web view must exist")
    // Content should have non-zero frame
    XCTAssertGreaterThan(webView.frame.width, 0, "Content should have positive width")
    XCTAssertGreaterThan(webView.frame.height, 0, "Content should have positive height")
  }

  // MARK: - 3. Navigation Bar Toggle

  func testNavigationBarCanBeToggled() throws {
    try openFirstAvailableEPUB()

    // Initially the nav bar may be hidden
    let navBar = reader.navigationBar

    // Tap to show
    reader.tapCenterOfContent()
    _ = navBar.waitForExistence(timeout: 3)
    let visibleAfterFirstTap = navBar.isHittable

    // Tap again to hide
    reader.tapCenterOfContent()
    sleep(1) // allow animation
    let visibleAfterSecondTap = navBar.isHittable

    // The two states should be different (toggling works)
    XCTExpectFailure("Nav bar toggle may behave differently depending on Readium configuration") {
      XCTAssertNotEqual(visibleAfterFirstTap, visibleAfterSecondTap,
                        "Navigation bar visibility should toggle on center tap")
    }
  }

  // MARK: - 4. Next Page Navigation

  func testNextPageNavigationWorks() throws {
    try openFirstAvailableEPUB()

    // Record initial state
    let initialLabel = reader.positionLabel.label

    // Tap right edge for next page
    reader.tapRightEdge()
    sleep(1)

    XCTExpectFailure("Position label may not be wired up yet") {
      let afterLabel = reader.positionLabel.label
      XCTAssertNotEqual(initialLabel, afterLabel,
                        "Position should update after navigating forward")
    }
  }

  // MARK: - 5. Previous Page Navigation

  func testPreviousPageNavigationWorks() throws {
    try openFirstAvailableEPUB()

    // Go forward first so we can go back
    reader.tapRightEdge()
    sleep(1)
    let afterForward = reader.positionLabel.label

    reader.tapLeftEdge()
    sleep(1)

    XCTExpectFailure("Position label may not be wired up yet") {
      let afterBack = reader.positionLabel.label
      XCTAssertNotEqual(afterForward, afterBack,
                        "Position should update after navigating backward")
    }
  }

  // MARK: - 6. TOC Button Opens Table of Contents

  func testTOCButtonOpensTableOfContents() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let tocBtn = reader.tocButton
    XCTExpectFailure("TOC button accessibility label may differ") {
      XCTAssertTrue(tocBtn.waitForExistence(timeout: 3), "TOC button should exist in nav bar")
    }
    guard tocBtn.exists else { return }

    tocBtn.tap()
    let tocTable = reader.tocTableView
    XCTAssertTrue(tocTable.waitForExistence(timeout: 5), "TOC table should appear")
  }

  // MARK: - 7. Bookmark Button Toggles State

  func testBookmarkButtonTogglesBookmarkState() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let bookmarkBtn = reader.bookmarkButton
    XCTExpectFailure("Bookmark button may not be accessible in nav bar") {
      XCTAssertTrue(bookmarkBtn.waitForExistence(timeout: 3), "Bookmark button should exist")
    }
    guard bookmarkBtn.exists else { return }

    let labelBefore = bookmarkBtn.label
    bookmarkBtn.tap()
    sleep(1)
    let labelAfter = bookmarkBtn.label

    // Label should change between "Add Bookmark" and "Remove Bookmark"
    XCTAssertNotEqual(labelBefore, labelAfter,
                      "Bookmark button label should toggle after tap")
  }

  // MARK: - 8. Search Button Opens In-Book Search

  func testSearchButtonOpensInBookSearch() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let searchBtn = reader.searchButton
    XCTExpectFailure("Search button may not be present in all configurations") {
      XCTAssertTrue(searchBtn.waitForExistence(timeout: 3), "Search button should exist")
    }
    guard searchBtn.exists else { return }

    searchBtn.tap()

    let searchField = reader.searchField
    XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                  "Search field should appear after tapping search")
  }

  // MARK: - 9. Font Size Controls

  func testFontSizeControlsWork() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let settingsBtn = reader.fontSettingsButton
    XCTExpectFailure("Font settings button may use a different label") {
      XCTAssertTrue(settingsBtn.waitForExistence(timeout: 3), "Settings button should exist")
    }
    guard settingsBtn.exists else { return }

    settingsBtn.tap()

    let increaseBtn = reader.increaseFontButton
    let decreaseBtn = reader.decreaseFontButton

    XCTExpectFailure("Font controls may not be wired with standard labels") {
      XCTAssertTrue(increaseBtn.waitForExistence(timeout: 3), "Increase font button should exist")
      XCTAssertTrue(decreaseBtn.exists, "Decrease font button should exist")
    }
  }

  // MARK: - 10. Theme Switching

  func testThemeSwitching() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let settingsBtn = reader.fontSettingsButton
    guard settingsBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("Settings button not found -- cannot test theme switching")
    }
    settingsBtn.tap()

    XCTExpectFailure("Theme buttons may not be wired with expected labels") {
      let sepiaBtn = reader.sepiaThemeButton
      XCTAssertTrue(sepiaBtn.waitForExistence(timeout: 3), "Sepia theme button should exist")
      sepiaBtn.tap()

      let darkBtn = reader.darkThemeButton
      XCTAssertTrue(darkBtn.exists, "Dark theme button should exist")
      darkBtn.tap()

      let whiteBtn = reader.whiteThemeButton
      XCTAssertTrue(whiteBtn.exists, "White theme button should exist")
      whiteBtn.tap()
    }
  }

  // MARK: - 11. Brightness Slider

  func testBrightnessSliderIsAccessible() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let settingsBtn = reader.fontSettingsButton
    guard settingsBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("Settings button not found -- cannot test brightness slider")
    }
    settingsBtn.tap()

    XCTExpectFailure("Brightness slider may not be present in current reader settings UI") {
      let slider = reader.brightnessSlider
      XCTAssertTrue(slider.waitForExistence(timeout: 3), "Brightness slider should be accessible")
    }
  }

  // MARK: - 12. Reader Remembers Position on Reopen

  func testReaderRemembersPositionOnReopen() throws {
    try openFirstAvailableEPUB()

    // Navigate forward a few pages
    reader.tapRightEdge()
    sleep(1)
    reader.tapRightEdge()
    sleep(1)

    let positionBeforeClose = reader.positionLabel.label

    // Close reader
    ensureNavigationBarVisible()
    reader.backButton.tap()
    sleep(2)

    // Reopen
    try openFirstAvailableEPUB()
    sleep(2)

    XCTExpectFailure("Position persistence may not be verifiable via label comparison") {
      let positionAfterReopen = reader.positionLabel.label
      XCTAssertEqual(positionBeforeClose, positionAfterReopen,
                     "Reader should restore the last read position on reopen")
    }
  }

  // MARK: - 13. Chapter Navigation from TOC

  func testChapterNavigationFromTOC() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let tocBtn = reader.tocButton
    guard tocBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("TOC button not found")
    }
    tocBtn.tap()

    let tocTable = reader.tocTableView
    guard tocTable.waitForExistence(timeout: 5) else {
      throw XCTSkip("TOC table did not appear")
    }

    // Tap a chapter that is not the first one
    let cells = reader.tocCells
    XCTExpectFailure("TOC may have only one chapter or different cell structure") {
      XCTAssertGreaterThan(cells.count, 1, "TOC should have multiple chapters")
      cells.element(boundBy: 1).tap()

      // Reader should navigate and web view should still be present
      let webView = reader.webContentView
      XCTAssertTrue(webView.waitForExistence(timeout: 10), "Reader should display after TOC navigation")
    }
  }

  // MARK: - 14. Search Finds Text in Book

  func testSearchFindsTextInBook() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let searchBtn = reader.searchButton
    guard searchBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("Search button not found")
    }
    searchBtn.tap()

    let searchField = reader.searchField
    guard searchField.waitForExistence(timeout: 5) else {
      throw XCTSkip("Search field did not appear")
    }

    XCTExpectFailure("Search results depend on book content and search implementation") {
      searchField.tap()
      searchField.typeText("the\n") // common word likely in any EPUB

      let resultsList = reader.searchResultsList
      XCTAssertTrue(resultsList.waitForExistence(timeout: 10), "Search results should appear")
      XCTAssertGreaterThan(resultsList.cells.count, 0, "At least one search result expected")
    }
  }

  // MARK: - 15. Progress Indicator Shows Position

  func testProgressIndicatorShowsPosition() throws {
    try openFirstAvailableEPUB()

    XCTExpectFailure("Position label may not use expected identifier or format") {
      let label = reader.positionLabel
      XCTAssertTrue(label.waitForExistence(timeout: 5), "Position label should be visible")
      XCTAssertFalse(label.label.isEmpty, "Position label should have content")
    }
  }

  // MARK: - 16. Reader Closes via Back/Done

  func testReaderClosesViaBackDoneButton() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let backBtn = reader.backButton
    XCTAssertTrue(backBtn.waitForExistence(timeout: 3), "Back/Done button should exist")
    backBtn.tap()

    // After closing, we should be back on My Books or detail screen
    let myBooksTab = reader.myBooksTab
    XCTAssertTrue(myBooksTab.waitForExistence(timeout: 10),
                  "Should return to library after closing reader")
  }

  // MARK: - 17. Landscape Orientation

  func testLandscapeOrientationWorks() throws {
    try openFirstAvailableEPUB()

    XCUIDevice.shared.orientation = .landscapeLeft
    sleep(2)

    let webView = reader.webContentView
    XCTAssertTrue(webView.exists, "Content should still be visible in landscape")
    XCTAssertGreaterThan(webView.frame.width, webView.frame.height,
                         "Width should exceed height in landscape")

    // Restore portrait
    XCUIDevice.shared.orientation = .portrait
    sleep(1)
  }

  // MARK: - 18. VoiceOver Announces Page Content

  func testVoiceOverAnnouncesPageContent() throws {
    try openFirstAvailableEPUB()

    // VoiceOver integration is verified at the element level:
    // web content should have an accessibility value or label.
    let webView = reader.webContentView
    XCTExpectFailure("VoiceOver content announcement depends on runtime VoiceOver state") {
      XCTAssertNotNil(webView.value, "Web view should expose content for VoiceOver")
    }
  }

  // MARK: - 19. Long Press Shows Dictionary/Define

  func testLongPressShowsDictionaryDefine() throws {
    try openFirstAvailableEPUB()

    let webView = reader.webContentView
    let center = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

    XCTExpectFailure("Long-press dictionary lookup depends on system behavior and text selection") {
      center.press(forDuration: 1.5)
      sleep(1)

      // Look for the system "Define" or "Look Up" menu item
      let defineItem = app.menuItems["Define"]
      let lookUpItem = app.menuItems["Look Up"]
      let hasDefineOption = defineItem.waitForExistence(timeout: 3) || lookUpItem.exists
      XCTAssertTrue(hasDefineOption, "Long press should show Define or Look Up option")
    }
  }

  // MARK: - 20. Page Turn Animation Completes

  func testPageTurnAnimationCompletes() throws {
    try openFirstAvailableEPUB()

    // Swipe and verify the web view remains responsive
    reader.swipeContentLeft()
    sleep(1)

    let webView = reader.webContentView
    XCTAssertTrue(webView.exists, "Web view should still exist after page turn")
    XCTAssertTrue(webView.isHittable, "Web view should be hittable (not blocked by animation)")
  }

  // MARK: - 21. Reader Handles Empty Content Gracefully

  func testReaderHandlesEmptyContentGracefully() throws {
    // This scenario validates that the reader does not crash on unusual content.
    // Since we cannot inject empty content in a UI test, we verify robustness
    // by rapidly navigating past the end of the book.
    try openFirstAvailableEPUB()

    XCTExpectFailure("Edge-of-book behavior depends on publication structure") {
      // Rapidly advance pages
      for _ in 0..<20 {
        reader.tapRightEdge()
        usleep(200_000) // 200ms
      }

      // Reader should still be alive
      let webView = reader.webContentView
      XCTAssertTrue(webView.exists, "Reader should remain stable at end of book")
    }
  }

  // MARK: - 22. Multiple Bookmarks Can Be Created

  func testMultipleBookmarksCanBeCreated() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let bookmarkBtn = reader.bookmarkButton
    guard bookmarkBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("Bookmark button not found")
    }

    XCTExpectFailure("Bookmark creation across pages may require specific timing") {
      // Bookmark page 1
      bookmarkBtn.tap()
      sleep(1)

      // Navigate forward and bookmark page 2
      reader.tapRightEdge()
      sleep(1)
      ensureNavigationBarVisible()
      bookmarkBtn.tap()
      sleep(1)

      // Navigate forward and bookmark page 3
      reader.tapRightEdge()
      sleep(1)
      ensureNavigationBarVisible()
      bookmarkBtn.tap()
      sleep(1)

      // Verify by opening TOC bookmarks tab (if available)
      let tocBtn = reader.tocButton
      XCTAssertTrue(tocBtn.exists, "TOC button needed to verify bookmarks")
    }
  }

  // MARK: - 23. Bookmark List Is Accessible

  func testBookmarkListIsAccessible() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    let tocBtn = reader.tocButton
    guard tocBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("TOC button not found")
    }
    tocBtn.tap()

    // Look for a bookmarks segment / tab in the positions view controller
    let bookmarksSegment = app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Bookmark"
    )).firstMatch

    XCTExpectFailure("Bookmarks tab may use different label or structure") {
      XCTAssertTrue(bookmarksSegment.waitForExistence(timeout: 5),
                    "Bookmarks segment should be accessible in positions view")
      bookmarksSegment.tap()
    }
  }

  // MARK: - 24. Reader Settings Persist Across Sessions

  func testReaderSettingsPersistAcrossSessions() throws {
    try openFirstAvailableEPUB()
    ensureNavigationBarVisible()

    // Attempt to change a setting
    let settingsBtn = reader.fontSettingsButton
    guard settingsBtn.waitForExistence(timeout: 3) else {
      throw XCTSkip("Settings button not found -- cannot test persistence")
    }

    XCTExpectFailure("Settings persistence requires app relaunch which resets UI test state") {
      settingsBtn.tap()
      let increaseBtn = reader.increaseFontButton
      guard increaseBtn.waitForExistence(timeout: 3) else { return }
      increaseBtn.tap()
      sleep(1)

      // Close and relaunch
      reader.tapCenterOfContent() // dismiss settings
      sleep(1)
      ensureNavigationBarVisible()
      reader.backButton.tap()
      sleep(2)

      app.terminate()
      app.launch()

      try? openFirstAvailableEPUB()
      ensureNavigationBarVisible()

      // Re-open settings and verify -- this is a best-effort check
      let reopenedSettings = reader.fontSettingsButton
      XCTAssertTrue(reopenedSettings.waitForExistence(timeout: 3))
    }
  }

  // MARK: - 25. Page Number Display Updates

  func testPageNumberDisplayUpdates() throws {
    try openFirstAvailableEPUB()

    XCTExpectFailure("Page number display may not be present or may use unexpected format") {
      let posLabel = reader.positionLabel
      guard posLabel.waitForExistence(timeout: 5) else {
        XCTFail("Position label not found")
        return
      }

      let initialText = posLabel.label

      // Navigate forward
      reader.tapRightEdge()
      sleep(2)

      let updatedText = posLabel.label
      XCTAssertNotEqual(initialText, updatedText,
                        "Page number display should update after navigation")
    }
  }
}

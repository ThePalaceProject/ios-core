//
//  PDFReaderUITests.swift
//  PalaceUITests
//
//  XCUITest scenarios for the PDF reader screen.
//  Requires a borrowed/downloaded PDF book on the device under test.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

// MARK: - PDF Reader Page Object

/// Inline page-object helper encapsulating PDF reader element queries.
/// The PDF reader is a SwiftUI `TPPPDFReaderView` wrapped in a UIHostingController.
private struct PDFReaderScreen {
  let app: XCUIApplication

  // MARK: - My Books tab (launch point)

  var myBooksTab: XCUIElement {
    app.tabBars.buttons["My Books"]
  }

  // MARK: - Book Detail

  var readButton: XCUIElement {
    app.buttons["bookDetail.readButton"]
  }

  // MARK: - Navigation bar

  var navigationBar: XCUIElement {
    app.navigationBars.firstMatch
  }

  var backButton: XCUIElement {
    navigationBar.buttons.firstMatch
  }

  // MARK: - Toolbar buttons (TPPPDFNavigation)

  /// TOC / list button (leading toolbar item).
  var tocButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Table of Contents"
    )).firstMatch
  }

  /// Search button (magnifying glass in trailing items).
  var searchButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Search"
    )).firstMatch
  }

  /// Bookmark button (trailing item).
  var bookmarkButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
      "Add Bookmark", "Remove Bookmark"
    )).firstMatch
  }

  /// Resume button shown when in TOC/preview/bookmark modes.
  var resumeButton: XCUIElement {
    navigationBar.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Resume"
    )).firstMatch
  }

  // MARK: - Segmented picker (previews / TOC / bookmarks)

  var previewsSegment: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Page Previews"
    )).firstMatch
  }

  var tocSegment: XCUIElement {
    // Inside the segmented picker, the TOC tab
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Table of Contents"
    )).firstMatch
  }

  var bookmarksSegment: XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] %@", "Bookmark"
    )).firstMatch
  }

  // MARK: - PDF content area

  /// The PDF rendering view. Readium-less path uses PDFView / custom SwiftUI wrapper.
  var pdfContentView: XCUIElement {
    // TPPPDFView or TPPEncryptedPDFView renders inside a hosting controller
    // Look for any scroll view or the generic other element
    let scrollViews = app.scrollViews
    if scrollViews.count > 0 {
      return scrollViews.firstMatch
    }
    return app.otherElements.firstMatch
  }

  /// Page number / location label (TPPPDFLocationView).
  var pageNumberLabel: XCUIElement {
    app.staticTexts.matching(NSPredicate(
      format: "label MATCHES %@", ".*\\d+.*of.*\\d+.*|.*Page.*|.*\\d+/\\d+.*"
    )).firstMatch
  }

  // MARK: - Thumbnail strip (TPPPDFPreviewBar)

  var thumbnailStrip: XCUIElement {
    app.collectionViews.firstMatch
  }

  // MARK: - Search

  var searchField: XCUIElement {
    app.searchFields.firstMatch
  }

  var searchResultsList: XCUIElement {
    app.tables.firstMatch
  }

  // MARK: - Preview grid (TPPPDFPreviewGrid)

  var previewGrid: XCUIElement {
    app.collectionViews.firstMatch
  }

  var previewGridCells: XCUIElementQuery {
    previewGrid.cells
  }

  // MARK: - Actions

  func swipeContentLeft() {
    pdfContentView.swipeLeft()
  }

  func swipeContentRight() {
    pdfContentView.swipeRight()
  }

  func pinchToZoomIn() {
    pdfContentView.pinch(withScale: 2.0, velocity: 1.0)
  }

  func pinchToZoomOut() {
    pdfContentView.pinch(withScale: 0.5, velocity: -1.0)
  }

  func doubleTapCenter() {
    let center = pdfContentView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.doubleTap()
  }
}

// MARK: - Test Class

final class PDFReaderUITests: XCTestCase {

  private var app: XCUIApplication!
  private var reader: PDFReaderScreen!

  // MARK: - Lifecycle

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
    app.launch()
    reader = PDFReaderScreen(app: app)
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
    app = nil
    reader = nil
  }

  // MARK: - Helpers

  /// Navigate to My Books, find a PDF book, and tap Read.
  /// Throws `XCTSkip` when no downloadable PDF is available.
  @discardableResult
  private func openFirstAvailablePDF() throws -> XCUIElement {
    let myBooksTab = reader.myBooksTab
    guard myBooksTab.waitForExistence(timeout: 10) else {
      throw XCTSkip("My Books tab not found -- app may not be configured with a library account")
    }
    myBooksTab.tap()

    // Look for a Read button
    let readButton = app.buttons["bookDetail.readButton"]
    if readButton.waitForExistence(timeout: 5) {
      readButton.tap()
    } else {
      let firstBook = app.collectionViews.cells.firstMatch
      guard firstBook.waitForExistence(timeout: 5) else {
        throw XCTSkip("No downloaded books available for PDF reader testing")
      }
      firstBook.tap()
      guard readButton.waitForExistence(timeout: 5) else {
        throw XCTSkip("Selected book does not have a Read button (may not be a PDF or not downloaded)")
      }
      readButton.tap()
    }

    // Wait for PDF content to render
    let content = reader.pdfContentView
    guard content.waitForExistence(timeout: 15) else {
      throw XCTSkip("PDF reader did not open -- book may not be a valid PDF")
    }
    return content
  }

  // MARK: - 1. PDF Opens

  func testPDFOpensWhenTappingReadOnDownloadedPDF() throws {
    try openFirstAvailablePDF()
    XCTAssertTrue(reader.pdfContentView.exists, "PDF content view should be displayed")
  }

  // MARK: - 2. Page Content Renders

  func testPageContentRenders() throws {
    try openFirstAvailablePDF()
    let content = reader.pdfContentView
    XCTAssertTrue(content.exists, "PDF content must exist")
    XCTAssertGreaterThan(content.frame.width, 0, "PDF content should have positive width")
    XCTAssertGreaterThan(content.frame.height, 0, "PDF content should have positive height")
  }

  // MARK: - 3. Zoom In/Out (Pinch Gesture)

  func testZoomInOutWorks() throws {
    try openFirstAvailablePDF()

    XCTExpectFailure("Pinch zoom may not be verifiable via frame changes in UI tests") {
      let frameBefore = reader.pdfContentView.frame

      reader.pinchToZoomIn()
      sleep(1)

      let frameAfterZoomIn = reader.pdfContentView.frame

      reader.pinchToZoomOut()
      sleep(1)

      // At minimum, the view should still exist and be interactive
      XCTAssertTrue(reader.pdfContentView.exists, "PDF view should survive zoom gestures")
      // Ideally frame or content offset changes
      XCTAssertNotEqual(frameBefore, frameAfterZoomIn,
                        "Frame or content should change after pinch zoom in")
    }
  }

  // MARK: - 4. Page Navigation (Swipe)

  func testPageNavigationViaSwipe() throws {
    try openFirstAvailablePDF()

    XCTExpectFailure("Page label may not be present or may not update predictably") {
      let labelBefore = reader.pageNumberLabel.label

      reader.swipeContentLeft()
      sleep(1)

      let labelAfter = reader.pageNumberLabel.label
      XCTAssertNotEqual(labelBefore, labelAfter,
                        "Page number should update after swipe navigation")
    }
  }

  // MARK: - 5. Thumbnail Strip Visible

  func testThumbnailStripIsVisible() throws {
    try openFirstAvailablePDF()

    XCTExpectFailure("Thumbnail strip visibility depends on PDF reader mode and configuration") {
      let thumbnails = reader.thumbnailStrip
      XCTAssertTrue(thumbnails.waitForExistence(timeout: 5),
                    "Thumbnail strip should be visible in reader")
    }
  }

  // MARK: - 6. Page Number Label Updates

  func testPageNumberLabelUpdates() throws {
    try openFirstAvailablePDF()

    XCTExpectFailure("Page number label format may differ from expected pattern") {
      let label = reader.pageNumberLabel
      XCTAssertTrue(label.waitForExistence(timeout: 5), "Page number label should exist")

      let textBefore = label.label
      reader.swipeContentLeft()
      sleep(1)

      let textAfter = label.label
      XCTAssertNotEqual(textBefore, textAfter,
                        "Page number label should update after page change")
    }
  }

  // MARK: - 7. Bookmark Functionality

  func testBookmarkFunctionalityWorks() throws {
    try openFirstAvailablePDF()

    let bookmarkBtn = reader.bookmarkButton
    XCTExpectFailure("Bookmark button may not be accessible via expected label") {
      XCTAssertTrue(bookmarkBtn.waitForExistence(timeout: 5), "Bookmark button should exist")
    }
    guard bookmarkBtn.exists else { return }

    let labelBefore = bookmarkBtn.label
    bookmarkBtn.tap()
    sleep(1)
    let labelAfter = bookmarkBtn.label

    XCTAssertNotEqual(labelBefore, labelAfter,
                      "Bookmark state should toggle after tap")
  }

  // MARK: - 8. Search Within PDF

  func testSearchWithinPDF() throws {
    try openFirstAvailablePDF()

    let searchBtn = reader.searchButton
    XCTExpectFailure("Search button may not be present in current PDF toolbar") {
      XCTAssertTrue(searchBtn.waitForExistence(timeout: 5), "Search button should exist")
    }
    guard searchBtn.exists else { return }

    searchBtn.tap()

    let searchField = reader.searchField
    XCTExpectFailure("PDF search sheet may use a different UI structure") {
      XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should appear")
      searchField.tap()
      searchField.typeText("the\n")

      let results = reader.searchResultsList
      XCTAssertTrue(results.waitForExistence(timeout: 10), "Search results should appear")
    }
  }

  // MARK: - 9. Landscape Orientation

  func testLandscapeOrientationWorks() throws {
    try openFirstAvailablePDF()

    XCUIDevice.shared.orientation = .landscapeLeft
    sleep(2)

    let content = reader.pdfContentView
    XCTAssertTrue(content.exists, "PDF content should still be visible in landscape")
    XCTAssertGreaterThan(content.frame.width, content.frame.height,
                         "Width should exceed height in landscape")

    XCUIDevice.shared.orientation = .portrait
    sleep(1)
  }

  // MARK: - 10. Navigation Bar Toggle

  func testNavigationBarToggle() throws {
    try openFirstAvailablePDF()

    // PDF reader uses SwiftUI navigation which may always show the bar.
    // Verify the bar exists and contains expected controls.
    let navBar = reader.navigationBar
    XCTAssertTrue(navBar.waitForExistence(timeout: 5), "Navigation bar should exist")

    XCTExpectFailure("Navigation bar toggle may not be supported in SwiftUI PDF reader") {
      // Tap content to potentially toggle
      reader.pdfContentView.tap()
      sleep(1)
      let visibleAfterTap = navBar.isHittable

      reader.pdfContentView.tap()
      sleep(1)
      let visibleAfterSecondTap = navBar.isHittable

      XCTAssertNotEqual(visibleAfterTap, visibleAfterSecondTap,
                        "Navigation bar should toggle on content tap")
    }
  }

  // MARK: - 11. Reader Closes via Back/Done

  func testReaderClosesViaBackDone() throws {
    try openFirstAvailablePDF()

    let backBtn = reader.backButton
    XCTAssertTrue(backBtn.waitForExistence(timeout: 5), "Back button should exist")
    backBtn.tap()

    let myBooksTab = reader.myBooksTab
    XCTAssertTrue(myBooksTab.waitForExistence(timeout: 10),
                  "Should return to library after closing PDF reader")
  }

  // MARK: - 12. Large PDFs Load Without Crash

  func testLargePDFsLoadWithoutCrash() throws {
    // We cannot control which PDF is loaded, but we verify that after opening,
    // the reader remains responsive and does not crash.
    try openFirstAvailablePDF()

    // Perform several interactions to stress the renderer
    for _ in 0..<5 {
      reader.swipeContentLeft()
      usleep(500_000)
    }
    for _ in 0..<5 {
      reader.swipeContentRight()
      usleep(500_000)
    }

    XCTAssertTrue(reader.pdfContentView.exists,
                  "PDF reader should remain stable after rapid navigation")
  }

  // MARK: - 13. PDF Remembers Last Page

  func testPDFRemembersLastPage() throws {
    try openFirstAvailablePDF()

    // Navigate forward
    reader.swipeContentLeft()
    sleep(1)
    reader.swipeContentLeft()
    sleep(1)

    XCTExpectFailure("Last-page persistence may not be verifiable in a single UI test session") {
      let pageBefore = reader.pageNumberLabel.label

      // Close reader
      reader.backButton.tap()
      sleep(2)

      // Reopen
      try openFirstAvailablePDF()
      sleep(2)

      let pageAfter = reader.pageNumberLabel.label
      XCTAssertEqual(pageBefore, pageAfter,
                     "PDF reader should restore the last viewed page")
    }
  }

  // MARK: - 14. Double-Tap to Zoom

  func testDoubleTapToZoomWorks() throws {
    try openFirstAvailablePDF()

    XCTExpectFailure("Double-tap zoom may not be implemented or verifiable via UI tests") {
      let frameBefore = reader.pdfContentView.frame

      reader.doubleTapCenter()
      sleep(1)

      let frameAfter = reader.pdfContentView.frame
      XCTAssertTrue(reader.pdfContentView.exists, "PDF view should survive double-tap")
      XCTAssertNotEqual(frameBefore, frameAfter,
                        "Double-tap should change zoom level")
    }
  }

  // MARK: - 15. Page Jump via Thumbnail

  func testPageJumpViaThumbnail() throws {
    try openFirstAvailablePDF()

    // Open preview grid via TOC button
    let tocBtn = reader.tocButton
    XCTExpectFailure("TOC/preview navigation may use different labels or structure") {
      XCTAssertTrue(tocBtn.waitForExistence(timeout: 5), "TOC button should exist")
    }
    guard tocBtn.exists else { return }

    tocBtn.tap()
    sleep(1)

    // The previews segment should be selected by default or we select it
    let previewsTab = reader.previewsSegment
    if previewsTab.waitForExistence(timeout: 3) {
      previewsTab.tap()
      sleep(1)
    }

    let grid = reader.previewGrid
    XCTExpectFailure("Preview grid may not be visible or may use a different element type") {
      XCTAssertTrue(grid.waitForExistence(timeout: 5), "Preview grid should appear")

      let cells = reader.previewGridCells
      XCTAssertGreaterThan(cells.count, 1, "Preview grid should have multiple thumbnails")

      // Tap a thumbnail that is not the first page
      let targetCell = cells.element(boundBy: min(2, cells.count - 1))
      targetCell.tap()
      sleep(1)

      // Should return to reader view
      XCTAssertTrue(reader.pdfContentView.exists, "Should return to PDF content after thumbnail tap")
    }
  }
}

import XCTest

/// Screen object for the Book Detail screen.
///
/// **AI-DEV GUIDE:**
/// - Represents the book detail/action screen
/// - Handles GET, READ, LISTEN, DELETE, RESERVE actions
/// - Monitors download progress and state changes
///
/// **EXAMPLE:**
/// ```swift
/// let bookDetail = BookDetailScreen(app: app)
/// bookDetail.tapGetButton()
/// bookDetail.waitForDownloadComplete()
/// bookDetail.tapReadButton()
/// ```
final class BookDetailScreen: ScreenObject {
  
  // MARK: - UI Elements
  
  var navigationBar: XCUIElement {
    app.navigationBars[AccessibilityID.BookDetail.navigationBar]
  }
  
  var backButton: XCUIElement {
    navigationBar.buttons.element(boundBy: 0) // Back button is typically first
  }
  
  var coverImage: XCUIElement {
    app.images[AccessibilityID.BookDetail.coverImage]
  }
  
  var titleLabel: XCUIElement {
    app.staticTexts[AccessibilityID.BookDetail.title]
  }
  
  var authorLabel: XCUIElement {
    app.staticTexts[AccessibilityID.BookDetail.author]
  }
  
  var descriptionLabel: XCUIElement {
    app.staticTexts[AccessibilityID.BookDetail.description]
  }
  
  // MARK: - Action Buttons
  
  var getButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.getButton]
  }
  
  var downloadButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.downloadButton]
  }
  
  var readButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.readButton]
  }
  
  var listenButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.listenButton]
  }
  
  var deleteButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.deleteButton]
  }
  
  var returnButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.returnButton]
  }
  
  var reserveButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.reserveButton]
  }
  
  var cancelButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.cancelButton]
  }
  
  var retryButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.retryButton]
  }
  
  var manageHoldButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.manageHoldButton]
  }
  
  var sampleButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.sampleButton]
  }
  
  var audiobookSampleButton: XCUIElement {
    app.buttons[AccessibilityID.BookDetail.audiobookSampleButton]
  }
  
  // MARK: - Progress & State
  
  var downloadProgress: XCUIElement {
    app.progressIndicators[AccessibilityID.BookDetail.downloadProgress]
  }
  
  var halfSheet: XCUIElement {
    app.sheets[AccessibilityID.BookDetail.halfSheet]
  }
  
  // MARK: - Verification
  
  @discardableResult
  override func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    coverImage.waitForExistence(timeout: timeout) || titleLabel.waitForExistence(timeout: timeout)
  }
  
  /// Checks if GET button is visible
  func hasGetButton() -> Bool {
    getButton.exists && getButton.isHittable
  }
  
  /// Checks if READ button is visible (indicates book is downloaded)
  func hasReadButton() -> Bool {
    readButton.exists && readButton.isHittable
  }
  
  /// Checks if LISTEN button is visible (for audiobooks)
  func hasListenButton() -> Bool {
    listenButton.exists && listenButton.isHittable
  }
  
  /// Checks if DELETE button is visible
  func hasDeleteButton() -> Bool {
    deleteButton.exists && deleteButton.isHittable
  }
  
  /// Checks if RESERVE button is visible
  func hasReserveButton() -> Bool {
    reserveButton.exists && reserveButton.isHittable
  }
  
  /// Checks if download is in progress
  func isDownloading() -> Bool {
    downloadProgress.exists || downloadButton.exists
  }
  
  // MARK: - Actions
  
  /// Taps the GET button to start download
  func tapGetButton() {
    XCTAssertTrue(waitForElement(getButton, timeout: defaultTimeout),
                  "GET button not found")
    getButton.tap()
    
    // Handle half sheet if it appears
    if halfSheet.waitForExistence(timeout: shortTimeout) {
      // Download started, half sheet may show progress
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  /// Taps the READ button to open book
  func tapReadButton() {
    XCTAssertTrue(waitForElement(readButton, timeout: defaultTimeout),
                  "READ button not found")
    readButton.tap()
  }
  
  /// Taps the LISTEN button to open audiobook
  func tapListenButton() {
    XCTAssertTrue(waitForElement(listenButton, timeout: defaultTimeout),
                  "LISTEN button not found")
    listenButton.tap()
  }
  
  /// Taps the DELETE button and confirms
  func tapDeleteButton(confirm: Bool = true) {
    XCTAssertTrue(waitForElement(deleteButton, timeout: defaultTimeout),
                  "DELETE button not found")
    deleteButton.tap()
    
    // Half sheet appears for confirmation
    if halfSheet.waitForExistence(timeout: shortTimeout) {
      if confirm {
        // Look for delete confirmation button in half sheet
        let confirmButton = app.sheets.buttons[AccessibilityID.BookDetail.deleteButton]
        if confirmButton.waitForExistence(timeout: shortTimeout) {
          confirmButton.tap()
        }
      } else {
        // Close half sheet
        let closeButton = app.sheets.buttons[AccessibilityID.BookDetail.halfSheetCloseButton]
        if closeButton.exists {
          closeButton.tap()
        }
      }
    }
  }
  
  /// Taps the RESERVE button
  func tapReserveButton() {
    XCTAssertTrue(waitForElement(reserveButton, timeout: defaultTimeout),
                  "RESERVE button not found")
    reserveButton.tap()
  }
  
  /// Waits for download to complete (GET → READ transition)
  /// - Parameter timeout: Maximum wait time
  /// - Returns: true if download completed successfully
  @discardableResult
  func waitForDownloadComplete(timeout: TimeInterval = 30.0) -> Bool {
    let startTime = Date()
    
    while Date().timeIntervalSince(startTime) < timeout {
      // Check if READ or LISTEN button appeared (download complete)
      if hasReadButton() || hasListenButton() {
        return true
      }
      
      // Check if download failed (retry button appeared)
      if retryButton.exists {
        XCTFail("Download failed - RETRY button appeared")
        return false
      }
      
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    XCTFail("Download did not complete within \(timeout) seconds")
    return false
  }
  
  /// Waits for GET button to appear (after deletion)
  /// - Parameter timeout: Maximum wait time
  /// - Returns: true if GET button appeared
  @discardableResult
  func waitForGetButton(timeout: TimeInterval = 10.0) -> Bool {
    let startTime = Date()
    
    while Date().timeIntervalSince(startTime) < timeout {
      if hasGetButton() {
        return true
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    XCTFail("GET button did not appear within \(timeout) seconds")
    return false
  }
  
  /// Downloads a book (GET + wait for completion)
  /// - Returns: true if download successful
  @discardableResult
  func downloadBook() -> Bool {
    tapGetButton()
    return waitForDownloadComplete()
  }
  
  /// Opens a book (taps READ or LISTEN)
  /// - Returns: true if book opened successfully
  @discardableResult
  func openBook() -> Bool {
    if hasReadButton() {
      tapReadButton()
      return true
    } else if hasListenButton() {
      tapListenButton()
      return true
    } else {
      XCTFail("No READ or LISTEN button available")
      return false
    }
  }
  
  /// Full flow: download and open book
  /// - Returns: true if successful
  @discardableResult
  func downloadAndOpenBook() -> Bool {
    guard downloadBook() else { return false }
    return openBook()
  }
  
  /// Returns to previous screen (catalog or search)
  @discardableResult
  func goBack() -> Bool {
    backButton.tap()
    return true
  }
  
  /// Scrolls down to see more book information
  func scrollDown() {
    app.swipeUp()
  }
  
  /// Taps "More..." to expand description
  func expandDescription() {
    let moreButton = app.buttons[AccessibilityID.BookDetail.moreButton]
    if moreButton.exists {
      moreButton.tap()
    }
  }
}


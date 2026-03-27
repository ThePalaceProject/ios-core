import XCTest

final class BookDetailScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var coverImage: XCUIElement { app.images[AccessibilityID.BookDetail.coverImage] }
  var titleLabel: XCUIElement { app.staticTexts[AccessibilityID.BookDetail.title] }
  var authorLabel: XCUIElement { app.staticTexts[AccessibilityID.BookDetail.author] }
  var descriptionLabel: XCUIElement { app.staticTexts[AccessibilityID.BookDetail.description] }
  var moreButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.moreButton] }
  var shareButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.shareButton] }

  // Action buttons
  var getButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.getButton] }
  var downloadButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.downloadButton] }
  var readButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.readButton] }
  var listenButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.listenButton] }
  var deleteButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.deleteButton] }
  var returnButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.returnButton] }
  var reserveButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.reserveButton] }
  var cancelButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.cancelButton] }
  var retryButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.retryButton] }
  var sampleButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.sampleButton] }
  var audiobookSampleButton: XCUIElement { app.buttons[AccessibilityID.BookDetail.audiobookSampleButton] }

  // Progress
  var downloadProgress: XCUIElement { app.progressIndicators[AccessibilityID.BookDetail.downloadProgress] }

  // Metadata
  var informationSection: XCUIElement { app.otherElements[AccessibilityID.BookDetail.informationSection] }
  var publisherLabel: XCUIElement { app.staticTexts[AccessibilityID.BookDetail.publisherLabel] }
  var categoriesLabel: XCUIElement { app.staticTexts[AccessibilityID.BookDetail.categoriesLabel] }
  var relatedBooksSection: XCUIElement { app.otherElements[AccessibilityID.BookDetail.relatedBooksSection] }

  // Navigation
  var backButton: XCUIElement { app.navigationBars.buttons.firstMatch }

  // MARK: - Actions

  @discardableResult
  func tapGet() -> BookDetailScreen {
    getButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapRead() -> EPUBReaderScreen {
    readButton.waitAndTap()
    return EPUBReaderScreen(app: app)
  }

  @discardableResult
  func tapListen() -> AudiobookPlayerScreen {
    listenButton.waitAndTap()
    return AudiobookPlayerScreen(app: app)
  }

  @discardableResult
  func tapBack() -> CatalogScreen {
    backButton.waitAndTap()
    return CatalogScreen(app: app)
  }

  @discardableResult
  func tapSample() -> BookDetailScreen {
    sampleButton.waitAndTap()
    return self
  }

  // MARK: - Assertions

  func verifyLoaded() {
    // Book detail should show at least a title or cover image
    let hasTitle = titleLabel.waitForExistence(timeout: 10)
    let hasCover = coverImage.waitForExistence(timeout: 5)
    XCTAssertTrue(hasTitle || hasCover, "Book detail should show title or cover image")
  }

  func verifyHasActionButton() {
    let hasAction = getButton.exists || readButton.exists || downloadButton.exists
      || reserveButton.exists || listenButton.exists
    XCTAssertTrue(hasAction, "Book detail should have at least one action button")
  }
}

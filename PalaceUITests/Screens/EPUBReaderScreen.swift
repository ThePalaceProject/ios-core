import XCTest

final class EPUBReaderScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  /// The web view that renders EPUB content
  var pageContent: XCUIElement { app.webViews.firstMatch }

  /// Navigation bar (may be hidden until tapped)
  var navigationBar: XCUIElement { app.navigationBars.firstMatch }

  /// Back/close button in the navigation bar
  var backButton: XCUIElement { app.navigationBars.buttons.firstMatch }
  var closeButton: XCUIElement { app.buttons[AccessibilityID.Common.closeButton] }

  /// Table of contents button
  var tocButton: XCUIElement { app.buttons["Table of Contents"] }

  /// Bookmark button
  var bookmarkButton: XCUIElement { app.buttons["Bookmark"] }

  /// Settings/appearance button
  var settingsButton: XCUIElement { app.buttons["Settings"] }

  // MARK: - Actions

  @discardableResult
  func tapCenter() -> EPUBReaderScreen {
    let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.tap()
    return self
  }

  @discardableResult
  func tapNextPage() -> EPUBReaderScreen {
    let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    rightEdge.tap()
    return self
  }

  @discardableResult
  func tapPreviousPage() -> EPUBReaderScreen {
    let leftEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
    leftEdge.tap()
    return self
  }

  @discardableResult
  func showNavigationBar() -> EPUBReaderScreen {
    tapCenter()
    return self
  }

  @discardableResult
  func close() -> BookDetailScreen {
    showNavigationBar()
    if closeButton.exists {
      closeButton.tap()
    } else {
      backButton.waitAndTap()
    }
    return BookDetailScreen(app: app)
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(pageContent.waitForExistence(timeout: 15), "EPUB web view should be visible")
  }
}

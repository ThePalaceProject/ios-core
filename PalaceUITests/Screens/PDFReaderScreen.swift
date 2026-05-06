import XCTest

final class PDFReaderScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  /// PDF content view (PDFKit renders as other elements)
  var pageContent: XCUIElement { app.otherElements.matching(identifier: "PDF View").firstMatch }

  /// Navigation bar (may be hidden until tapped)
  var navigationBar: XCUIElement { app.navigationBars.firstMatch }

  /// Back/close button
  var backButton: XCUIElement { app.navigationBars.buttons.firstMatch }
  var closeButton: XCUIElement { app.buttons[AccessibilityID.Common.closeButton] }

  /// Thumbnail sidebar/overview
  var thumbnailView: XCUIElement { app.scrollViews.element(boundBy: 1) }

  // MARK: - Actions

  @discardableResult
  func tapCenter() -> PDFReaderScreen {
    let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.tap()
    return self
  }

  @discardableResult
  func showNavigationBar() -> PDFReaderScreen {
    tapCenter()
    return self
  }

  @discardableResult
  func pinchToZoomIn() -> PDFReaderScreen {
    pageContent.pinch(withScale: 2.0, velocity: 1.0)
    return self
  }

  @discardableResult
  func pinchToZoomOut() -> PDFReaderScreen {
    pageContent.pinch(withScale: 0.5, velocity: -1.0)
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
    // PDF viewer may render as various element types
    let hasContent = pageContent.waitForExistence(timeout: 15)
      || navigationBar.waitForExistence(timeout: 10)
    XCTAssertTrue(hasContent, "PDF reader should show content or navigation")
  }
}

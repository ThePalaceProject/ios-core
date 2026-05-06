import XCTest

final class CatalogScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var catalogTab: XCUIElement { app.tabBars.buttons["Catalog"] }
  var searchButton: XCUIElement { app.buttons[AccessibilityID.Catalog.searchButton] }
  var accountButton: XCUIElement { app.buttons[AccessibilityID.Catalog.accountButton] }
  var libraryLogo: XCUIElement { app.images[AccessibilityID.Catalog.libraryLogo] }
  var scrollView: XCUIElement { app.scrollViews[AccessibilityID.Catalog.scrollView] }
  var loadingIndicator: XCUIElement { app.activityIndicators[AccessibilityID.Catalog.loadingIndicator] }
  var errorView: XCUIElement { app.otherElements[AccessibilityID.Catalog.errorView] }
  var retryButton: XCUIElement { app.buttons[AccessibilityID.Catalog.retryButton] }

  /// Returns the first book cell found in the catalog via collection views or cells
  var firstBookCell: XCUIElement { app.cells.firstMatch }

  func lane(at index: Int) -> XCUIElement {
    app.otherElements[AccessibilityID.Catalog.lane(index)]
  }

  func laneTitle(at index: Int) -> XCUIElement {
    app.staticTexts[AccessibilityID.Catalog.laneTitle(index)]
  }

  func laneMoreButton(at index: Int) -> XCUIElement {
    app.buttons[AccessibilityID.Catalog.laneMoreButton(index)]
  }

  // MARK: - Actions

  @discardableResult
  func tapSearch() -> SearchScreen {
    searchButton.waitAndTap()
    return SearchScreen(app: app)
  }

  @discardableResult
  func tapFirstBook() -> BookDetailScreen {
    firstBookCell.waitAndTap()
    return BookDetailScreen(app: app)
  }

  @discardableResult
  func navigate() -> CatalogScreen {
    catalogTab.waitAndTap()
    return self
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(catalogTab.waitForExistence(timeout: 10), "Catalog tab should exist")
    // The catalog should show either content or loading state
    let hasContent = scrollView.waitForExistence(timeout: 15)
      || firstBookCell.waitForExistence(timeout: 5)
      || loadingIndicator.exists
    XCTAssertTrue(hasContent, "Catalog should show content, cells, or loading indicator")
  }
}

import XCTest

final class SearchScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var searchField: XCUIElement { app.searchFields.firstMatch }
  var cancelButton: XCUIElement { app.buttons[AccessibilityID.Search.cancelButton] }
  var clearButton: XCUIElement { app.buttons[AccessibilityID.Search.clearButton] }
  var resultsScrollView: XCUIElement { app.scrollViews[AccessibilityID.Search.resultsScrollView] }
  var noResultsView: XCUIElement { app.otherElements[AccessibilityID.Search.noResultsView] }
  var loadingIndicator: XCUIElement { app.activityIndicators[AccessibilityID.Search.loadingIndicator] }
  var firstResultCell: XCUIElement { app.cells.firstMatch }

  // MARK: - Actions

  @discardableResult
  func typeQuery(_ query: String) -> SearchScreen {
    searchField.waitAndTap()
    searchField.typeText(query)
    return self
  }

  @discardableResult
  func submitSearch() -> SearchScreen {
    searchField.typeText("\n")
    return self
  }

  @discardableResult
  func clearSearch() -> SearchScreen {
    clearButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapCancel() -> CatalogScreen {
    // Try the accessibility-identified cancel first, fall back to system Cancel
    if cancelButton.exists {
      cancelButton.tap()
    } else {
      app.buttons["Cancel"].waitAndTap()
    }
    return CatalogScreen(app: app)
  }

  @discardableResult
  func tapFirstResult() -> BookDetailScreen {
    firstResultCell.waitAndTap()
    return BookDetailScreen(app: app)
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field should be visible")
  }

  func verifyHasResults() {
    XCTAssertTrue(firstResultCell.waitForExistence(timeout: 15), "Search results should appear")
  }

  func verifyNoResults() {
    XCTAssertTrue(noResultsView.waitForExistence(timeout: 10), "No results view should appear")
  }
}

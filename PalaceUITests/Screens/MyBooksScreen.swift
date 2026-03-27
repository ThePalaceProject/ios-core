import XCTest

final class MyBooksScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var myBooksTab: XCUIElement { app.tabBars.buttons["My Books"] }
  var searchButton: XCUIElement { app.buttons[AccessibilityID.MyBooks.searchButton] }
  var sortButton: XCUIElement { app.buttons[AccessibilityID.MyBooks.sortButton] }
  var gridView: XCUIElement { app.collectionViews[AccessibilityID.MyBooks.gridView] }
  var emptyStateView: XCUIElement { app.otherElements[AccessibilityID.MyBooks.emptyStateView] }
  var loadingIndicator: XCUIElement { app.activityIndicators[AccessibilityID.MyBooks.loadingIndicator] }

  // Sort menu
  var sortMenu: XCUIElement { app.otherElements[AccessibilityID.MyBooks.sortMenu] }
  var sortByAuthor: XCUIElement { app.buttons[AccessibilityID.MyBooks.sortByAuthor] }
  var sortByTitle: XCUIElement { app.buttons[AccessibilityID.MyBooks.sortByTitle] }

  var firstBookCell: XCUIElement { app.cells.firstMatch }

  // MARK: - Actions

  @discardableResult
  func navigate() -> MyBooksScreen {
    myBooksTab.waitAndTap()
    return self
  }

  @discardableResult
  func tapSort() -> MyBooksScreen {
    sortButton.waitAndTap()
    return self
  }

  @discardableResult
  func sortByAuthorName() -> MyBooksScreen {
    tapSort()
    sortByAuthor.waitAndTap()
    return self
  }

  @discardableResult
  func sortByBookTitle() -> MyBooksScreen {
    tapSort()
    sortByTitle.waitAndTap()
    return self
  }

  @discardableResult
  func tapFirstBook() -> BookDetailScreen {
    firstBookCell.waitAndTap()
    return BookDetailScreen(app: app)
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(myBooksTab.waitForExistence(timeout: 10), "My Books tab should exist")
    // Should show either grid content or empty state
    let hasContent = gridView.waitForExistence(timeout: 10)
      || emptyStateView.waitForExistence(timeout: 5)
      || loadingIndicator.exists
    XCTAssertTrue(hasContent, "My Books should show grid, empty state, or loading")
  }

  func verifyEmpty() {
    XCTAssertTrue(emptyStateView.waitForExistence(timeout: 10), "Empty state should be visible")
  }
}

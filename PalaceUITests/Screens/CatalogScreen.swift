import XCTest

/// Screen object for the Catalog/Browse screen.
///
/// **AI-DEV GUIDE:**
/// - Represents the main catalog browsing screen
/// - Provides access to search, lanes, and book selection
/// - Use this as the starting point for most test flows
///
/// **EXAMPLE:**
/// ```swift
/// let catalog = CatalogScreen(app: app)
/// XCTAssertTrue(catalog.isDisplayed())
/// let search = catalog.tapSearchButton()
/// ```
final class CatalogScreen: ScreenObject {
  
  // MARK: - UI Elements
  
  var navigationBar: XCUIElement {
    app.navigationBars[AccessibilityID.Catalog.navigationBar]
  }
  
  var searchButton: XCUIElement {
    app.buttons[AccessibilityID.Catalog.searchButton]
  }
  
  var accountButton: XCUIElement {
    app.buttons[AccessibilityID.Catalog.accountButton]
  }
  
  var libraryLogo: XCUIElement {
    app.images[AccessibilityID.Catalog.libraryLogo]
  }
  
  var scrollView: XCUIElement {
    app.scrollViews[AccessibilityID.Catalog.scrollView]
  }
  
  var loadingIndicator: XCUIElement {
    app.activityIndicators[AccessibilityID.Catalog.loadingIndicator]
  }
  
  var errorView: XCUIElement {
    app.otherElements[AccessibilityID.Catalog.errorView]
  }
  
  var retryButton: XCUIElement {
    app.buttons[AccessibilityID.Catalog.retryButton]
  }
  
  // MARK: - Verification
  
  @discardableResult
  override func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    // Catalog is displayed when either the scroll view or loading indicator is visible
    let displayed = scrollView.waitForExistence(timeout: timeout) ||
                   loadingIndicator.waitForExistence(timeout: timeout)
    
    if displayed {
      // Wait for loading to complete if present
      if loadingIndicator.exists {
        _ = waitForElementToDisappear(loadingIndicator, timeout: longTimeout)
      }
    }
    
    return displayed
  }
  
  /// Verifies the catalog loaded successfully (no error state)
  func isCatalogLoaded() -> Bool {
    !errorView.exists && scrollView.exists
  }
  
  // MARK: - Actions
  
  /// Taps the search button and returns the search screen
  @discardableResult
  func tapSearchButton() -> SearchScreen {
    XCTAssertTrue(waitForElement(searchButton, timeout: defaultTimeout),
                  "Search button not found")
    searchButton.tap()
    return SearchScreen(app: app)
  }
  
  /// Taps the account/library selection button
  @discardableResult
  func tapAccountButton() -> Bool {
    safeTap(accountButton)
  }
  
  /// Scrolls to find and tap a book by its identifier
  /// - Parameter bookID: The book's identifier
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func selectBook(withID bookID: String) -> BookDetailScreen? {
    let bookCell = app.otherElements[AccessibilityID.Catalog.bookCell(bookID)]
    
    if scrollAndTap(bookCell, in: scrollView) {
      return BookDetailScreen(app: app)
    }
    
    return nil
  }
  
  /// Taps the first visible book in the catalog
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func selectFirstBook() -> BookDetailScreen? {
    // Find first book cell (they have specific accessibility pattern)
    let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.bookCell.'"))
    
    guard bookCells.count > 0 else {
      XCTFail("No books found in catalog")
      return nil
    }
    
    let firstBook = bookCells.element(boundBy: 0)
    if firstBook.waitForExistence(timeout: defaultTimeout) {
      firstBook.tap()
      return BookDetailScreen(app: app)
    }
    
    return nil
  }
  
  /// Scrolls to a specific lane by index
  /// - Parameter index: Lane index (0-based)
  /// - Returns: true if lane found
  @discardableResult
  func scrollToLane(_ index: Int) -> Bool {
    let lane = app.otherElements[AccessibilityID.Catalog.lane(index)]
    return scrollAndTap(lane, in: scrollView)
  }
  
  /// Taps "More" button for a specific lane
  /// - Parameter index: Lane index
  /// - Returns: true if tapped successfully
  @discardableResult
  func tapMoreButton(forLane index: Int) -> Bool {
    let moreButton = app.buttons[AccessibilityID.Catalog.laneMoreButton(index)]
    return scrollAndTap(moreButton, in: scrollView)
  }
  
  /// Retries loading the catalog if error state is shown
  @discardableResult
  func retryLoading() -> Bool {
    guard errorView.exists else {
      return false
    }
    
    safeTap(retryButton)
    
    // Wait for loading to complete
    if loadingIndicator.exists {
      _ = waitForElementToDisappear(loadingIndicator, timeout: longTimeout)
    }
    
    return isCatalogLoaded()
  }
  
  /// Pull to refresh the catalog
  func pullToRefresh() {
    scrollView.swipeDown()
    
    // Wait for refresh to complete
    Thread.sleep(forTimeInterval: 2.0)
    
    if loadingIndicator.exists {
      _ = waitForElementToDisappear(loadingIndicator, timeout: longTimeout)
    }
  }
}


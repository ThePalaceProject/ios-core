import XCTest

/// Screen object for the Search screen.
///
/// **AI-DEV GUIDE:**
/// - Handles book search functionality
/// - Supports text entry and result selection
/// - Returns to catalog or navigates to book details
///
/// **EXAMPLE:**
/// ```swift
/// let search = SearchScreen(app: app)
/// search.enterSearchText("alice wonderland")
/// search.tapFirstResult()
/// ```
final class SearchScreen: ScreenObject {
  
  // MARK: - UI Elements
  
  var searchField: XCUIElement {
    app.searchFields[AccessibilityID.Search.searchField]
  }
  
  var clearButton: XCUIElement {
    app.buttons[AccessibilityID.Search.clearButton]
  }
  
  var cancelButton: XCUIElement {
    app.buttons[AccessibilityID.Search.cancelButton]
  }
  
  var resultsScrollView: XCUIElement {
    app.scrollViews[AccessibilityID.Search.resultsScrollView]
  }
  
  var noResultsView: XCUIElement {
    app.otherElements[AccessibilityID.Search.noResultsView]
  }
  
  var loadingIndicator: XCUIElement {
    app.activityIndicators[AccessibilityID.Search.loadingIndicator]
  }
  
  // MARK: - Verification
  
  @discardableResult
  override func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    searchField.waitForExistence(timeout: timeout)
  }
  
  /// Checks if search results are displayed
  func hasResults() -> Bool {
    !noResultsView.exists && resultsScrollView.exists
  }
  
  /// Checks if "no results" state is displayed
  func hasNoResults() -> Bool {
    noResultsView.exists
  }
  
  /// Returns the number of visible result cells
  func resultCount() -> Int {
    let results = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'"))
    return results.count
  }
  
  // MARK: - Actions
  
  /// Enters text into the search field
  /// - Parameter text: Search query
  func enterSearchText(_ text: String) {
    XCTAssertTrue(waitForElement(searchField, timeout: defaultTimeout),
                  "Search field not found")
    
    searchField.tap()
    searchField.typeText(text)
    
    // Wait for search results to load
    if loadingIndicator.exists {
      _ = waitForElementToDisappear(loadingIndicator, timeout: longTimeout)
    }
    
    // Give results time to appear
    wait(1.0)
  }
  
  /// Clears the search field
  func clearSearch() {
    if clearButton.exists {
      clearButton.tap()
    } else {
      // Fallback: select all and delete
      searchField.tap()
      searchField.clearAndType("")
    }
  }
  
  /// Taps the cancel button to return to catalog
  @discardableResult
  func cancel() -> CatalogScreen {
    cancelButton.tap()
    return CatalogScreen(app: app)
  }
  
  /// Taps the first search result
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func tapFirstResult() -> BookDetailScreen? {
    let results = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'"))
    
    guard results.count > 0 else {
      XCTFail("No search results found")
      return nil
    }
    
    let firstResult = results.element(boundBy: 0)
    if firstResult.waitForExistence(timeout: defaultTimeout) {
      firstResult.tap()
      return BookDetailScreen(app: app)
    }
    
    return nil
  }
  
  /// Taps a specific search result by book ID
  /// - Parameter bookID: The book's identifier
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func tapResult(withID bookID: String) -> BookDetailScreen? {
    let resultCell = app.otherElements[AccessibilityID.Search.resultCell(bookID)]
    
    if scrollAndTap(resultCell, in: resultsScrollView) {
      return BookDetailScreen(app: app)
    }
    
    return nil
  }
  
  /// Searches for text and taps the first result
  /// - Parameter text: Search query
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func searchAndSelectFirst(_ text: String) -> BookDetailScreen? {
    enterSearchText(text)
    return tapFirstResult()
  }
  
  /// Verifies that search results contain expected text
  /// - Parameter text: Text to search for in results
  /// - Returns: true if text found in any result
  func resultsContain(_ text: String) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
    let matchingElements = app.staticTexts.matching(predicate)
    return matchingElements.count > 0
  }
}


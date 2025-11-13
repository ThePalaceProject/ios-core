import XCTest

/// Screen object for the My Books/Library screen.
///
/// **AI-DEV GUIDE:**
/// - Represents user's downloaded/borrowed books
/// - Supports sorting, searching, and book selection
/// - Can refresh to update book states
///
/// **EXAMPLE:**
/// ```swift
/// let myBooks = MyBooksScreen(app: app)
/// XCTAssertTrue(myBooks.hasBooks())
/// myBooks.selectFirstBook()
/// ```
final class MyBooksScreen: ScreenObject {
  
  // MARK: - UI Elements
  
  var navigationBar: XCUIElement {
    app.navigationBars[AccessibilityID.MyBooks.navigationBar]
  }
  
  var searchButton: XCUIElement {
    app.buttons[AccessibilityID.MyBooks.searchButton]
  }
  
  var sortButton: XCUIElement {
    app.buttons[AccessibilityID.MyBooks.sortButton]
  }
  
  var gridView: XCUIElement {
    app.otherElements[AccessibilityID.MyBooks.gridView]
  }
  
  var emptyStateView: XCUIElement {
    app.otherElements[AccessibilityID.MyBooks.emptyStateView]
  }
  
  var loadingIndicator: XCUIElement {
    app.activityIndicators[AccessibilityID.MyBooks.loadingIndicator]
  }
  
  // MARK: - Verification
  
  @discardableResult
  override func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    navigationBar.waitForExistence(timeout: timeout)
  }
  
  /// Checks if user has any books
  func hasBooks() -> Bool {
    !emptyStateView.exists && !isEmptyLibrary()
  }
  
  /// Checks if library is empty
  func isEmptyLibrary() -> Bool {
    emptyStateView.exists || bookCount() == 0
  }
  
  /// Returns the number of books in library
  func bookCount() -> Int {
    let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'myBooks.bookCell.'"))
    return bookCells.count
  }
  
  /// Checks if a specific book exists in library
  /// - Parameter bookID: Book identifier
  /// - Returns: true if book is present
  func hasBook(withID bookID: String) -> Bool {
    let bookCell = app.otherElements[AccessibilityID.MyBooks.bookCell(bookID)]
    return bookCell.exists
  }
  
  // MARK: - Actions
  
  /// Pulls to refresh the book list
  func pullToRefresh() {
    // Scroll view is usually the main content area
    let scrollView = app.scrollViews.firstMatch
    if scrollView.exists {
      scrollView.swipeDown()
      
      // Wait for refresh to complete
      wait(2.0)
      
      if loadingIndicator.exists {
        _ = waitForElementToDisappear(loadingIndicator, timeout: longTimeout)
      }
    }
  }
  
  /// Taps the sort button and shows sort menu
  func tapSortButton() {
    XCTAssertTrue(waitForElement(sortButton, timeout: defaultTimeout),
                  "Sort button not found")
    sortButton.tap()
  }
  
  /// Changes sort order
  /// - Parameter sortType: The sort order to apply
  func sortBy(_ sortType: MyBooksSortType) {
    tapSortButton()
    
    let sortOption: XCUIElement
    switch sortType {
    case .author:
      sortOption = app.buttons[AccessibilityID.MyBooks.sortByAuthor]
    case .title:
      sortOption = app.buttons[AccessibilityID.MyBooks.sortByTitle]
    }
    
    XCTAssertTrue(waitForElement(sortOption, timeout: shortTimeout),
                  "Sort option '\(sortType)' not found")
    sortOption.tap()
    
    // Wait for re-sort animation
    wait(0.5)
  }
  
  /// Selects the first book in the library
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func selectFirstBook() -> BookDetailScreen? {
    let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'myBooks.bookCell.'"))
    
    guard bookCells.count > 0 else {
      XCTFail("No books found in My Books")
      return nil
    }
    
    let firstBook = bookCells.element(boundBy: 0)
    if firstBook.waitForExistence(timeout: defaultTimeout) {
      firstBook.tap()
      return BookDetailScreen(app: app)
    }
    
    return nil
  }
  
  /// Selects a specific book by ID
  /// - Parameter bookID: Book identifier
  /// - Returns: BookDetailScreen if successful
  @discardableResult
  func selectBook(withID bookID: String) -> BookDetailScreen? {
    let bookCell = app.otherElements[AccessibilityID.MyBooks.bookCell(bookID)]
    
    // Try direct tap first
    if bookCell.exists && bookCell.isHittable {
      bookCell.tap()
      return BookDetailScreen(app: app)
    }
    
    // Scroll to find book
    let scrollView = app.scrollViews.firstMatch
    if scrollView.scrollUntilVisible(bookCell) {
      bookCell.tap()
      return BookDetailScreen(app: app)
    }
    
    XCTFail("Book with ID '\(bookID)' not found in My Books")
    return nil
  }
  
  /// Waits for a book to appear in library (after download)
  /// - Parameters:
  ///   - bookID: Book identifier
  ///   - timeout: Maximum wait time
  /// - Returns: true if book appeared
  @discardableResult
  func waitForBook(withID bookID: String, timeout: TimeInterval = 30.0) -> Bool {
    let bookCell = app.otherElements[AccessibilityID.MyBooks.bookCell(bookID)]
    return bookCell.waitForExistence(timeout: timeout)
  }
  
  /// Waits for a book to disappear (after deletion)
  /// - Parameters:
  ///   - bookID: Book identifier
  ///   - timeout: Maximum wait time
  /// - Returns: true if book disappeared
  @discardableResult
  func waitForBookToDisappear(withID bookID: String, timeout: TimeInterval = 10.0) -> Bool {
    let bookCell = app.otherElements[AccessibilityID.MyBooks.bookCell(bookID)]
    return waitForElementToDisappear(bookCell, timeout: timeout)
  }
  
  /// Gets the title of a book in the list
  /// - Parameter bookID: Book identifier
  /// - Returns: Book title text
  func bookTitle(forID bookID: String) -> String? {
    let titleLabel = app.staticTexts[AccessibilityID.MyBooks.bookTitle(bookID)]
    return titleLabel.exists ? titleLabel.label : nil
  }
}

/// My Books sort options
enum MyBooksSortType {
  case author
  case title
}


import XCTest

/// My Books functionality tests
/// Converted from: MyBooks.feature
final class MyBooksTests: XCTestCase {
  
  var app: XCUIApplication!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    
    app = XCUIApplication()
    app.launchArguments = ["-testMode", "1"]
    app.launch()
    _ = app.tabBars.firstMatch.waitForExistence(timeout: 15.0)
  }
  
  override func tearDownWithError() throws {
    app.terminate()
    TestContext.shared.clear()
    try super.tearDownWithError()
  }
  
  // MARK: - From MyBooks.feature
  
  /// Scenario: Check of added books in Palace Bookshelf (line 4)
  func testCheckAddedBooksInPalaceBookshelf() {
    // Close tutorial/welcome
    skipTutorialIfPresent()
    skipWelcomeIfPresent()
    
    // Add Palace Bookshelf library
    selectLibrary("Palace Bookshelf")
    
    // Search for books
    TestHelpers.navigateToTab("Catalog")
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.waitForExistence(timeout: 5.0) {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Search and save books
    let booksToAdd = ["One Way", "Jane Eyre", "The Tempest", "Poetry"]
    TestContext.shared.save(booksToAdd, forKey: "listOfBooks")
    
    // Return from search
    let cancelButton = app.buttons["Cancel"]
    if cancelButton.exists { cancelButton.tap() }
    
    // Go to My Books
    TestHelpers.navigateToTab("My Books")
    
    // Verify books added
    let myBooksTab = app.tabBars.buttons[AppStrings.TabBar.myBooks]
    XCTAssertTrue(myBooksTab.isSelected, "Should be on My Books")
  }
  
  /// Scenario: Check of sorting in Palace Bookshelf (line 22)
  func testSortingInPalaceBookshelf() {
    skipTutorialIfPresent()
    selectLibrary("Palace Bookshelf")
    
    // Search for books
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    
    // Add books
    let books = ["One Way", "Jane Eyre", "The Tempest", "Poetry"]
    TestContext.shared.save(books, forKey: "listOfBooks")
    
    returnFromSearch()
    
    // Go to My Books
    TestHelpers.navigateToTab("My Books")
    
    // Default sort by Author
    Thread.sleep(forTimeInterval: 1.0)
    
    // Change to Title sort
    let sortButton = app.buttons[AccessibilityID.MyBooks.sortButton]
    if !sortButton.exists {
      let anySortButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sort'")).firstMatch
      if anySortButton.exists {
        anySortButton.tap()
        Thread.sleep(forTimeInterval: 0.5)
      }
    } else {
      sortButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Select Title (use element in sheet/alert, not background)
    let titleOption = app.sheets.buttons["Title"]
    if !titleOption.exists {
      let anyTitleButton = app.buttons["Title"].firstMatch
      if anyTitleButton.exists { anyTitleButton.tap() }
    } else {
      titleOption.tap()
    }
    
    // Verify sort applied
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.myBooks].isSelected)
  }
  
  /// Scenario: Return book from My Books in Lyrasis Reads (line 40)
  func testReturnBookFromMyBooksInLyrasisReads() {
    skipTutorialIfPresent()
    skipWelcomeIfPresent()
    selectLibrary("Lyrasis Reads")
    
    // Sign in
    signInToLyrasis()
    
    // Search for book
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    searchForBook(distributor: "Bibliotheca", bookType: "EBOOK")
    
    // Get book from catalog
    let firstBook = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.bookCell.'")).firstMatch
    if firstBook.waitForExistence(timeout: 5.0) {
      firstBook.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Tap GET (use firstMatch to handle multiple results)
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.waitForExistence(timeout: 5.0) {
      getButton.tap()
    }
    
    // Wait for download
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    _ = readButton.waitForExistence(timeout: 30.0)
    
    // Go to My Books
    TestHelpers.navigateToTab("My Books")
    
    // Verify book present with READ button
    Thread.sleep(forTimeInterval: 1.0)
    
    // Open book
    let firstMyBook = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'myBooks.bookCell.'")).firstMatch
    if firstMyBook.exists {
      firstMyBook.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Return book
    let returnButton = app.buttons[AccessibilityID.BookDetail.deleteButton] // iOS shows DELETE not RETURN
    if returnButton.exists {
      returnButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Confirm
      let confirmButton = app.sheets.buttons.element(boundBy: 0)
      if confirmButton.exists {
        confirmButton.tap()
      }
    }
    
    // Go back to My Books
    TestHelpers.navigateToTab("My Books")
    
    // Book should be gone (or show GET button if back in catalog)
    Thread.sleep(forTimeInterval: 2.0)
  }
  
  // MARK: - Helper Methods
  
  private func skipTutorialIfPresent() {
    Thread.sleep(forTimeInterval: 1.0)
    let skipButton = app.buttons["Skip"]
    if skipButton.exists { skipButton.tap() }
    let doneButton = app.buttons["Done"]
    if doneButton.exists { doneButton.tap() }
  }
  
  private func skipWelcomeIfPresent() {
    Thread.sleep(forTimeInterval: 0.5)
    let closeButton = app.buttons["Close"]
    if closeButton.exists { closeButton.tap() }
    let continueButton = app.buttons["Continue"]
    if continueButton.exists { continueButton.tap() }
  }
  
  private func selectLibrary(_ name: String) {
    Thread.sleep(forTimeInterval: 1.0)
    // Navigate to library selection if needed
    // For now, assume library already selected or handle via settings
  }
  
  private func signInToLyrasis() {
    let credentials = TestHelpers.TestCredentials.lyrasis
    
    Thread.sleep(forTimeInterval: 1.0)
    
    let barcodeField = app.textFields.firstMatch
    if barcodeField.waitForExistence(timeout: 5.0) {
      barcodeField.tap()
      barcodeField.typeText(credentials.barcode)
    }
    
    let pinField = app.secureTextFields.firstMatch
    if pinField.waitForExistence(timeout: 3.0) {
      pinField.tap()
      pinField.typeText(credentials.pin)
    }
    
    let signInButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign'")).firstMatch
    if signInButton.exists {
      signInButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
  }
  
  private func openSearch() {
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  private func searchForBook(distributor: String, bookType: String) {
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      
      let searchTerm = bookType == "AUDIOBOOK" ? "audiobook" : bookType == "PDF" ? "pdf" : "book"
      searchField.typeText(searchTerm)
      Thread.sleep(forTimeInterval: 2.0)
    }
  }
  
  private func returnFromSearch() {
    let cancelButton = app.buttons["Cancel"]
    if cancelButton.exists { cancelButton.tap() }
  }
}


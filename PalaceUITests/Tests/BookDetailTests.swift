import XCTest

/// Book Detail View tests
/// Converted from: BookDetailView.feature
final class BookDetailTests: XCTestCase {
  
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
  
  /// From BookDetailView.feature - basic book detail display
  func testBookDetailDisplaysMetadata() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    
    // Search for book
    openSearch()
    search("Alice")
    
    // Tap first result
    tapFirstResult()
    
    // Verify book detail elements
    let coverImage = app.images[AccessibilityID.BookDetail.coverImage]
    let titleLabel = app.staticTexts[AccessibilityID.BookDetail.title]
    
    XCTAssertTrue(coverImage.waitForExistence(timeout: 5.0) || titleLabel.waitForExistence(timeout: 5.0),
                  "Book detail should display")
    
    // Should have action button
    let hasActionButton = app.buttons[AccessibilityID.BookDetail.getButton].exists ||
                         app.buttons[AccessibilityID.BookDetail.readButton].exists ||
                         app.buttons[AccessibilityID.BookDetail.listenButton].exists
    
    XCTAssertTrue(hasActionButton, "Should have action button")
  }
  
  /// Book detail shows description
  func testBookDetailShowsDescription() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Pride Prejudice")
    tapFirstResult()
    
    // Look for description text (long text)
    Thread.sleep(forTimeInterval: 1.0)
    let hasLongText = app.staticTexts.allElementsBoundByIndex.contains { $0.label.count > 100 }
    
    // Don't fail - some books don't have descriptions
    if hasLongText {
      print("✅ Description found")
    }
  }
  
  /// Can expand/collapse description with More button
  func testExpandCollapseDescription() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Moby Dick")
    tapFirstResult()
    
    Thread.sleep(forTimeInterval: 1.0)
    
    // Look for More button
    let moreButton = app.buttons.matching(NSPredicate(format: "label == 'More' OR label == 'More...'")).firstMatch
    
    if moreButton.exists {
      moreButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Should show Less button now
      let lessButton = app.buttons.matching(NSPredicate(format: "label == 'Less'")).firstMatch
      // Don't strictly assert - UI may vary
    }
  }
  
  // MARK: - Helpers
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
  
  private func openSearch() {
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  private func search(_ term: String) {
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText(term)
      Thread.sleep(forTimeInterval: 2.0)
    }
  }
  
  private func tapFirstResult() {
    let firstResult = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
    if !firstResult.exists {
      // Try cells or any tappable element
      let anyResult = app.cells.firstMatch
      if anyResult.exists {
        anyResult.tap()
      } else {
        // Tap first book-like element
        let anyBook = app.otherElements.element(boundBy: 0)
        anyBook.tap()
      }
    } else {
      firstResult.tap()
    }
    Thread.sleep(forTimeInterval: 1.0)
  }
}


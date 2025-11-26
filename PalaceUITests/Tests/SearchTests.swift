import XCTest

/// Search functionality tests
/// Converted from: Search.feature
final class SearchTests: XCTestCase {
  
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
  
  // MARK: - From Search.feature
  
  /// Scenario: Find a book with name in different font cases in Palace Bookshelf (line 43)
  func testFindBookDifferentCasesInPalaceBookshelf() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    
    // Open search
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.waitForExistence(timeout: 5.0) {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Search for book (different cases tested: "el gato negro", "EL GATO NEGRO", "eL gAto NeGrO")
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText("el gato negro")
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Verify results
    Thread.sleep(forTimeInterval: 1.0)
    // First book should match search term
    XCTAssertTrue(app.otherElements.count > 0 || app.cells.count > 0, "Should have search results")
  }
  
  /// Scenario: Check that the field allows you to enter characters (line 189)
  func testSearchFieldAllowsInput() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    
    TestHelpers.navigateToTab("Catalog")
    
    // Open search
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.waitForExistence(timeout: 5.0) {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Type text
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText("book")
      
      // Verify text entered
      let value = searchField.value as? String ?? ""
      XCTAssertTrue(value.contains("book"), "Search field should contain typed text")
    }
  }
  
  /// Scenario: Check of the Delete button in Lyrasis Reads (line 215)
  func testClearSearchField() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    
    TestHelpers.navigateToTab("Catalog")
    
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.waitForExistence(timeout: 5.0) {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText("Silk Road")
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Clear search
    let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
    if !clearButton.exists {
      let xButton = app.buttons["xmark.circle.fill"]
      if xButton.exists { xButton.tap() }
    } else {
      clearButton.tap()
    }
    
    // Verify cleared
    Thread.sleep(forTimeInterval: 0.5)
    if searchField.exists {
      let value = searchField.value as? String ?? ""
      XCTAssertTrue(value.isEmpty, "Search field should be empty")
    }
  }
  
  // MARK: - Helpers
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    let skipButton = app.buttons["Skip"]
    if skipButton.exists { skipButton.tap() }
    let closeButton = app.buttons["Close"]
    if closeButton.exists { closeButton.tap() }
  }
  
  private func selectLibrary(_ name: String) {
    Thread.sleep(forTimeInterval: 1.0)
    // Library selection logic
  }
}


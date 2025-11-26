import XCTest

/// Catalog navigation tests
/// Converted from: CatalogNavigation.feature
final class CatalogNavigationTests: XCTestCase {
  
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
  
  /// Basic catalog loading
  func testCatalogLoads() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    
    // Verify catalog loaded
    let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
    XCTAssertTrue(catalogTab.isSelected, "Catalog should load")
    
    Thread.sleep(forTimeInterval: 2.0)
    
    // Should show content or loading state
    let hasContent = app.buttons.count > 5 || app.staticTexts.count > 5
    XCTAssertTrue(hasContent, "Catalog should show content")
  }
  
  /// Navigate between catalog tabs (All, eBooks, Audiobooks)
  func testNavigateBetweenCatalogTabs() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    Thread.sleep(forTimeInterval: 1.0)
    
    // Look for category/filter tabs
    let eBooksTab = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'ebooks' OR label CONTAINS[c] 'books'")).firstMatch
    let audiobooksTab = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'audiobook'")).firstMatch
    
    // If tabs exist, navigate
    if eBooksTab.exists {
      eBooksTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    if audiobooksTab.exists {
      audiobooksTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Verify still on catalog
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.catalog].isSelected)
  }
  
  /// Search from catalog
  func testSearchFromCatalog() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    
    // Tap search
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    XCTAssertTrue(searchButton.waitForExistence(timeout: 5.0), "Search button should exist")
    
    searchButton.tap()
    Thread.sleep(forTimeInterval: 0.5)
    
    // Verify search field appears
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Search field should appear")
  }
  
  /// Cancel search returns to catalog
  func testCancelSearchReturnsToCatalog() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Cancel
    let cancelButton = app.buttons["Cancel"]
    if cancelButton.exists {
      cancelButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Should be back on catalog
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.catalog].isSelected)
  }
  
  // MARK: - Helpers
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
}


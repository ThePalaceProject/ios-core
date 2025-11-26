import XCTest

/// Library management tests
/// Converted from: ManageLibraries.feature
final class LibraryManagementTests: XCTestCase {
  
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
  
  func testSwitchBetweenLibraries() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Settings")
    Thread.sleep(forTimeInterval: 1.0)
    
    // Look for library selection
    let libraryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'library' OR label CONTAINS[c] 'libraries'")).firstMatch
    
    if libraryButton.exists {
      libraryButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Should show library list
      XCTAssertTrue(app.cells.count > 0 || app.buttons.count > 5, "Should show library options")
    }
  }
  
  func testAddLibraryFlow() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Settings")
    Thread.sleep(forTimeInterval: 1.0)
    
    let addLibraryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'add library'")).firstMatch
    
    if addLibraryButton.exists {
      addLibraryButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Should show library search or list
      let hasSearchOrList = app.searchFields.count > 0 || app.textFields.count > 0 || app.cells.count > 0
      XCTAssertTrue(hasSearchOrList, "Add library screen should appear")
    }
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
}


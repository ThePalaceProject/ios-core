import XCTest

/// Feed refresh tests
/// Converted from: RefreshFeed.feature
final class RefreshFeedTests: XCTestCase {
  
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
  
  func testPullToRefreshCatalog() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    Thread.sleep(forTimeInterval: 2.0)
    
    // Pull to refresh
    app.swipeDown()
    Thread.sleep(forTimeInterval: 3.0)
    
    // Catalog should still be displayed
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.catalog].isSelected)
  }
  
  func testPullToRefreshMyBooks() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("My Books")
    Thread.sleep(forTimeInterval: 2.0)
    
    // Pull to refresh
    app.swipeDown()
    Thread.sleep(forTimeInterval: 3.0)
    
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.myBooks].isSelected)
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
}


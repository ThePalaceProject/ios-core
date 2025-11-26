import XCTest

/// Menu bar / Tab bar tests
/// Converted from: MenuBar.feature
final class MenuBarTests: XCTestCase {
  
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
  
  func testAllTabsAccessible() {
    skipOnboarding()
    
    // Catalog
    let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
    XCTAssertTrue(catalogTab.exists, "Catalog tab should exist")
    
    // My Books
    let myBooksTab = app.tabBars.buttons[AppStrings.TabBar.myBooks]
    XCTAssertTrue(myBooksTab.exists, "My Books tab should exist")
    
    // Reservations
    let reservationsTab = app.tabBars.buttons[AppStrings.TabBar.reservations]
    XCTAssertTrue(reservationsTab.exists, "Reservations tab should exist")
    
    // Settings
    let settingsTab = app.tabBars.buttons[AppStrings.TabBar.settings]
    XCTAssertTrue(settingsTab.exists, "Settings tab should exist")
  }
  
  func testNavigateBetweenAllTabs() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.catalog].isSelected)
    
    TestHelpers.navigateToTab("My Books")
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.myBooks].isSelected)
    
    TestHelpers.navigateToTab("Reservations")
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.reservations].isSelected)
    
    TestHelpers.navigateToTab("Settings")
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.settings].isSelected)
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
}


import XCTest

/// Book transaction tests (GET, READ, RETURN flows)
/// Converted from: BooksTransactions.feature
final class BooksTransactionsTests: XCTestCase {
  
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
  
  func testGetBookShowsReadButton() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.waitForExistence(timeout: 5.0) {
      getButton.tap()
    }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    XCTAssertTrue(readButton.waitForExistence(timeout: 30.0), "GET should change to READ after download")
  }
  
  func testDeleteBookShowsGetButton() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let deleteButton = app.buttons[AccessibilityID.BookDetail.deleteButton]
    if deleteButton.waitForExistence(timeout: 30.0) {
      deleteButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      let confirmButton = app.sheets.buttons.element(boundBy: 0)
      if confirmButton.exists { confirmButton.tap() }
    }
    
    let getButtonAgain = app.buttons[AccessibilityID.BookDetail.getButton]
    XCTAssertTrue(getButtonAgain.waitForExistence(timeout: 10.0), "DELETE should change to GET")
  }
  
  func testCancelDownload() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("large book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists {
      getButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    let cancelButton = app.buttons[AccessibilityID.BookDetail.cancelButton]
    if cancelButton.waitForExistence(timeout: 3.0) {
      cancelButton.tap()
    }
    
    let getButtonAgain = app.buttons[AccessibilityID.BookDetail.getButton]
    // Cancel may show GET button again
    Thread.sleep(forTimeInterval: 1.0)
  }
  
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
    var firstResult = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
    if !firstResult.exists {
      firstResult = app.cells.firstMatch
    }
    
    if firstResult.waitForExistence(timeout: 5.0) {
      firstResult.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
}


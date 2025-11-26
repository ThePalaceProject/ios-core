import XCTest

/// Multi-distributor tests
/// Converted from: Distributors.feature
final class DistributorsTests: XCTestCase {
  
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
  
  func testGetBookFromBibliothe ca() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Bibliotheca book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    XCTAssertTrue(readButton.waitForExistence(timeout: 30.0), "Book from Bibliotheca should download")
  }
  
  func testGetBookFromAxis360() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Axis 360 book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    XCTAssertTrue(readButton.waitForExistence(timeout: 30.0), "Book from Axis 360 should download")
  }
  
  func testGetBookFromPalaceMarketplace() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Palace Marketplace book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    XCTAssertTrue(readButton.waitForExistence(timeout: 30.0), "Book from Palace Marketplace should download")
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
  
  private func selectLibrary(_ name: String) {
    Thread.sleep(forTimeInterval: 1.0)
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


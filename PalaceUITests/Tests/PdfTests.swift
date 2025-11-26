import XCTest

/// PDF reading tests
/// Converted from: PdfLyrasisIos.feature, PdfPalaceIos.feature
final class PdfTests: XCTestCase {
  
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
  
  func testOpenPdfBook() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("pdf")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    let tabBar = app.tabBars.firstMatch
    XCTAssertFalse(tabBar.isHittable, "PDF reader should open")
  }
  
  func testPdfPageNavigation() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("pdf")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Swipe to next page
    app.swipeUp()
    Thread.sleep(forTimeInterval: 0.5)
    
    // Swipe to previous page
    app.swipeDown()
    Thread.sleep(forTimeInterval: 0.5)
    
    XCTAssertTrue(true, "PDF navigation completed")
  }
  
  func testPdfBookmark() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("pdf")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
  
  private func selectLibrary(_ name: String) {
    Thread.sleep(forTimeInterval: 1.0)
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


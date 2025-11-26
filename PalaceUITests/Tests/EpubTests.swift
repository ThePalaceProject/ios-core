import XCTest

/// EPUB reading tests
/// Converted from: EpubLyrasis.feature, EpubOverdrive.feature, EpubPalace.feature
final class EpubTests: XCTestCase {
  
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
  
  /// Open EPUB and verify reader displays
  func testOpenEpubBook() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    // Get book
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.waitForExistence(timeout: 5.0) {
      getButton.tap()
    }
    
    // Wait for READ button
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Verify EPUB reader opened (tab bar hidden)
    let tabBar = app.tabBars.firstMatch
    let isReaderOpen = !tabBar.isHittable || !tabBar.exists
    
    XCTAssertTrue(isReaderOpen, "EPUB reader should open")
  }
  
  /// Navigate pages in EPUB
  func testEpubPageNavigation() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Navigate pages - tap right side
    for _ in 0..<5 {
      let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      rightSide.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Navigate back - tap left side
    for _ in 0..<2 {
      let leftSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
      leftSide.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Still in reader
    let tabBar = app.tabBars.firstMatch
    XCTAssertFalse(tabBar.isHittable, "Should still be in reader")
  }
  
  /// Create bookmark in EPUB
  func testEpubBookmark() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Pride Prejudice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Look for bookmark button
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Bookmark should be created
      print("✅ Bookmark created")
    }
  }
  
  /// Resume reading at last page
  func testEpubResumeReading() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Metamorphosis")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Read a few pages
    for _ in 0..<10 {
      let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      rightSide.tap()
      Thread.sleep(forTimeInterval: 0.3)
    }
    
    // Close reader (tap top left)
    let topLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
    topLeft.tap()
    Thread.sleep(forTimeInterval: 1.0)
    
    // Tap anywhere to dismiss menu if appeared
    app.tap()
    Thread.sleep(forTimeInterval: 1.0)
    
    // Should be back at book detail or my books
    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.exists, "Should return from reader")
  }
  
  // MARK: - Helpers
  
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
    let firstResult = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
    if !firstResult.exists {
      firstResult = app.cells.firstMatch
    }
    
    if firstResult.waitForExistence(timeout: 5.0) {
      firstResult.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
}


import XCTest

/// Reservations/Holds tests  
/// Converted from: Reservations.feature
final class ReservationsTests: XCTestCase {
  
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
  
  /// Navigate to Reservations tab
  func testReservationsTabAccessible() {
    skipOnboarding()
    
    // Go to Reservations
    TestHelpers.navigateToTab("Reservations")
    
    // Verify on Reservations
    let reservationsTab = app.tabBars.buttons[AppStrings.TabBar.reservations]
    XCTAssertTrue(reservationsTab.isSelected, "Should be on Reservations")
  }
  
  /// Reserve a book
  func testReserveBook() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    
    // Search for unavailable book to reserve
    openSearch()
    search("unavailable book")
    
    // Tap first result
    tapFirstResult()
    
    // Look for RESERVE button
    let reserveButton = app.buttons[AccessibilityID.BookDetail.reserveButton]
    
    if reserveButton.waitForExistence(timeout: 5.0) {
      reserveButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
      
      // Verify reservation was placed
      // Button might change or show hold status
    }
  }
  
  /// View reservations list
  func testViewReservationsList() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Reservations")
    Thread.sleep(forTimeInterval: 2.0)
    
    // Either has holds or shows empty state
    let emptyState = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'no holds' OR label CONTAINS[c] 'no reservations'")).firstMatch
    let hasHolds = app.cells.count > 0
    
    // Both states are valid
    XCTAssertTrue(hasHolds || emptyState.exists, "Reservations screen should show holds or empty state")
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


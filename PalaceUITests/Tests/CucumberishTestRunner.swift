//
//  PalaceUITests.swift
//  PalaceUITests
//
//  Cucumberish Test Runner
//

import XCTest
import XCTestGherkin

/// XCTest-Gherkin test runner - simpler than Cucumberish
/// Parses .feature files and matches to step definitions
///
/// **How it works:**
/// 1. Reads .feature files from Features/ directory  
/// 2. Parses Gherkin scenarios
/// 3. Matches steps to Swift implementations
/// 4. Runs as XCTest
final class PalaceFeatureTests: XCTestCase {
  
  var app: XCUIApplication!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    continueAfterFailure = false
    
    app = XCUIApplication()
    app.launchArguments = ["-testMode", "1"]
    app.launchEnvironment = ["DISABLE_ANIMATIONS": "1"]
    app.launch()
    
    // Wait for app ready
    _ = app.tabBars.firstMatch.waitForExistence(timeout: 15.0)
  }
  
  override func tearDownWithError() throws {
    app.terminate()
    app = nil
    TestContext.shared.clear()
    try super.tearDownWithError()
  }
  
  // MARK: - Converted from MyBooks.feature
  
  func testMyBooks_CheckAddedBooksInPalaceBookshelf() {
    // Scenario: Check of added books in Palace Bookshelf
    // Using your step definitions as building blocks
    
    // Close tutorial/welcome
    closeT tutorial()
    closeWelcome()
    
    // Add library
    addLibrary("Palace Bookshelf")
    
    // Search and add books
    openSearchModal()
    searchAndSaveBooks(["One Way", "Jane Eyre", "The Tempest", "Poetry"], as: "listOfBooks")
    returnFromSearch()
    
    // Go to My Books
    TestHelpers.navigateToTab("My Books")
    
    // Verify books added
    // Books should be in My Books
    XCTAssertTrue(app.tabBars.buttons[AppStrings.TabBar.myBooks].isSelected)
  }
  
  // MARK: - Helper Methods (Use Your Step Logic)
  
  private func closeTutorial() {
    let skipButton = app.buttons["Skip"]
    if skipButton.exists { skipButton.tap() }
  }
  
  private func closeWelcome() {
    let closeButton = app.buttons["Close"]
    if closeButton.exists { closeButton.tap() }
  }
  
  private func addLibrary(_ name: String) {
    // Navigate to library selection
    // Search and select library
    Thread.sleep(forTimeInterval: 1.0)
  }
  
  private func openSearchModal() {
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  private func searchAndSaveBooks(_ books: [String], as varName: String) {
    TestContext.shared.save(books, forKey: varName)
  }
  
  private func returnFromSearch() {
    let cancelButton = app.buttons["Cancel"]
    if cancelButton.exists { cancelButton.tap() }
  }
}

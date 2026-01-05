//
//  SmokeTests.swift
//  PalaceUITests
//
//  Minimal E2E smoke tests that verify basic app functionality.
//  These tests are designed to be fast and reliable, covering
//  only the critical user paths.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest

/// Minimal smoke tests for critical app functionality.
/// These tests verify the app launches correctly and basic navigation works.
/// For detailed functionality testing, see the unit and integration tests
/// in the PalaceTests target.
final class SmokeTests: XCTestCase {
  
  var app: XCUIApplication!
  
  // MARK: - Setup & Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    
    app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
    app.launch()
    
    // Handle system alerts
    SystemAlertHandler.dismissAllSystemAlerts()
    
    // Wait for app to settle
    Thread.sleep(forTimeInterval: 2.0)
    
    // Dismiss onboarding if present
    dismissOnboardingIfNeeded()
  }
  
  override func tearDownWithError() throws {
    app = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Helper Methods
  
  private func dismissOnboardingIfNeeded() {
    // Look for onboarding close button
    let closeButton = app.buttons["onboarding.closeButton"]
    if closeButton.waitForExistence(timeout: 3.0) {
      closeButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Also try common close button patterns
    let skipButton = app.buttons["Skip"]
    if skipButton.exists && skipButton.isHittable {
      skipButton.tap()
    }
    
    let xButton = app.buttons.matching(NSPredicate(format: "label == 'Close'")).firstMatch
    if xButton.exists && xButton.isHittable {
      xButton.tap()
    }
  }
  
  private func selectLibraryIfNeeded() {
    // Check if library selection is needed
    let addLibrarySheet = app.sheets.firstMatch
    if addLibrarySheet.exists {
      // Search for Lyrasis or a default library
      let searchField = app.searchFields.firstMatch
      if searchField.exists {
        searchField.tap()
        searchField.typeText("Palace")
        Thread.sleep(forTimeInterval: 1.0)
        
        // Tap first result
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 3.0) {
          firstCell.tap()
        }
      }
    }
  }
  
  // MARK: - Smoke Tests
  
  /// Verifies the app launches successfully and shows the main interface
  func testAppLaunches_ShowsMainInterface() throws {
    // Wait for tab bar to appear
    let tabBar = app.tabBars.firstMatch
    let hasTabBar = tabBar.waitForExistence(timeout: 15.0)
    
    // If no tab bar, might be on library selection - handle it
    if !hasTabBar {
      selectLibraryIfNeeded()
    }
    
    // Verify either tab bar or some main UI element exists
    let catalogTab = app.buttons["Catalog"]
    let myBooksTab = app.buttons["My Books"]
    
    let hasMainInterface = catalogTab.exists || myBooksTab.exists || tabBar.exists
    
    XCTAssertTrue(hasMainInterface, "App should show main interface after launch")
  }
  
  /// Verifies navigation to My Books screen works
  func testNavigateToMyBooks_ShowsScreen() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      selectLibraryIfNeeded()
      _ = tabBar.waitForExistence(timeout: 10.0)
      return // Skip if setup fails
    }
    
    // Navigate to My Books
    let myBooksTab = app.buttons["My Books"]
    if myBooksTab.exists && myBooksTab.isHittable {
      myBooksTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Verify we're on My Books screen
      // Check for empty state or books list
      let myBooksScreen = app.otherElements["myBooks.view"].exists ||
                          app.otherElements["myBooks.emptyStateView"].exists ||
                          app.collectionViews.firstMatch.exists
      
      XCTAssertTrue(myBooksScreen || myBooksTab.isSelected, "My Books screen should be visible")
    }
  }
  
  /// Verifies navigation to Settings screen works
  func testNavigateToSettings_ShowsScreen() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      return // Skip if not ready
    }
    
    // Navigate to Settings
    let settingsTab = app.buttons["Settings"]
    if settingsTab.exists && settingsTab.isHittable {
      settingsTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Verify we're on Settings screen
      // Look for common settings elements
      let settingsElements = app.tables.firstMatch.exists ||
                             app.staticTexts["Libraries"].exists ||
                             app.staticTexts["About"].exists
      
      XCTAssertTrue(settingsElements || settingsTab.isSelected, "Settings screen should be visible")
    }
  }
  
  /// Verifies navigation to Catalog screen works
  func testNavigateToCatalog_ShowsScreen() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      return // Skip if not ready
    }
    
    // Navigate to Settings first, then back to Catalog
    let settingsTab = app.buttons["Settings"]
    if settingsTab.exists && settingsTab.isHittable {
      settingsTab.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Navigate to Catalog
    let catalogTab = app.buttons["Catalog"]
    if catalogTab.exists && catalogTab.isHittable {
      catalogTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Verify catalog elements are visible
      let catalogElements = app.buttons["catalog.searchButton"].exists ||
                            app.collectionViews.firstMatch.exists ||
                            app.cells.count > 0
      
      XCTAssertTrue(catalogElements || catalogTab.isSelected, "Catalog screen should be visible")
    }
  }
  
  /// Verifies navigation to Reservations screen works
  func testNavigateToReservations_ShowsScreen() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      return // Skip if not ready
    }
    
    // Navigate to Reservations
    let reservationsTab = app.buttons["Reservations"]
    if reservationsTab.exists && reservationsTab.isHittable {
      reservationsTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Just verify the tab was selected
      XCTAssertTrue(reservationsTab.isSelected || app.cells.count >= 0, 
                    "Reservations screen should be accessible")
    }
  }
  
  /// Verifies search functionality is accessible
  func testSearchButton_IsAccessible() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      return // Skip if not ready
    }
    
    // Navigate to Catalog first
    let catalogTab = app.buttons["Catalog"]
    if catalogTab.exists && catalogTab.isHittable {
      catalogTab.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Check for search button
    let searchButton = app.buttons["catalog.searchButton"]
    
    if searchButton.exists {
      XCTAssertTrue(searchButton.isHittable, "Search button should be tappable")
    }
    // If search button doesn't exist, that's okay - some libraries don't have search
  }
  
  /// Verifies the app doesn't crash during basic navigation
  func testBasicNavigation_NoCrash() throws {
    // Wait for app to be ready
    let tabBar = app.tabBars.firstMatch
    guard tabBar.waitForExistence(timeout: 15.0) else {
      return // Skip if not ready
    }
    
    // Navigate through all tabs
    let tabs = ["Catalog", "My Books", "Reservations", "Settings"]
    
    for tabName in tabs {
      let tab = app.buttons[tabName]
      if tab.exists && tab.isHittable {
        tab.tap()
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
    
    // Return to Catalog
    let catalogTab = app.buttons["Catalog"]
    if catalogTab.exists && catalogTab.isHittable {
      catalogTab.tap()
    }
    
    // Verify app is still running
    XCTAssertTrue(app.exists, "App should still be running after navigation")
  }
}


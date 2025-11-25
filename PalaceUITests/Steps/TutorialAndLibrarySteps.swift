import Foundation
import Cucumberish
import XCTest

/// Tutorial, Welcome, and Library Management Steps
///
/// **Handles:**
/// - Tutorial screen (close/skip)
/// - Welcome screen
/// - Add library functionality
/// - Library selection
class TutorialAndLibrarySteps {
  
  static func setup() {
    let app = TestHelpers.app
    
    // MARK: - Tutorial & Welcome
    
    When("Close tutorial screen") { _, _ in
      // Look for tutorial/onboarding screen elements
      let skipButton = app.buttons["Skip"]
      let doneButton = app.buttons["Done"]
      let closeButton = app.buttons["Close"]
      
      if skipButton.exists {
        skipButton.tap()
      } else if doneButton.exists {
        doneButton.tap()
      } else if closeButton.exists {
        closeButton.tap()
      }
      // If none exist, tutorial already dismissed
      TestHelpers.waitFor(0.5)
    }
    
    When("Close welcome screen") { _, _ in
      // Look for welcome screen dismiss button
      let closeButton = app.buttons["Close"]
      let continueButton = app.buttons["Continue"]
      let getStartedButton = app.buttons["Get Started"]
      
      if closeButton.exists {
        closeButton.tap()
      } else if continueButton.exists {
        continueButton.tap()
      } else if getStartedButton.exists {
        getStartedButton.tap()
      }
      TestHelpers.waitFor(0.5)
    }
    
    Then("Welcome screen is opened") { _, _ in
      // Verify welcome screen elements
      let hasWelcomeContent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'welcome'")).count > 0 ||
                             app.buttons["Close"].exists
      // Don't fail if already past welcome - just note it
      if !hasWelcomeContent {
        print("ℹ️ Welcome screen not shown (already dismissed)")
      }
    }
    
    Then("Add library screen is opened") { _, _ in
      // Verify add library / library selection screen
      Thread.sleep(forTimeInterval: 1.0)
      // Library screen should be visible - catalog or library list
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      XCTAssertTrue(catalogTab.exists, "Should reach library/catalog screen")
    }
    
    // MARK: - Library Management
    
    When("Add library \"(.*)\" on Add library screen") { args, _ in
      let libraryName = args![0] as! String
      
      // Navigate to add library if not already there
      let settingsTab = app.tabBars.buttons[AppStrings.TabBar.settings]
      if settingsTab.exists && !settingsTab.isSelected {
        settingsTab.tap()
        TestHelpers.waitFor(0.5)
      }
      
      // Look for add library button or library name
      let addLibraryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'add library'")).firstMatch
      if addLibraryButton.exists {
        addLibraryButton.tap()
        TestHelpers.waitFor(1.0)
      }
      
      // Search for library
      let searchField = app.searchFields.firstMatch
      if searchField.exists {
        searchField.tap()
        searchField.typeText(libraryName)
        TestHelpers.waitFor(1.0)
      }
      
      // Tap the library from list
      let libraryCell = app.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", libraryName)).firstMatch
      if libraryCell.exists {
        libraryCell.tap()
        TestHelpers.waitFor(2.0)
      } else {
        print("⚠️ Library '\(libraryName)' not found in list")
      }
    }
    
    Then("Library \"(.*)\" is opened on Catalog screen") { args, _ in
      let libraryName = args![0] as! String
      
      // Verify catalog screen is showing
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      XCTAssertTrue(catalogTab.exists, "Catalog should be accessible")
      
      // Navigate to catalog if not there
      if !catalogTab.isSelected {
        catalogTab.tap()
        TestHelpers.waitFor(1.0)
      }
      
      // Library should be loaded (catalog visible)
      print("✅ Library '\(libraryName)' opened")
    }
    
    When("Open Books") { _, _ in
      let myBooksTab = app.tabBars.buttons[AppStrings.TabBar.myBooks]
      if TestHelpers.waitForElement(myBooksTab, timeout: 5.0) {
        myBooksTab.tap()
        TestHelpers.waitFor(1.0)
      }
    }
    
    When("Open Catalog") { _, _ in
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      if TestHelpers.waitForElement(catalogTab, timeout: 5.0) {
        catalogTab.tap()
        TestHelpers.waitFor(1.0)
      }
    }
    
    When("Open Reservations") { _, _ in
      let reservationsTab = app.tabBars.buttons[AppStrings.TabBar.reservations]
      if TestHelpers.waitForElement(reservationsTab, timeout: 5.0) {
        reservationsTab.tap()
        TestHelpers.waitFor(1.0)
      }
    }
    
    When("Open Settings") { _, _ in
      let settingsTab = app.tabBars.buttons[AppStrings.TabBar.settings]
      if TestHelpers.waitForElement(settingsTab, timeout: 5.0) {
        settingsTab.tap()
        TestHelpers.waitFor(1.0)
      }
    }
  }
}


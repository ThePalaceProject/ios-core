import Foundation
import Cucumberish
import XCTest

/// Authentication and credentials steps
///
/// **Handles:**
/// - Signing in with library credentials
/// - Logout functionality
/// - Sync bookmarks activation
/// - Account verification
class AuthenticationSteps {
  
  static func setup() {
    let app = TestHelpers.app
    
    // MARK: - Sign In
    
    When("Enter credentials for '(.*)' library") { args, _ in
      let libraryName = args![0] as! String
      
      // Get credentials based on library
      let credentials: TestHelpers.TestCredentials
      
      switch libraryName.lowercased() {
      case let name where name.contains("lyrasis"):
        credentials = TestHelpers.TestCredentials.lyrasis
      default:
        credentials = TestHelpers.TestCredentials.lyrasis // fallback
      }
      
      // Find barcode/username field
      let barcodeField = app.textFields[AccessibilityID.SignIn.barcodeField]
      if !barcodeField.exists {
        // Try any text field with "barcode" or "username" label
        let anyBarcodeField = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'barcode' OR placeholderValue CONTAINS[c] 'username'")).firstMatch
        if anyBarcodeField.waitForExistence(timeout: 5.0) {
          anyBarcodeField.tap()
          anyBarcodeField.typeText(credentials.barcode)
        }
      } else {
        barcodeField.tap()
        barcodeField.typeText(credentials.barcode)
      }
      
      // Find PIN field
      let pinField = app.secureTextFields[AccessibilityID.SignIn.pinField]
      if !pinField.exists {
        let anyPinField = app.secureTextFields.firstMatch
        if anyPinField.waitForExistence(timeout: 3.0) {
          anyPinField.tap()
          anyPinField.typeText(credentials.pin)
        }
      } else {
        pinField.tap()
        pinField.typeText(credentials.pin)
      }
      
      // Tap sign in button
      let signInButton = app.buttons[AccessibilityID.SignIn.signInButton]
      if !signInButton.exists {
        let anySignInButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign in' OR label CONTAINS[c] 'log in'")).firstMatch
        if anySignInButton.exists {
          anySignInButton.tap()
        }
      } else {
        signInButton.tap()
      }
      
      // Wait for sign in to complete
      TestHelpers.waitFor(3.0)
    }
    
    When("Enter valid credentials fot \"(.*)\" library on Sign in screen") { args, _ in
      let libraryName = args![0] as! String
      
      // Same as "Enter credentials for" but with different wording
      let credentials = TestHelpers.TestCredentials.lyrasis
      
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
      }
      
      TestHelpers.waitFor(3.0)
    }
    
    Then("Login is performed successfully") { _, _ in
      // Wait for sign in to complete
      TestHelpers.waitFor(2.0)
      
      // Verify we're past sign in screen (catalog should be accessible)
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      XCTAssertTrue(catalogTab.exists, "Should be signed in and see catalog")
    }
    
    When("Activate sync bookmarks on Sign in screen") { _, _ in
      // Look for sync bookmarks toggle/checkbox
      let syncSwitch = app.switches.matching(NSPredicate(format: "label CONTAINS[c] 'sync' OR label CONTAINS[c] 'bookmark'")).firstMatch
      
      if syncSwitch.exists && !syncSwitch.isSelected {
        syncSwitch.tap()
        TestHelpers.waitFor(0.5)
      }
      // If already activated or doesn't exist, continue
    }
    
    // MARK: - Sign Out
    
    When("Click the log out button on the account screen") { _, _ in
      let signOutButton = app.buttons[AccessibilityID.Settings.signOutButton]
      if !signOutButton.exists {
        let anySignOutButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign out' OR label CONTAINS[c] 'log out'")).firstMatch
        if anySignOutButton.exists {
          anySignOutButton.tap()
          TestHelpers.waitFor(0.5)
          
          // Confirm if alert appears
          let confirmButton = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign out'")).firstMatch
          if confirmButton.exists {
            confirmButton.tap()
          }
        }
      } else {
        signOutButton.tap()
      }
    }
    
    // MARK: - App Lifecycle
    
    When("Restart app") { _, _ in
      let app = XCUIApplication()
      app.terminate()
      Thread.sleep(forTimeInterval: 2.0)
      app.launch()
      
      // Wait for app to be ready
      let tabBar = app.tabBars.firstMatch
      _ = tabBar.waitForExistence(timeout: 15.0)
    }
    
    // MARK: - Wait Steps
    
    When("Wait for (\\d+) seconds") { args, _ in
      let seconds = Int(args![0] as! String)!
      TestHelpers.waitFor(TimeInterval(seconds))
    }
  }
}


import XCTest

/// Dynamic authentication helper
/// Detects and handles sign-in screens automatically from any state
class AuthenticationHelper {
  
  /// Checks if currently on sign-in screen and signs in if needed
  /// Returns: true if signed in (or was already), false if failed
  @discardableResult
  static func signInIfNeeded(app: XCUIApplication) -> Bool {
    print("🔐 Checking authentication state...")
    
    // Check for sign-in indicators
    let barcodeField = app.textFields.matching(NSPredicate(format: "identifier != 'search.searchField' AND placeholderValue CONTAINS[c] 'barcode'")).firstMatch
    let pinField = app.secureTextFields.firstMatch
    let signInButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign in'")).firstMatch
    
    // If we see sign-in fields, we need to sign in
    if (barcodeField.exists || pinField.exists) && signInButton.exists {
      print("   Sign-in screen detected, authenticating...")
      
      let credentials = TestHelpers.TestCredentials.lyrasis
      
      // Enter barcode
      if let actualBarcodeField = findBarcodeField(app: app) {
        actualBarcodeField.tap()
        actualBarcodeField.typeText(credentials.barcode)
        print("   ✅ Entered barcode")
      } else {
        print("   ❌ Could not find barcode field")
        return false
      }
      
      // Enter PIN
      if pinField.waitForExistence(timeout: 2.0) {
        pinField.tap()
        pinField.typeText(credentials.pin)
        print("   ✅ Entered PIN")
      }
      
      // Submit
      if signInButton.exists {
        signInButton.tap()
        print("   ⏳ Submitting sign-in...")
        Thread.sleep(forTimeInterval: 5.0)
        
        // Verify signed in (catalog becomes accessible)
        let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
        if catalogTab.exists {
          print("✅ Sign-in successful!")
          return true
        } else {
          print("⚠️ Sign-in may have failed")
          return false
        }
      }
    }
    
    // Check if already signed in (catalog accessible)
    let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
    if catalogTab.exists {
      print("✅ Already signed in")
      return true
    }
    
    print("⚠️ Authentication state unclear")
    return false
  }
  
  /// Finds the actual barcode/username field (not search field)
  private static func findBarcodeField(app: XCUIApplication) -> XCUIElement? {
    // Try fields with "barcode" or "username" placeholder
    let barcodeField = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'barcode' OR placeholderValue CONTAINS[c] 'username'")).firstMatch
    
    if barcodeField.exists {
      return barcodeField
    }
    
    // Try fields that are NOT search field
    let nonSearchFields = app.textFields.allElementsBoundByIndex.filter { 
      $0.identifier != "search.searchField"
    }
    
    return nonSearchFields.first
  }
  
  /// Handles any modals/overlays that might appear after borrowing
  static func handleBorrowModals(app: XCUIApplication) {
    Thread.sleep(forTimeInterval: 2.0)
    
    // Check for library selector modal (select Lyrasis Reads if present)
    let lyrasisButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lyrasis'")).firstMatch
    let a1qaButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'A1QA'")).firstMatch
    
    if lyrasisButton.exists || a1qaButton.exists {
      print("ℹ️ Library picker appeared, selecting library...")
      
      // Prefer Lyrasis Reads (our test credentials work there)
      if lyrasisButton.exists {
        lyrasisButton.tap()
        print("   Selected: Lyrasis Reads")
        Thread.sleep(forTimeInterval: 2.0)
      } else {
        // Cancel if only A1QA available (we don't have those credentials)
        print("   Only A1QA available, but we need Lyrasis - cancelling...")
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists { cancelButton.tap(); Thread.sleep(forTimeInterval: 1.0) }
        return
      }
    }
    
    // Check for sign-in (HANDLE this)
    let signedIn = signInIfNeeded(app: app)
    
    if signedIn {
      print("✅ Authentication handled, continuing with borrow flow...")
      // DON'T dismiss anything - let the borrow/download continue!
      // The app will show book detail or download progress
      return
    }
    
    // Only dismiss unexpected modals if NOT signed in and not on book detail
    // Check if we're on book detail (has cover or title)
    let onBookDetail = app.images[AccessibilityID.BookDetail.coverImage].exists ||
                      app.staticTexts[AccessibilityID.BookDetail.title].exists
    
    if !onBookDetail {
      // Not on book detail - might be stuck on an error modal
      let closeButton = app.buttons["Close"]
      if closeButton.exists && !app.tabBars.firstMatch.isHittable {
        print("⚠️ Unexpected modal detected, closing...")
        closeButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
      }
    } else {
      print("✅ On book detail page, ready to download")
    }
  }
}


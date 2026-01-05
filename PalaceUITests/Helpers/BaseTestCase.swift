import XCTest

/// Base class for all UI test cases.
///
/// **AI-DEV GUIDE:**
/// - All test classes should inherit from this
/// - Provides common setup and teardown
/// - Manages app lifecycle and state
/// - Handles screenshots and error reporting
/// - Automatically handles system alerts (notifications, tracking, etc.)
/// - Handles first-launch flow (onboarding, library selection)
///
/// **EXAMPLE:**
/// ```swift
/// final class CatalogTests: BaseTestCase {
///     func testSearchForBook() {
///         let catalog = CatalogScreen(app: app)
///         catalog.tapSearchButton()
///         // ... test continues
///     }
/// }
/// ```
class BaseTestCase: XCTestCase {
  
  /// The main application instance
  var app: XCUIApplication!
  
  /// System alert handler for automatic dismissal of permission dialogs
  private var alertHandler: SystemAlertHandler!
  
  // MARK: - Setup & Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    // Stop immediately when a failure occurs
    continueAfterFailure = false
    
    // Setup system alert handlers BEFORE launching app
    // This automatically handles notification permissions, tracking dialogs, etc.
    alertHandler = setupSystemAlertHandling()
    
    // Initialize app
    app = XCUIApplication()
    
    // Configure launch arguments
    app.launchArguments = TestConfiguration.launchArguments
    app.launchEnvironment = TestConfiguration.launchEnvironment
    
    // Launch app
    app.launch()
    
    print("🚀 App launched, waiting for UI...")
    
    // Wait for app to be ready (handles first-launch flow)
    waitForAppToBeReady()
  }
  
  override func tearDownWithError() throws {
    // Take screenshot on failure
    if let testRun = testRun, testRun.hasSucceeded == false {
      takeScreenshot(named: "FAILURE-\(name)")
    }
    
    // Clean up alert handlers
    alertHandler?.removeAllHandlers()
    
    // Terminate app
    app.terminate()
    app = nil
    
    try super.tearDownWithError()
  }
  
  // MARK: - App State Management
  
  /// Waits for the app to complete initial launch and be ready for interaction
  /// Handles first-launch flow including onboarding and library selection
  private func waitForAppToBeReady() {
    // Give app time to initialize
    Thread.sleep(forTimeInterval: 3.0)
    
    // IMPORTANT: Directly dismiss any system alerts (notifications, tracking, etc.)
    // This is more reliable than interrupt monitors which require interaction first
    print("🔔 Checking for system alerts...")
    SystemAlertHandler.dismissAllSystemAlerts()
    
    // Also trigger any interrupt handlers we've set up
    triggerAlertHandlers()
    
    // ALWAYS check for onboarding FIRST - it may overlay the tab bar
    // The tab bar can exist in the view hierarchy but be covered by onboarding
    print("📱 Checking for onboarding overlay...")
    handleOnboarding()
    
    // Now check if we need library selection
    handleLibrarySelection()
    
    // Wait for app to settle
    Thread.sleep(forTimeInterval: 2.0)
    
    let tabBar = app.tabBars.firstMatch
    
    // Verify tab bar is actually usable (not just existing but covered)
    if tabBar.waitForExistence(timeout: 10.0) {
      // Check if a tab button is actually hittable
      let catalogTab = app.tabBars.buttons["Catalog"]
      if catalogTab.exists && catalogTab.isHittable {
        print("✅ Tab bar found and hittable - app is ready")
        return
      } else {
        print("⚠️ Tab bar exists but not hittable - onboarding may still be showing")
        // Try onboarding again
        handleOnboarding()
        Thread.sleep(forTimeInterval: 2.0)
      }
    }
    
    // Final check
    if !tabBar.waitForExistence(timeout: 30.0) {
      print("⚠️ Warning: Tab bar still not visible after setup")
      debugPrintCurrentScreen()
    } else {
      print("✅ App ready after first-launch setup")
    }
  }
  
  /// Triggers any pending system alert handlers by interacting with the app
  private func triggerAlertHandlers() {
    let safePoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    safePoint.tap()
    Thread.sleep(forTimeInterval: 0.5)
  }
  
  /// Handles onboarding/tutorial screens
  /// The Palace onboarding shows image slides with an X button in top-right corner
  /// IMPORTANT: Always tries to dismiss onboarding even if not explicitly detected,
  /// because the tab bar can exist behind the onboarding overlay
  private func handleOnboarding() {
    print("   Checking for onboarding screens...")
    
    // Give onboarding time to appear
    Thread.sleep(forTimeInterval: 2.0)
    
    // Check if we're on the onboarding screen
    let onboardingTitle = app.staticTexts["Getting Started with Palace"]
    let step1Text = app.staticTexts["Step 1"]
    let findLibraryText = app.staticTexts["Find Your Library"]
    let palaceProjectText = app.staticTexts["The Palace Project"]
    
    let isOnOnboarding = onboardingTitle.exists || step1Text.exists || findLibraryText.exists || palaceProjectText.exists
    
    // Debug: print visible static texts
    let allTexts = app.staticTexts.allElementsBoundByIndex.prefix(10).map { $0.label }
    print("   Visible texts: \(allTexts)")
    
    // Debug: print visible buttons
    let allButtons = app.buttons.allElementsBoundByIndex.prefix(15).map { 
      "[\($0.identifier)|\($0.label)|\($0.isHittable)]" 
    }
    print("   Visible buttons: \(allButtons)")
    
    if isOnOnboarding {
      print("   ✅ Detected onboarding screen")
    } else {
      // Even if not detected, still try coordinate tap in case accessibility isn't working
      print("   ⚠️ Onboarding text not detected, but will try coordinate tap anyway")
    }
    
    // The onboarding X button - try multiple approaches
    
    // Method 1: By accessibility identifier (most reliable after app update)
    let onboardingCloseButton = app.buttons[AccessibilityID.Onboarding.closeButton]
    
    // Method 2: By SF Symbol name
    let xCircleFillButton = app.buttons["xmark.circle.fill"]
    
    // Method 3: By accessibility label "Close"
    let closeButton = app.buttons["Close"]
    
    // Method 4: Any close-related button
    let closeByLabel = app.buttons.matching(NSPredicate(format: "label ==[c] 'Close'")).firstMatch
    
    var dismissed = false
    
    // Try each dismiss option (in order of likelihood)
    if onboardingCloseButton.waitForExistence(timeout: 2.0) {
      print("   ✅ Found onboarding close button by identifier")
      if onboardingCloseButton.isHittable {
        onboardingCloseButton.tap()
      } else {
        onboardingCloseButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      }
      dismissed = true
      Thread.sleep(forTimeInterval: 1.0)
    } else if xCircleFillButton.waitForExistence(timeout: 2.0) {
      print("   ✅ Found xmark.circle.fill button, tapping...")
      if xCircleFillButton.isHittable {
        xCircleFillButton.tap()
      } else {
        xCircleFillButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      }
      dismissed = true
      Thread.sleep(forTimeInterval: 1.0)
    } else if closeButton.exists {
      print("   ✅ Found Close button, tapping...")
      if closeButton.isHittable {
        closeButton.tap()
      } else {
        closeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      }
      dismissed = true
      Thread.sleep(forTimeInterval: 1.0)
    } else if closeByLabel.exists {
      print("   ✅ Found button with Close label, tapping...")
      closeByLabel.tap()
      dismissed = true
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // ALWAYS try coordinate taps for the X button location
    // The X button is in the top-right corner on the blue onboarding screen
    if !dismissed || isOnOnboarding {
      print("   🎯 Trying coordinate taps for X button in top-right corner...")
      
      // Try multiple positions where the X might be based on different screen sizes
      // The X is a gray circle in the top-right on blue background
      let positions = [
        CGVector(dx: 0.94, dy: 0.04),   // Top right for notch devices
        CGVector(dx: 0.95, dy: 0.05),   // Slightly different position
        CGVector(dx: 0.92, dy: 0.06),   // For devices with different safe areas
        CGVector(dx: 0.90, dy: 0.07),   // More conservative
        CGVector(dx: 0.94, dy: 0.08),   // Lower position
        CGVector(dx: 0.93, dy: 0.03),   // Very top
      ]
      
      for (index, pos) in positions.enumerated() {
        let coord = app.coordinate(withNormalizedOffset: pos)
        print("   Tapping position \(index + 1): (\(pos.dx), \(pos.dy))")
        coord.tap()
        Thread.sleep(forTimeInterval: 0.8)
        
        // Check if onboarding dismissed (catalog tab becomes hittable)
        let catalogTab = app.tabBars.buttons["Catalog"]
        if catalogTab.exists && catalogTab.isHittable {
          print("   ✅ Onboarding dismissed - Catalog tab now hittable!")
          break
        }
        
        // Also check if onboarding text disappeared
        if !onboardingTitle.exists && !step1Text.exists && !palaceProjectText.exists {
          print("   ✅ Onboarding text no longer visible!")
          break
        }
      }
      
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Skip tutorial if present (after dismissing initial onboarding)
    if app.buttons["Skip"].waitForExistence(timeout: 2.0) {
      print("   Skipping tutorial...")
      app.buttons["Skip"].tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Get Started / Continue
    let continueButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Get Started' OR label CONTAINS[c] 'Continue'")).firstMatch
    if continueButton.exists {
      print("   Tapping Continue...")
      continueButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Trigger any alerts that appeared
    triggerAlertHandlers()
  }
  
  /// Handles library selection screen (shown on first launch)
  private func handleLibrarySelection() {
    print("   Checking for library selection...")
    
    let tableView = app.tables.firstMatch
    let searchBar = app.searchFields.firstMatch
    
    // If we see a table with search, we're on library selection
    if tableView.waitForExistence(timeout: 3.0) {
      print("   Library selection screen found...")
      
      // Search for Lyrasis Reads
      if searchBar.exists {
        searchBar.tap()
        searchBar.typeText("Lyrasis")
        Thread.sleep(forTimeInterval: 2.0)
      }
      
      // Select Lyrasis Reads
      let lyrasisCell = app.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Lyrasis Reads'")).firstMatch
      if lyrasisCell.waitForExistence(timeout: 5.0) {
        print("   Selecting Lyrasis Reads...")
        lyrasisCell.tap()
        Thread.sleep(forTimeInterval: 3.0)
      } else {
        // Try any Lyrasis cell
        let anyLyrasis = app.cells.matching(NSPredicate(format: "label CONTAINS[c] 'Lyrasis'")).firstMatch
        if anyLyrasis.exists {
          anyLyrasis.tap()
          Thread.sleep(forTimeInterval: 3.0)
        } else {
          print("   ⚠️ Could not find Lyrasis library")
        }
      }
    }
  }
  
  /// Prints debug info about current screen state
  private func debugPrintCurrentScreen() {
    let buttons = app.buttons.allElementsBoundByIndex.prefix(10).map { $0.label }
    let texts = app.staticTexts.allElementsBoundByIndex.prefix(10).map { $0.label }
    print("   DEBUG - Buttons: \(buttons)")
    print("   DEBUG - Texts: \(texts)")
  }
  
  /// Resets app to a known state
  /// - Parameter signOut: Whether to sign out if user is signed in
  func resetAppState(signOut: Bool = true) {
    // Navigate to settings
    app.tabBars.buttons[AccessibilityID.TabBar.settingsTab].tap()
    
    if signOut {
      // Sign out if needed
      let signOutButton = app.buttons[AccessibilityID.Settings.signOutButton]
      if signOutButton.waitForExistence(timeout: 2.0) {
        signOutButton.tap()
        
        // Confirm sign out if alert appears
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2.0) {
          alert.buttons["Sign Out"].tap()
        }
      }
    }
    
    // Navigate back to catalog
    app.tabBars.buttons[AppStrings.TabBar.catalog].tap()
  }
  
  /// Navigates to a specific tab
  /// - Parameter tab: The tab to navigate to
  func navigateToTab(_ tab: AppTab) {
    // Use localized strings from app (single source of truth)
    let tabLabel: String
    
    switch tab {
    case .catalog:
      tabLabel = AppStrings.TabBar.catalog
    case .myBooks:
      tabLabel = AppStrings.TabBar.myBooks
    case .holds:
      tabLabel = AppStrings.TabBar.reservations
    case .settings:
      tabLabel = AppStrings.TabBar.settings
    }
    
    let tabButton = app.tabBars.buttons[tabLabel]
    XCTAssertTrue(tabButton.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "Tab button '\(tabLabel)' not found")
    tabButton.tap()
  }
  
  // MARK: - Authentication Helpers
  
  /// Signs in with test credentials
  /// - Parameters:
  ///   - credentials: Test credentials to use
  ///   - fromSettings: Whether to start sign-in from settings (default: true)
  func signIn(with credentials: TestConfiguration.TestCredentials, fromSettings: Bool = true) {
    if fromSettings {
      navigateToTab(.settings)
      
      let signInButton = app.buttons[AccessibilityID.Settings.signInButton]
      XCTAssertTrue(signInButton.waitForExistence(timeout: TestConfiguration.uiTimeout),
                    "Sign in button not found")
      signInButton.tap()
    }
    
    // Fill credentials
    let barcodeField = app.textFields[AccessibilityID.SignIn.barcodeField]
    XCTAssertTrue(barcodeField.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "Barcode field not found")
    barcodeField.tap()
    barcodeField.typeText(credentials.barcode)
    
    let pinField = app.secureTextFields[AccessibilityID.SignIn.pinField]
    XCTAssertTrue(pinField.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "PIN field not found")
    pinField.tap()
    pinField.typeText(credentials.pin)
    
    // Submit
    let submitButton = app.buttons[AccessibilityID.SignIn.signInButton]
    XCTAssertTrue(submitButton.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "Submit button not found")
    submitButton.tap()
    
    // Wait for sign in to complete
    waitForSignInToComplete()
  }
  
  /// Waits for sign in process to complete
  private func waitForSignInToComplete() {
    // Sign in is complete when we see the signed-in state in settings
    // or when the catalog loads (depending on flow)
    let accountName = app.staticTexts[AccessibilityID.Settings.accountName]
    _ = accountName.waitForExistence(timeout: TestConfiguration.networkTimeout)
  }
  
  // MARK: - Book Helpers
  
  /// Searches for a book in the catalog
  /// - Parameter searchTerm: The search query
  /// - Returns: Search screen instance
  @discardableResult
  func searchForBook(_ searchTerm: String) -> SearchScreen {
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText(searchTerm)
    return search
  }
  
  /// Finds and taps the first book in search results
  /// - Parameter searchTerm: What to search for
  /// - Returns: true if book was found and tapped
  @discardableResult
  func findAndSelectBook(_ searchTerm: String) -> Bool {
    let search = searchForBook(searchTerm)
    return search.tapFirstResult() != nil
  }
  
  // MARK: - Wait Helpers
  
  /// Waits for a specific amount of time
  /// - Parameter seconds: Time to wait
  func waitFor(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
  }
  
  /// Waits for an element to exist
  /// - Parameters:
  ///   - element: Element to wait for
  ///   - timeout: Maximum wait time
  ///   - message: Custom failure message
  @discardableResult
  func waitForElement(_ element: XCUIElement,
                      timeout: TimeInterval = TestConfiguration.uiTimeout,
                      message: String? = nil) -> Bool {
    let exists = element.waitForExistence(timeout: timeout)
    if !exists {
      XCTFail(message ?? "Element \(element) did not appear within \(timeout) seconds")
    }
    return exists
  }
  
  // MARK: - Screenshot Helpers
  
  /// Takes a screenshot with a descriptive name
  /// - Parameter name: Description for the screenshot
  func takeScreenshot(named name: String) {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(self.name)-\(name)"
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: name) { activity in
      activity.add(attachment)
    }
  }
  
  // MARK: - Assertion Helpers
  
  /// Asserts that an element exists
  /// - Parameters:
  ///   - element: Element to check
  ///   - timeout: Maximum wait time
  ///   - message: Custom failure message
  func assertExists(_ element: XCUIElement,
                   timeout: TimeInterval = TestConfiguration.uiTimeout,
                   message: String? = nil) {
    XCTAssertTrue(
      element.waitForExistence(timeout: timeout),
      message ?? "Expected element to exist: \(element)"
    )
  }
  
  /// Asserts that an element does not exist
  /// - Parameters:
  ///   - element: Element to check
  ///   - timeout: Maximum wait time to verify non-existence
  ///   - message: Custom failure message
  func assertNotExists(_ element: XCUIElement,
                      timeout: TimeInterval = TestConfiguration.shortTimeout,
                      message: String? = nil) {
    // Wait a moment to ensure element doesn't appear
    Thread.sleep(forTimeInterval: timeout)
    XCTAssertFalse(
      element.exists,
      message ?? "Expected element to not exist: \(element)"
    )
  }
}

// MARK: - App Tab Enum

/// App tabs for navigation
enum AppTab {
  case catalog
  case myBooks
  case holds
  case settings
}

// Screen objects are imported from their respective files:
// - CatalogScreen.swift
// - SearchScreen.swift
// - BookDetailScreen.swift
// - MyBooksScreen.swift


import XCTest

/// Base class for all UI test cases.
///
/// **AI-DEV GUIDE:**
/// - All test classes should inherit from this
/// - Provides common setup and teardown
/// - Manages app lifecycle and state
/// - Handles screenshots and error reporting
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
  
  // MARK: - Setup & Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    // Stop immediately when a failure occurs
    continueAfterFailure = false
    
    // Initialize app
    app = XCUIApplication()
    
    // Configure launch arguments
    app.launchArguments = TestConfiguration.launchArguments
    app.launchEnvironment = TestConfiguration.launchEnvironment
    
    // Launch app
    app.launch()
    
    // Wait for app to be ready
    waitForAppToBeReady()
  }
  
  override func tearDownWithError() throws {
    // Take screenshot on failure
    if let testRun = testRun, testRun.hasSucceeded == false {
      takeScreenshot(named: "FAILURE-\(name)")
    }
    
    // Terminate app
    app.terminate()
    app = nil
    
    try super.tearDownWithError()
  }
  
  // MARK: - App State Management
  
  /// Waits for the app to complete initial launch and be ready for interaction
  private func waitForAppToBeReady() {
    // Wait for tab bar to appear (indicates app is ready)
    let tabBar = app.tabBars.firstMatch
    _ = tabBar.waitForExistence(timeout: TestConfiguration.networkTimeout)
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


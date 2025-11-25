import XCTest

/// Shared test helpers and utilities
class TestHelpers {
  
  /// Shared app instance
  static var app: XCUIApplication {
    XCUIApplication()
  }
  
  // MARK: - Navigation
  
  /// Navigates to a specific tab
  static func navigateToTab(_ tabName: String) {
    let app = XCUIApplication()
    
    // Use localized strings from app (single source of truth)
    let tabLabel: String
    
    switch tabName.lowercased() {
    case "catalog", "browse":
      tabLabel = AppStrings.TabBar.catalog
    case "my books", "mybooks", "library":
      tabLabel = AppStrings.TabBar.myBooks
    case "holds", "reservations":
      tabLabel = AppStrings.TabBar.reservations
    case "settings":
      tabLabel = AppStrings.TabBar.settings
    default:
      XCTFail("Unknown tab: \(tabName)")
      return
    }
    
    // Find tab button by localized label
    let tabButton = app.tabBars.buttons[tabLabel]
    if tabButton.waitForExistence(timeout: 5.0) {
      tabButton.tap()
    } else {
      XCTFail("Tab '\(tabLabel)' not found")
    }
  }
  
  // MARK: - Wait Helpers
  
  /// Waits for a fixed time period
  /// ⚠️ Use sparingly - prefer waitForElement() or waitForCondition()
  static func waitFor(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }
  
  /// Waits for element to exist (PREFERRED over fixed waits)
  @discardableResult
  static func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    element.waitForExistence(timeout: timeout)
  }
  
  /// Waits for element to disappear (PREFERRED over fixed waits)
  @discardableResult
  static func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
  }
  
  /// Waits for a condition to be true (PREFERRED over fixed waits)
  /// - Parameters:
  ///   - timeout: Maximum time to wait
  ///   - condition: Closure that returns true when condition is met
  /// - Returns: true if condition was met within timeout
  @discardableResult
  static func waitForCondition(timeout: TimeInterval = 5.0, _ condition: () -> Bool) -> Bool {
    let startTime = Date()
    
    while Date().timeIntervalSince(startTime) < timeout {
      if condition() {
        return true
      }
      Thread.sleep(forTimeInterval: 0.1) // Small sleep to avoid busy-waiting
    }
    
    return false
  }
  
  /// Waits for element to be hittable (not just exist)
  @discardableResult
  static func waitForElementToBeHittable(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    waitForCondition(timeout: timeout) {
      element.exists && element.isHittable
    }
  }
  
  // MARK: - Time Parsing
  
  /// Parses time label (e.g., "12:34" or "1:23:45") to seconds
  static func parseTimeLabel(_ label: String) -> TimeInterval {
    let components = label.split(separator: ":").compactMap { Int($0) }
    
    switch components.count {
    case 2: // MM:SS
      return TimeInterval(components[0] * 60 + components[1])
    case 3: // HH:MM:SS
      return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
    default:
      return 0
    }
  }
  
  // MARK: - Screenshots
  
  static func takeScreenshot(named name: String) {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: name) { activity in
      activity.add(attachment)
    }
  }
  
  // MARK: - Test Credentials
  
  struct TestCredentials {
    let barcode: String
    let pin: String
    
    static var lyrasis: TestCredentials {
      TestCredentials(
        barcode: ProcessInfo.processInfo.environment["LYRASIS_BARCODE"] ?? "01230000000002",
        pin: ProcessInfo.processInfo.environment["LYRASIS_PIN"] ?? "Lyrtest123"
      )
    }
  }
}

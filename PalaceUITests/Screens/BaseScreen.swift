import XCTest

/// Base protocol for all screen objects in UI tests.
///
/// **AI-DEV GUIDE:**
/// - All screen objects should conform to this protocol
/// - Provides common app reference and wait utilities
/// - Use descriptive property names for UI elements
/// - Add screen-specific actions as methods
///
/// **EXAMPLE:**
/// ```swift
/// class CatalogScreen: BaseScreen {
///     var searchButton: XCUIElement {
///         app.buttons[AccessibilityID.Catalog.searchButton]
///     }
///     
///     @discardableResult
///     func tapSearchButton() -> SearchScreen {
///         searchButton.tap()
///         return SearchScreen(app: app)
///     }
/// }
/// ```
protocol BaseScreen {
  /// Reference to the XCUIApplication instance
  var app: XCUIApplication { get }
  
  /// Verifies the screen is currently displayed
  /// - Parameter timeout: Maximum time to wait for screen to appear (default: 5 seconds)
  /// - Returns: true if screen is visible, false otherwise
  @discardableResult
  func isDisplayed(timeout: TimeInterval) -> Bool
}

extension BaseScreen {
  /// Default timeout for element waits (5 seconds)
  var defaultTimeout: TimeInterval { 5.0 }
  
  /// Short timeout for quick checks (2 seconds)
  var shortTimeout: TimeInterval { 2.0 }
  
  /// Long timeout for network operations (15 seconds)
  var longTimeout: TimeInterval { 15.0 }
  
  /// Waits for an element to exist
  /// - Parameters:
  ///   - element: The UI element to wait for
  ///   - timeout: Maximum wait time
  /// - Returns: true if element exists within timeout
  @discardableResult
  func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    element.waitForExistence(timeout: timeout)
  }
  
  /// Waits for an element to disappear
  /// - Parameters:
  ///   - element: The UI element to wait to disappear
  ///   - timeout: Maximum wait time
  /// - Returns: true if element disappeared within timeout
  @discardableResult
  func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
  }
  
  /// Safely taps an element, waiting for it to exist first
  /// - Parameters:
  ///   - element: The element to tap
  ///   - timeout: Maximum wait time before tap
  /// - Returns: true if element was tapped successfully
  @discardableResult
  func safeTap(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
    guard waitForElement(element, timeout: timeout) else {
      XCTFail("Element \(element) not found within \(timeout) seconds")
      return false
    }
    element.tap()
    return true
  }
  
  /// Scrolls to find and tap an element
  /// - Parameters:
  ///   - element: The element to find and tap
  ///   - scrollView: The scroll view to scroll within
  /// - Returns: true if element was found and tapped
  @discardableResult
  func scrollAndTap(_ element: XCUIElement, in scrollView: XCUIElement? = nil) -> Bool {
    let container = scrollView ?? app.scrollViews.firstMatch
    
    // Try direct tap first
    if element.exists && element.isHittable {
      element.tap()
      return true
    }
    
    // Scroll up to find element
    for _ in 0..<10 {
      if element.exists && element.isHittable {
        element.tap()
        return true
      }
      container.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
    
    XCTFail("Could not find element \(element) after scrolling")
    return false
  }
  
  /// Takes a screenshot with a descriptive name
  /// - Parameter name: Description for the screenshot
  func takeScreenshot(named name: String) {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: name) { activity in
      activity.add(attachment)
    }
  }
}

/// Concrete base class for screens that need state management
class ScreenObject: BaseScreen {
  let app: XCUIApplication
  
  init(app: XCUIApplication) {
    self.app = app
  }
  
  /// Default implementation - override in subclasses with screen-specific logic
  @discardableResult
  func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    // Subclasses should override this with their specific verification logic
    return true
  }
}


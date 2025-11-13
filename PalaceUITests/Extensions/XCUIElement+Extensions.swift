import XCTest

/// Extensions to make XCUIElement more expressive and easier to use in tests.
///
/// **AI-DEV GUIDE:**
/// - Use these extensions to make test code more readable
/// - Add new extensions here when you find repetitive patterns
/// - Keep extensions focused and single-purpose
extension XCUIElement {
  
  /// Clears existing text and types new text
  /// Useful for text fields and search bars
  func clearAndType(_ text: String) {
    guard exists else {
      XCTFail("Cannot clear and type - element does not exist")
      return
    }
    
    tap()
    
    // Select all and delete (works on both iOS simulators and devices)
    if let currentValue = value as? String, !currentValue.isEmpty {
      // Double tap to select word, then select all
      doubleTap()
      
      // Try to use "Select All" menu item if available
      let selectAllMenuItem = app.menuItems["Select All"]
      if selectAllMenuItem.waitForExistence(timeout: 1.0) {
        selectAllMenuItem.tap()
      }
      
      // Delete selected text
      app.keys["delete"].tap()
    }
    
    typeText(text)
  }
  
  /// Checks if element exists and is hittable
  var existsAndIsHittable: Bool {
    exists && isHittable
  }
  
  /// Checks if element is fully visible on screen
  var isFullyVisible: Bool {
    guard exists else { return false }
    return frame.minX >= 0 &&
           frame.minY >= 0 &&
           frame.maxX <= app.frame.maxX &&
           frame.maxY <= app.frame.maxY
  }
  
  /// Taps the element and waits briefly for the action to process
  /// - Parameter delay: Time to wait after tap (default: 0.5 seconds)
  func tapAndWait(delay: TimeInterval = 0.5) {
    tap()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: delay))
  }
  
  /// Force tap at element's coordinate (useful when element is not directly tappable)
  func forceTap() {
    coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }
  
  /// Swipes element in a specific direction
  /// - Parameter direction: The direction to swipe
  func swipe(_ direction: SwipeDirection) {
    switch direction {
    case .up:
      swipeUp()
    case .down:
      swipeDown()
    case .left:
      swipeLeft()
    case .right:
      swipeRight()
    }
  }
  
  /// Returns text content from label or button
  var textValue: String {
    (value as? String) ?? label
  }
  
  /// Waits for element to be hittable (not just exist)
  /// - Parameter timeout: Maximum wait time
  /// - Returns: true if element is hittable within timeout
  @discardableResult
  func waitToBeHittable(timeout: TimeInterval = 5.0) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
  }
  
  /// Waits for element's enabled state to change
  /// - Parameters:
  ///   - enabled: Expected enabled state
  ///   - timeout: Maximum wait time
  /// - Returns: true if state changed within timeout
  @discardableResult
  func waitForEnabled(_ enabled: Bool, timeout: TimeInterval = 5.0) -> Bool {
    let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled))
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
  }
  
  /// Scrolls within element until a child element is visible
  /// - Parameters:
  ///   - element: Child element to find
  ///   - maxScrolls: Maximum number of scroll attempts
  /// - Returns: true if child element found
  @discardableResult
  func scrollUntilVisible(_ element: XCUIElement, maxScrolls: Int = 10) -> Bool {
    for _ in 0..<maxScrolls {
      if element.exists && element.isHittable {
        return true
      }
      swipeUp()
    }
    return false
  }
  
  /// Gets the app instance for this element
  private var app: XCUIApplication {
    // Navigate up to find XCUIApplication
    var current: XCUIElement = self
    while let parent = current as? XCUIApplication {
      return parent
    }
    // Fallback: create new instance
    return XCUIApplication()
  }
}

/// Swipe direction enum for cleaner API
enum SwipeDirection {
  case up, down, left, right
}

// MARK: - Query Extensions

extension XCUIElementQuery {
  /// Returns the first element that matches a predicate
  /// - Parameter predicate: The matching condition
  /// - Returns: First matching element or nil
  func first(where predicate: (XCUIElement) -> Bool) -> XCUIElement? {
    allElementsBoundByIndex.first(where: predicate)
  }
  
  /// Filters elements by a predicate
  /// - Parameter predicate: The filtering condition
  /// - Returns: Array of matching elements
  func filter(_ predicate: (XCUIElement) -> Bool) -> [XCUIElement] {
    allElementsBoundByIndex.filter(predicate)
  }
  
  /// Returns all elements as an array
  var allElements: [XCUIElement] {
    allElementsBoundByIndex
  }
}

// MARK: - Accessibility Helpers

extension XCUIElement {
  /// Finds a descendant by accessibility identifier
  /// - Parameter identifier: The accessibility identifier to search for
  /// - Returns: The matching element
  func descendant(withIdentifier identifier: String) -> XCUIElement {
    descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
  
  /// Finds all descendants matching a type
  /// - Parameter type: The element type to search for
  /// - Returns: Query of matching elements
  func descendants(ofType type: XCUIElement.ElementType) -> XCUIElementQuery {
    descendants(matching: type)
  }
}


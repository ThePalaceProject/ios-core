import XCTest

extension XCUIElement {
  @discardableResult
  func waitForExistence(timeout: TimeInterval = 10) -> Bool {
    waitForExistence(timeout: timeout)
  }

  func waitAndTap(timeout: TimeInterval = 10, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(
      waitForExistence(timeout: timeout),
      "Element \(self) did not appear within \(timeout)s",
      file: file,
      line: line
    )
    tap()
  }

  func waitForText(_ text: String, timeout: TimeInterval = 10, file: StaticString = #file, line: UInt = #line) {
    let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    XCTAssertEqual(
      result,
      .completed,
      "Element did not contain text '\(text)' within \(timeout)s",
      file: file,
      line: line
    )
  }

  var isVisible: Bool {
    exists && isHittable
  }

  func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    return result == .completed
  }
}

extension XCUIApplication {
  func waitForActivity(timeout: TimeInterval = 10) {
    let spinner = activityIndicators.firstMatch
    if spinner.exists {
      let gone = spinner.waitForNonExistence(timeout: timeout)
      XCTAssertTrue(gone, "Activity indicator still visible after \(timeout)s")
    }
  }
}

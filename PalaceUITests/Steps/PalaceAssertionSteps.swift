import Foundation
import Cucumberish
import XCTest

class PalaceAssertionSteps {
  static func setup() {
    let app = TestHelpers.app
    
    Then("I should see \"(.*)\"") { args, _ in
      let expectedText = args![0] as! String
      let predicate = NSPredicate(format: "label CONTAINS[c] %@", expectedText)
      let matchingElements = app.staticTexts.matching(predicate)
      XCTAssertGreaterThan(matchingElements.count, 0, "Should see text: '\(expectedText)'")
    }
    
    Then("the app should launch") { _, _ in
      let tabBar = app.tabBars.firstMatch
      XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0), "App should launch")
    }
    
    Then("the app should be ready") { _, _ in
      TestHelpers.waitFor(2.0)
      let tabBar = app.tabBars.firstMatch
      XCTAssertTrue(tabBar.exists, "App should be ready")
    }
    
    Then("the library logo should be displayed") { _, _ in
      let logo = app.images[AccessibilityID.Catalog.libraryLogo]
      XCTAssertTrue(logo.waitForExistence(timeout: 10.0), "Library logo should be displayed")
    }
    
    And("I wait (\\d+) (second|seconds)") { args, _ in
      let seconds = Int(args![0] as! String)!
      TestHelpers.waitFor(TimeInterval(seconds))
    }
    
    And("I take a screenshot named \"(.*)\"") { args, _ in
      let name = args![0] as! String
      TestHelpers.takeScreenshot(named: name)
    }
    
    And("I take a screenshot") { _, _ in
      TestHelpers.takeScreenshot(named: "screenshot-\(Date().timeIntervalSince1970)")
    }
  }
}

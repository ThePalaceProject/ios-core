import Foundation
import Cucumberish
import XCTest

class PalaceNavigationSteps {
  static func setup() {
    let app = TestHelpers.app
    
    Given("I am on the (Catalog|My Books|Settings|Holds) screen") { args, _ in
      let screenName = args![0] as! String
      TestHelpers.navigateToTab(screenName)
      TestHelpers.waitFor(1.0)
    }
    
    When("I navigate to (Catalog|My Books|Settings|Holds)") { args, _ in
      let screenName = args![0] as! String
      TestHelpers.navigateToTab(screenName)
      TestHelpers.waitFor(1.0)
    }
    
    When("I tap the back button") { _, _ in
      let backButton = app.navigationBars.buttons.element(boundBy: 0)
      if backButton.exists {
        backButton.tap()
      }
    }
    
    Then("I should be on the (Catalog|My Books|Settings|Holds) screen") { args, _ in
      let screenName = args![0] as! String
      
      // Use localized strings (single source of truth)
      let tabLabel: String
      
      switch screenName.lowercased() {
      case "catalog": tabLabel = AppStrings.TabBar.catalog
      case "my books": tabLabel = AppStrings.TabBar.myBooks
      case "settings": tabLabel = AppStrings.TabBar.settings
      case "holds": tabLabel = AppStrings.TabBar.reservations
      default: XCTFail("Unknown screen: \(screenName)"); return
      }
      
      let tab = app.tabBars.buttons[tabLabel]
      XCTAssertTrue(tab.isSelected, "\(tabLabel) tab should be selected")
    }
  }
}

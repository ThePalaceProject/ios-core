import Foundation
import Cucumberish
import XCTest

class PalaceSearchSteps {
  
  static func setup() {
    let app = TestHelpers.app
    
    When("I search for \"(.*)\"") { args, _ in
      let searchTerm = args![0] as! String
      
      let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
      if searchButton.exists {
        searchButton.tap()
      } else {
        let myBooksSearch = app.buttons[AccessibilityID.MyBooks.searchButton]
        if myBooksSearch.exists {
          myBooksSearch.tap()
        }
      }
      
      TestHelpers.waitFor(0.5)
      
      let searchField = app.searchFields.firstMatch
      if TestHelpers.waitForElement(searchField, timeout: 5.0) {
        searchField.tap()
        searchField.typeText(searchTerm)
      }
      
      TestHelpers.waitFor(2.0)
    }
    
    When("I tap the first (result|search result)") { _, _ in
      let results = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'"))
      
      if results.count > 0 {
        results.element(boundBy: 0).tap()
        TestHelpers.waitFor(1.0)
      } else {
        let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.bookCell.'"))
        if bookCells.count > 0 {
          bookCells.element(boundBy: 0).tap()
          TestHelpers.waitFor(1.0)
        }
      }
    }
    
    Then("I should see search results") { _, _ in
      TestHelpers.waitFor(1.0)
      let results = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'"))
      XCTAssertGreaterThan(results.count, 0, "Should have search results")
    }
  }
}

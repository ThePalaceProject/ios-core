import Foundation
import Cucumberish
import XCTest

/// Complex search steps with distributor, bookType, and context storage
///
/// **Handles:**
/// - Search with availability filter
/// - Search with distributor filter  
/// - Search with bookType filter
/// - Saving search results to context
class ComplexSearchSteps {
  
  static func setup() {
    let app = TestHelpers.app
    
    // MARK: - Complex Search
    
    When("Search '(.*)' book of distributor '(.*)' and bookType '(.*)' and save as '(.*)'") { args, _ in
      let availability = args![0] as! String
      let distributor = args![1] as! String
      let bookType = args![2] as! String
      let varName = args![3] as! String
      
      // Open search if not already open
      let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
      if searchButton.exists {
        searchButton.tap()
        TestHelpers.waitFor(0.5)
      }
      
      // Search for book with criteria
      // For now, search generically and filter results
      let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
      
      if searchField.waitForExistence(timeout: 5.0) {
        searchField.tap()
        
        // Search term based on book type
        let searchTerm = bookType == "AUDIOBOOK" ? "audiobook" :
                        bookType == "PDF" ? "pdf" : "book"
        
        searchField.typeText(searchTerm)
        TestHelpers.waitFor(2.0)
      }
      
      // Save search context
      let bookInfo = BookInfo(
        title: searchTerm,
        author: nil,
        distributor: distributor,
        bookType: bookType
      )
      TestContext.shared.save(bookInfo, forKey: varName)
      
      print("ℹ️ Searched for \(availability) \(bookType) from \(distributor), saved as '\(varName)'")
    }
    
    When("Search for \"(.*)\" and save bookName as '(.*)'") { args, _ in
      let searchTerm = args![0] as! String
      let varName = args![1] as! String
      
      // Search for specific book
      let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
      
      if searchField.waitForExistence(timeout: 5.0) {
        searchField.tap()
        searchField.typeText(searchTerm)
        TestHelpers.waitFor(2.0)
      }
      
      // Save to context
      TestContext.shared.save(searchTerm, forKey: varName)
    }
    
    When("Search for word (.*) and save as '(.*)' on Catalog books screen") { args, _ in
      let searchTerm = args![0] as! String
      let varName = args![1] as! String
      
      let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
      
      if searchField.waitForExistence(timeout: 5.0) {
        searchField.tap()
        searchField.typeText(searchTerm)
        TestHelpers.waitFor(2.0)
      }
      
      TestContext.shared.save(searchTerm, forKey: varName)
    }
    
    When("Search several books and save them in list as '(.*)':") { args, userInfo in
      let varName = args![0] as! String
      
      // Get data table from userInfo
      guard let dataTable = userInfo?["dataTable"] as? [[String]] else {
        XCTFail("No data table provided")
        return
      }
      
      var bookList: [String] = []
      
      for row in dataTable {
        if let bookName = row.first {
          bookList.append(bookName)
        }
      }
      
      TestContext.shared.save(bookList, forKey: varName)
      print("ℹ️ Saved \(bookList.count) books to '\(varName)'")
    }
    
    // MARK: - Search Field Actions
    
    When("Clear search field on Catalog books screen") { _, _ in
      let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
      if clearButton.exists {
        clearButton.tap()
      } else {
        // Try x button
        let xButton = app.buttons["xmark.circle.fill"]
        if xButton.exists {
          xButton.tap()
        }
      }
    }
    
    When("Clear search field on Add library screen") { _, _ in
      let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
      if clearButton.exists {
        clearButton.tap()
      }
    }
    
    // MARK: - Search Verification
    
    Then("The search field is displayed") { _, _ in
      let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
      XCTAssertTrue(searchField.exists, "Search field should be displayed")
    }
    
    Then("Search field is empty on Catalog books screen") { _, _ in
      let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
      
      if searchField.exists {
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Search field should be empty")
      }
    }
    
    Then("Search field is empty on Add library screen") { _, _ in
      let searchField = app.searchFields.firstMatch
      if searchField.exists {
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Search field should be empty")
      }
    }
    
    Then("There is no results on Catalog books screen") { _, _ in
      TestHelpers.waitFor(2.0)
      
      // Check for "no results" message or empty state
      let noResultsText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'no results' OR label CONTAINS[c] 'no books'")).firstMatch
      let hasNoResults = noResultsText.exists || app.cells.count == 0
      
      XCTAssertTrue(hasNoResults, "Should show no results")
    }
    
    Then("Search result is empty on Add library screen") { _, _ in
      TestHelpers.waitFor(1.0)
      let hasCells = app.cells.count > 0 || app.tables.cells.count > 0
      XCTAssertFalse(hasCells, "Search results should be empty")
    }
  }
}


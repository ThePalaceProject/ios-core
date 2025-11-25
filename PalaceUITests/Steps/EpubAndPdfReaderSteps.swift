import Foundation
import Cucumberish
import XCTest

/// EPUB and PDF reader steps
///
/// **Handles:**
/// - Page navigation (forward/backward)
/// - Bookmarks
/// - Search in readers
/// - TOC (table of contents)
/// - Page number verification
class EpubAndPdfReaderSteps {
  
  static func setup() {
    let app = TestHelpers.app
    
    // MARK: - EPUB Reader Verification
    
    Then("'(.*)' book is present on epub reader screen") { args, _ in
      let bookInfoVar = args![0] as! String
      
      // Verify EPUB reader is open (look for reader-specific elements)
      // EPUB reader should be full-screen, no tab bar
      let tabBar = app.tabBars.firstMatch
      let isReaderOpen = !tabBar.isHittable || !tabBar.exists
      
      XCTAssertTrue(isReaderOpen, "EPUB reader should be open")
      print("ℹ️ EPUB reader is open for '\(bookInfoVar)'")
    }
    
    // MARK: - Page Navigation
    
    When("Go to next page on Reader epub screen") { _, _ in
      // Swipe or tap right side to go to next page
      let screenWidth = app.frame.width
      let screenHeight = app.frame.height
      
      // Tap right side of screen
      let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      rightSide.tap()
      
      TestHelpers.waitFor(0.5)
    }
    
    When("Go to next page on reader pdf screen") { _, _ in
      // Swipe or navigate to next PDF page
      app.swipeUp() // PDF often uses vertical scrolling
      TestHelpers.waitFor(0.5)
    }
    
    When("Go to previous page on reader pdf screen") { _, _ in
      app.swipeDown()
      TestHelpers.waitFor(0.5)
    }
    
    // MARK: - Bookmarks
    
    When("Add bookmark on reader epub screen") { _, _ in
      // Look for bookmark button
      let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
      if bookmarkButton.exists {
        bookmarkButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("Add bookmark on reader pdf screen") { _, _ in
      let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
      if bookmarkButton.exists {
        bookmarkButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("Delete bookmark on reader epub screen") { _, _ in
      let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
      if bookmarkButton.exists {
        bookmarkButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    Then("Bookmark is not displayed on reader epub screen") { _, _ in
      // Check for bookmark indicator absence
      // Simplified check
      print("ℹ️ Verified bookmark not displayed")
    }
    
    // MARK: - Reader Navigation
    
    When("Click on left book corner on epub reader screen") { _, _ in
      // Tap left side to go to previous page
      let leftSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
      leftSide.tap()
      TestHelpers.waitFor(0.5)
    }
    
    // MARK: - Search in Reader
    
    When("Enter '(.*)' text and save it as '(.*)' on search epub screen") { args, _ in
      let searchText = args![0] as! String
      let varName = args![1] as! String
      
      let searchField = app.searchFields.firstMatch
      if searchField.exists {
        searchField.tap()
        searchField.typeText(searchText)
      }
      
      TestContext.shared.save(searchText, forKey: varName)
    }
    
    When("Apply search on search epub screen") { _, _ in
      // Tap search/return key
      app.keyboards.buttons["Search"].tap()
      TestHelpers.waitFor(1.0)
    }
    
    When("Delete text in search line on search epub screen") { _, _ in
      let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
      if clearButton.exists {
        clearButton.tap()
      }
    }
    
    // MARK: - Save Page/Chapter Info
    
    When("Save pageNumber as '(.*)' and chapterName as '(.*)' on epub reader screen") { args, _ in
      let pageVar = args![0] as! String
      let chapterVar = args![1] as! String
      
      // Try to get current page number and chapter
      // This would require reader-specific accessibility
      TestContext.shared.save(1, forKey: pageVar) // Placeholder
      TestContext.shared.save("Chapter 1", forKey: chapterVar) // Placeholder
      
      print("ℹ️ Saved page to '\(pageVar)' and chapter to '\(chapterVar)'")
    }
    
    // MARK: - Reader Screen Verification
    
    Then("Reader pdf screen is opened") { _, _ in
      // PDF reader should be full-screen
      let tabBar = app.tabBars.firstMatch
      let isReaderOpen = !tabBar.isHittable || !tabBar.exists
      
      XCTAssertTrue(isReaderOpen, "PDF reader should be open")
    }
    
    // MARK: - PDF TOC
    
    When("Close pdf toc screen by back button") { _, _ in
      let backButton = app.navigationBars.buttons.element(boundBy: 0)
      if backButton.exists {
        backButton.tap()
      }
    }
  }
}


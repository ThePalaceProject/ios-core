# Migration Guide: Java/Appium → Swift/XCTest

**Complete guide for migrating iOS UI tests from Java/Appium/Cucumber to native Swift/XCTest**

---

## 📋 Overview

This guide helps you understand the differences between the old and new testing frameworks and provides patterns for converting existing tests.

### Framework Comparison

| Aspect | Old (Java/Appium) | New (Swift/XCTest) |
|--------|-------------------|-------------------|
| **Language** | Java | Swift |
| **Framework** | Appium + Cucumber | XCTest |
| **Locators** | XPath strings | Accessibility Identifiers (type-safe) |
| **Test Structure** | Gherkin (BDD) | Swift methods |
| **Execution** | BrowserStack | Local/GitHub Actions |
| **Speed** | 6-8 hours (full suite) | 2-3 hours (full suite) |
| **Reliability** | WebDriver abstraction | Native iOS API |
| **Maintainability** | External team | iOS developers |

---

## 🔄 Pattern Conversions

### 1. Element Location

#### Old (XPath Locators)
```java
// SearchScreen.java
private final ITextBox txbSearch = getElementFactory().getTextBox(
    By.xpath("//XCUIElementTypeSearchField"), "Search field");
```

#### New (Accessibility Identifiers)
```swift
// SearchScreen.swift
var searchField: XCUIElement {
    app.searchFields[AccessibilityID.Search.searchField]
}
```

**Benefits:**
- ✅ Type-safe (no typos)
- ✅ Centralized (all IDs in one place)
- ✅ Refactor-friendly (IDE can find all usages)
- ✅ Self-documenting

---

### 2. Test Structure

#### Old (Gherkin/Cucumber)
```gherkin
# BookAcquisition.feature
Scenario: Download a book
  When Search 'available' book of distributor 'Bibliotheca' and bookType 'EBOOK'
  And Click GET action button
  And Click READ action button
  Then Page number is correct
```

```java
// BookAcquisitionSteps.java
@When("Search {string} book of distributor {string} and bookType {string}")
public void searchBook(String availability, String distributor, String bookType) {
    // Implementation
}

@And("Click GET action button")
public void clickGetButton() {
    // Implementation
}
```

#### New (Swift/XCTest)
```swift
// BookAcquisitionTests.swift
func testDownloadAndReadBook() {
    // Arrange
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice wonderland")
    
    // Act
    guard let bookDetail = search.tapFirstResult() else {
        XCTFail("Could not open book")
        return
    }
    
    bookDetail.tapGetButton()
    XCTAssertTrue(bookDetail.waitForDownloadComplete())
    
    bookDetail.tapReadButton()
    
    // Assert
    // Verify book opened (EPUBReaderScreen exists)
    takeScreenshot(named: "book-opened")
}
```

**Benefits:**
- ✅ Standard Swift testing (familiar to iOS devs)
- ✅ Better IDE support (autocomplete, refactoring)
- ✅ Arrange-Act-Assert pattern (clear structure)
- ✅ Type safety (compile-time errors)

---

### 3. Page Object Pattern

#### Old (Java Class Hierarchy)
```java
// SearchScreen.java
public class SearchScreen extends Screen {
    private final ITextBox txbSearch = getElementFactory().getTextBox(
        By.xpath("//XCUIElementTypeSearchField"), "Search field");
    
    private final IButton btnClear = getElementFactory().getButton(
        By.xpath("//XCUIElementTypeButton[@name='clear.button.text']"), "Clear");
    
    public void enterSearchText(String text) {
        txbSearch.sendKeys(text);
    }
    
    public void clearSearch() {
        btnClear.click();
    }
}
```

#### New (Swift Protocol + Class)
```swift
// SearchScreen.swift
final class SearchScreen: ScreenObject {
  
  // MARK: - UI Elements
  
  var searchField: XCUIElement {
    app.searchFields[AccessibilityID.Search.searchField]
  }
  
  var clearButton: XCUIElement {
    app.buttons[AccessibilityID.Search.clearButton]
  }
  
  // MARK: - Actions
  
  func enterSearchText(_ text: String) {
    XCTAssertTrue(waitForElement(searchField))
    searchField.tap()
    searchField.typeText(text)
  }
  
  func clearSearch() {
    if clearButton.exists {
      clearButton.tap()
    }
  }
}
```

**Benefits:**
- ✅ Computed properties (evaluated when accessed)
- ✅ Protocol-oriented (flexible, testable)
- ✅ Swift conventions (clear, concise)
- ✅ Better error handling (XCTAssert)

---

### 4. Waits & Synchronization

#### Old (Explicit Waits)
```java
// Wait for element
wait.until(ExpectedConditions.visibilityOfElementLocated(
    By.xpath("//XCUIElementTypeButton[@name='GET']")));

// Or hard-coded sleep
Thread.sleep(3000);
```

#### New (Predicates & Expectations)
```swift
// Wait for element to exist
let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
XCTAssertTrue(getButton.waitForExistence(timeout: 10.0))

// Wait for element to disappear
let loadingIndicator = app.activityIndicators.firstMatch
let predicate = NSPredicate(format: "exists == false")
let expectation = XCTNSPredicateExpectation(predicate: predicate, object: loadingIndicator)
let result = XCTWaiter.wait(for: [expectation], timeout: 15.0)
XCTAssertEqual(result, .completed)

// ❌ AVOID hard sleeps
// sleep(3) 
```

**Benefits:**
- ✅ Explicit timeouts (no mystery waits)
- ✅ Condition-based (wait for actual state)
- ✅ Better test reliability
- ✅ Clearer test intent

---

### 5. Test Data Management

#### Old (JSON Config Files)
```json
// config.json
{
  "testLibraries": {
    "lyrasisReads": {
      "barcode": "01230000000002",
      "pin": "Lyrtest123"
    }
  }
}
```

```java
// Load from file
JsonObject config = loadConfig("config.json");
String barcode = config.get("testLibraries")
    .getAsJsonObject()
    .get("lyrasisReads")
    .getAsJsonObject()
    .get("barcode")
    .getAsString();
```

#### New (Type-Safe Configuration)
```swift
// TestConfiguration.swift
enum TestConfiguration {
  enum Library {
    case lyrasisReads
    
    var credentials: TestCredentials? {
      switch self {
      case .lyrasisReads:
        return TestCredentials(
          barcode: ProcessInfo.processInfo.environment["LYRASIS_BARCODE"] ?? "01230000000002",
          pin: ProcessInfo.processInfo.environment["LYRASIS_PIN"] ?? "Lyrtest123"
        )
      }
    }
  }
}

// Usage
let credentials = TestConfiguration.Library.lyrasisReads.credentials!
signIn(with: credentials)
```

**Benefits:**
- ✅ Type-safe (no JSON parsing errors)
- ✅ Environment variable support
- ✅ Centralized configuration
- ✅ Autocomplete in IDE

---

## 🗺️ Feature Mapping

### Cucumber Features → Swift Test Classes

| Old Feature File | New Test Class | Location |
|-----------------|----------------|----------|
| `AudiobookLyrasis.feature` | `AudiobookTests.swift` | `Tests/Audiobook/` |
| `EpubLyrasis.feature` | `EPUBReadingTests.swift` | `Tests/EPUB/` |
| `PdfLyrasisIos.feature` | `PDFReadingTests.swift` | `Tests/PDF/` |
| `MyBooks.feature` | `MyBooksTests.swift` | `Tests/MyBooks/` |
| `Reservations.feature` | `ReservationsTests.swift` | `Tests/Reservations/` |
| `BookDetailView.feature` | `BookDetailTests.swift` | `Tests/BookDetail/` |
| `CatalogNavigation.feature` | `CatalogNavigationTests.swift` | `Tests/Catalog/` |
| `Search.feature` | `SearchTests.swift` | `Tests/Search/` |
| `Settings.feature` | `SettingsTests.swift` | `Tests/Settings/` |

---

## 📝 Step-by-Step Migration

### Phase 1: Setup (Completed ✅)

1. ✅ Create `PalaceUITests` target
2. ✅ Add accessibility identifiers to app
3. ✅ Create base infrastructure
4. ✅ Implement 10 smoke tests
5. ✅ Set up CI/CD pipeline

### Phase 2: Core Flows (In Progress)

For each feature file:

1. **Create Test Class**
   ```swift
   final class MyNewTests: BaseTestCase {
     // Tests go here
   }
   ```

2. **Convert Scenarios to Test Methods**
   ```swift
   // Scenario: Download a book
   // → func testDownloadBook()
   ```

3. **Update Screen Objects** (if needed)
   ```swift
   // Add new elements or actions to screen classes
   ```

4. **Run and Verify**
   ```swift
   // Run test: ⌘U
   // Check results in Test Navigator
   ```

### Phase 3: Advanced Features

1. **Parameterized Tests**
   ```swift
   func testBookAcquisitionAcrossDistributors() {
     let distributors: [Distributor] = [.bibliotheca, .axis360]
     
     for distributor in distributors {
       // Test logic
     }
   }
   ```

2. **Test Fixtures**
   ```swift
   struct BookFixture {
     static let aliceInWonderland = TPPBook(...)
   }
   ```

3. **Network Mocking** (Optional)
   ```swift
   // Mock OPDS feeds for faster tests
   URLProtocol.registerClass(MockURLProtocol.self)
   ```

---

## 🔍 Example: Full Feature Migration

### Before: Cucumber Feature

```gherkin
# MyBooks.feature
Feature: My Books Management

Scenario: Download and view book in My Books
  Given I am on the Catalog screen
  When I search for "Alice in Wonderland"
  And I tap the first result
  And I tap GET button
  And I wait for download to complete
  And I navigate to My Books
  Then I should see the downloaded book
```

### After: Swift Test

```swift
// MyBooksTests.swift
final class MyBooksTests: BaseTestCase {
  
  /// Verifies downloaded book appears in My Books
  ///
  /// **Steps:**
  /// 1. Search for book
  /// 2. Download book
  /// 3. Navigate to My Books
  /// 4. Verify book is present
  ///
  /// **Expected:** Book visible in My Books after download
  func testDownloadedBookAppearsInMyBooks() {
    // Arrange: Navigate to catalog and search
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice wonderland")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    // Act: Download book
    if bookDetail.hasGetButton() {
      bookDetail.tapGetButton()
      XCTAssertTrue(bookDetail.waitForDownloadComplete(timeout: 30.0))
    }
    
    // Navigate to My Books
    navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    
    // Assert: Book is in library
    XCTAssertTrue(myBooks.hasBooks(), "My Books should contain the downloaded book")
    XCTAssertGreaterThan(myBooks.bookCount(), 0, "Should have at least one book")
    
    takeScreenshot(named: "book-in-my-books")
  }
}
```

---

## ⚡ Quick Reference

### Common Conversions

| Task | Java/Appium | Swift/XCTest |
|------|-------------|--------------|
| **Find element** | `By.xpath("//...")` | `app.buttons[AccessibilityID.xxx]` |
| **Tap** | `element.click()` | `element.tap()` |
| **Type text** | `element.sendKeys(text)` | `element.typeText(text)` |
| **Wait** | `wait.until(...)` | `element.waitForExistence(timeout:)` |
| **Assert exists** | `assertTrue(element.isDisplayed())` | `XCTAssertTrue(element.exists)` |
| **Screenshot** | Custom implementation | `takeScreenshot(named:)` |
| **Scroll** | `element.swipeUp()` | `element.swipeUp()` |
| **Get text** | `element.getText()` | `element.label` or `element.value` |

---

## 🎯 Best Practices

### DO ✅

- Use accessibility identifiers instead of XPath
- Write tests in Swift (native language)
- Use Screen Object pattern
- Wait for conditions (not hard sleeps)
- Take screenshots at key steps
- Reset app state between tests
- Use descriptive test names
- Add inline documentation

### DON'T ❌

- Use XPath locators
- Hard-code sleeps (`sleep(3)`)
- Access UI elements directly in tests
- Duplicate test logic
- Skip test isolation
- Ignore flaky tests
- Use brittle locators

---

## 📊 Migration Progress Tracking

```swift
// Track progress in a spreadsheet or project management tool

| Feature | Total Scenarios | Migrated | Status | Notes |
|---------|----------------|----------|--------|-------|
| Smoke Tests | 10 | 10 | ✅ Done | Phase 1 complete |
| Audiobook | 30 | 0 | 🔄 Planned | Phase 2 |
| EPUB | 40 | 0 | 🔄 Planned | Phase 2 |
| PDF | 20 | 0 | 🔄 Planned | Phase 2 |
| My Books | 25 | 0 | 🔄 Planned | Phase 2 |
| Search | 15 | 0 | 🔄 Planned | Phase 2 |
| Settings | 20 | 0 | 🔄 Planned | Phase 3 |
```

---

## 🤝 Getting Help

- **Questions?** Ask in `#ios-testing` Slack
- **Stuck?** Review existing smoke tests for patterns
- **Issues?** File GitHub issue with `[Migration]` prefix
- **Pair programming?** Schedule time with iOS team

---

*This guide will be updated as we learn more during migration.*
*Last updated: November 2025*


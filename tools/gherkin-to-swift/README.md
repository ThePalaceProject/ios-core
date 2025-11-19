# GherkinSwift: AI-Powered Test Converter

**Converts Cucumber/Gherkin scenarios → Native Swift/XCTest code**

---

## 🎯 Purpose

Enable QA engineers to write tests in **familiar Gherkin syntax** while generating **native Swift/XCTest code** for iOS testing.

### **The Problem:**
- QA knows Gherkin/Cucumber ✅
- QA doesn't know Swift ❌
- Swift tests are better for iOS ✅
- Need bridge between QA expertise and Swift tests ✅

### **The Solution:**
**AI-powered tool** that converts Gherkin → Swift automatically!

---

## 🚀 Quick Start

```bash
# 1. QA writes Gherkin scenario
cat > features/book-download.feature <<EOF
Feature: Book Download
  Scenario: Download a book
    Given I am on the Catalog screen
    When I search for "Alice in Wonderland"
    And I tap the GET button
    Then the book should download
EOF

# 2. Convert to Swift
./tools/gherkin-to-swift/convert.py features/book-download.feature

# 3. Output: PalaceUITests/Tests/Generated/BookDownloadTests.swift
# Ready for developer review and commit!
```

---

## 🏗️ Architecture

```
┌──────────────────────────────────┐
│  QA writes Gherkin               │
│  (features/my-test.feature)      │
└───────────────┬──────────────────┘
                ↓
┌──────────────────────────────────┐
│  Gherkin Parser                  │
│  • Parses .feature files         │
│  • Extracts scenarios & steps    │
└───────────────┬──────────────────┘
                ↓
┌──────────────────────────────────┐
│  AI Code Generator               │
│  • GPT-4 or Claude               │
│  • Palace context aware          │
│  • Knows screen objects          │
└───────────────┬──────────────────┘
                ↓
┌──────────────────────────────────┐
│  Swift Code Formatter            │
│  • Applies Palace patterns       │
│  • Adds assertions               │
│  • Includes screenshots          │
└───────────────┬──────────────────┘
                ↓
┌──────────────────────────────────┐
│  Generated Swift Test            │
│  (PalaceUITests/Tests/Generated/ │
│   BookDownloadTests.swift)       │
└──────────────────────────────────┘
```

---

## 📝 Example Conversion

### **Input (Gherkin):**

```gherkin
Feature: My Books Management

  Scenario: Sort books by author
    Given I am on the My Books screen
    And I have 3 downloaded books
    When I tap the sort button
    And I select "Author"
    Then books should be sorted alphabetically
```

### **Output (Swift):**

```swift
import XCTest

/// Auto-generated from: features/my-books-management.feature
/// Scenario: Sort books by author
/// Generated: 2025-11-17 12:00:00
final class MyBooksManagementTests: BaseTestCase {
  
  func testSortBooksByAuthor() {
    // Given I am on the My Books screen
    navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    XCTAssertTrue(myBooks.isDisplayed(), "My Books screen should be displayed")
    
    // And I have 3 downloaded books
    // (Prerequisite: ensure books are downloaded)
    XCTAssertGreaterThanOrEqual(myBooks.bookCount(), 3, 
                                "Should have at least 3 books")
    
    // When I tap the sort button
    myBooks.tapSortButton()
    
    // And I select "Author"
    myBooks.sortBy(.author)
    
    // Then books should be sorted alphabetically
    let bookTitles = myBooks.getVisibleBookTitles()
    let sortedTitles = bookTitles.sorted()
    XCTAssertEqual(bookTitles, sortedTitles, 
                   "Books should be sorted alphabetically by author")
    
    takeScreenshot(named: "books-sorted-by-author")
  }
}
```

---

## 🧠 AI Prompt Engineering

The tool uses carefully crafted prompts to generate high-quality Swift code:

### **System Prompt:**

```
You are an expert iOS test automation engineer specializing in Swift/XCTest.

You convert Gherkin/Cucumber scenarios to Swift XCTest code for the Palace iOS app.

Context:
- Palace is an iOS e-reader app (Swift/SwiftUI)
- Test framework uses Screen Object pattern
- Available screen objects: CatalogScreen, MyBooksScreen, BookDetailScreen, SearchScreen
- Base class: BaseTestCase (provides app, navigation, assertions)
- Use AccessibilityID enum for element identification

Guidelines:
1. Follow Arrange-Act-Assert pattern
2. Add descriptive comments (map Gherkin steps)
3. Use existing screen objects (don't create new ones)
4. Add XCTAssert statements for verifications
5. Take screenshots at key steps
6. Use waitForExistence for async operations
7. Follow Swift naming conventions (camelCase)
8. Add test documentation from Gherkin description

Generate production-quality test code that Palace developers would write.
```

### **User Prompt (Per Scenario):**

```
Convert this Gherkin scenario to Swift XCTest code:

Feature: Book Download
  Scenario: Download a book
    Given I am on the Catalog screen
    When I search for "Alice in Wonderland"
    And I tap the first result
    And I tap the GET button
    And I wait for download to complete
    Then I should see the READ button

Available Palace screen objects:
- CatalogScreen: tapSearchButton(), isDisplayed()
- SearchScreen: enterSearchText(String), tapFirstResult()
- BookDetailScreen: tapGetButton(), waitForDownloadComplete(), hasReadButton()

Generate a Swift test method following Palace conventions.
```

---

## 🎨 Supported Gherkin Features

### ✅ Supported:

- ✅ **Feature** blocks
- ✅ **Scenario** blocks
- ✅ **Scenario Outline** (generates parameterized tests)
- ✅ **Background** (generates setUp method)
- ✅ **Given/When/Then/And/But** steps
- ✅ **Data tables** (generates fixtures)
- ✅ **Tags** (maps to test organization)
- ✅ **Comments** (preserved in generated code)

### 🔄 Partially Supported:

- 🔄 **Examples** (manual mapping sometimes needed)
- 🔄 **Custom step definitions** (requires training)

### ❌ Not Supported (Yet):

- ❌ **Hooks** (Before/After)
- ❌ **Complex regex steps**

---

## 💻 Installation

### **Prerequisites:**

```bash
# Python 3.10+
python3 --version

# Install dependencies
pip install -r tools/gherkin-to-swift/requirements.txt
```

### **Requirements.txt:**

```
openai>=1.0.0          # OpenAI API for GPT-4
anthropic>=0.8.0       # Alternative: Claude API
gherkin-official>=24.0 # Gherkin parser
jinja2>=3.1.0          # Template engine
pyyaml>=6.0            # Configuration
rich>=13.0             # Pretty console output
```

### **Configuration:**

```yaml
# config.yaml
ai_provider: "openai"  # or "anthropic"
model: "gpt-4-turbo"
temperature: 0.2  # Low temperature for consistency
max_tokens: 2000

output_dir: "PalaceUITests/Tests/Generated"
screen_objects_dir: "PalaceUITests/Screens"

step_library: "tools/gherkin-to-swift/step_library.yaml"
```

---

## 🎯 Usage Examples

### **Convert Single Feature:**

```bash
python tools/gherkin-to-swift/convert.py \
  features/book-download.feature \
  --output PalaceUITests/Tests/Generated/BookDownloadTests.swift
```

### **Convert All Features:**

```bash
python tools/gherkin-to-swift/convert_all.py \
  features/ \
  --output-dir PalaceUITests/Tests/Generated/ \
  --verbose
```

### **With Custom Step Library:**

```bash
python tools/gherkin-to-swift/convert.py \
  features/my-test.feature \
  --steps custom-steps.yaml \
  --output MyTests.swift
```

### **Dry Run (Preview Only):**

```bash
python tools/gherkin-to-swift/convert.py \
  features/my-test.feature \
  --dry-run
```

---

## 📚 Step Library

Define custom step mappings in `step_library.yaml`:

```yaml
# Step patterns and their Swift code templates
steps:
  - pattern: "I am on the {screen} screen"
    swift: |
      let {screenVar} = {ScreenClass}(app: app)
      XCTAssertTrue({screenVar}.isDisplayed())
    
  - pattern: "I search for {string}"
    swift: |
      let search = catalog.tapSearchButton()
      search.enterSearchText({string})
  
  - pattern: "I tap the {button} button"
    swift: |
      bookDetail.tap{Button}Button()
  
  - pattern: "the {element} should {state}"
    swift: |
      XCTAssertTrue({element}.{stateCheck}())
```

---

## 🧪 Testing the Tool

### **Run Tool Tests:**

```bash
cd tools/gherkin-to-swift
pytest tests/
```

### **Test Scenarios:**

```bash
# Test with sample features
./test-converter.sh test-features/simple.feature
./test-converter.sh test-features/complex.feature
./test-converter.sh test-features/scenario-outline.feature
```

---

## 🤝 Contributing

### **Adding New Step Patterns:**

1. Edit `step_library.yaml`
2. Add pattern and Swift template
3. Test with sample scenario
4. Submit PR

### **Improving AI Generation:**

1. Edit `prompts/system_prompt.txt`
2. Update Palace context
3. Test with existing scenarios
4. Compare quality before/after

---

## 📊 Roadmap

### **Q4 2025:**
- ✅ MVP tool (basic conversion)
- ✅ 50+ common steps supported
- ✅ QA training complete
- ✅ 20 scenarios migrated (pilot)

### **Q1 2026:**
- ✅ AI-powered enhancements
- ✅ 200+ scenarios migrated
- ✅ Custom step definitions
- ✅ Scenario outlines fully supported

### **Q2 2026:**
- ✅ All 400+ scenarios migrated
- ✅ Java/Appium deprecated
- ✅ Full QA autonomy on test writing
- ✅ Continuous improvement process

---

*Let's bridge QA expertise with iOS native testing!*



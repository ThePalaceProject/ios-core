# Accessibility ID Management Guide

**Source of truth: The actual app UI, documented in AccessibilityIdentifiers.swift**

---

## 🎯 **Philosophy:**

**App is source of truth** → Tests adapt to app

**NOT:** Tests define IDs → App adapts to tests

---

## ✅ **How to Manage Accessibility IDs:**

### **1. Check What the App Actually Uses**

**Before adding test code, check the app:**

```bash
# Find what accessibility IDs exist
grep -r "\.accessibilityIdentifier" Palace/ --include="*.swift"

# Find what accessibility labels exist  
grep -r "\.accessibilityLabel" Palace/ --include="*.swift"
```

### **2. Use Text Labels for System UI Elements**

**Some SwiftUI components use text labels automatically:**

| Component | Identified By | Example |
|-----------|---------------|---------|
| **TabView items** | Text label | `app.tabBars.buttons["Catalog"]` |
| **NavigationLink** | Text label | `app.navigationBars.buttons["Back"]` |
| **Alert buttons** | Text label | `app.alerts.buttons["OK"]` |
| **ActionSheet** | Text label | `app.sheets.buttons["Cancel"]` |

**For these, use the actual text instead of custom IDs.**

### **3. Add Custom IDs to Your UI**

**For custom views and buttons, add accessibility IDs:**

```swift
// In app code:
Button("Get") { }
  .accessibilityIdentifier(AccessibilityID.BookDetail.getButton)

TextField("Search", text: $query)
  .accessibilityIdentifier(AccessibilityID.Search.searchField)
```

### **4. Document in AccessibilityIdentifiers.swift**

**Update the enum with actual values:**

```swift
public enum Search {
  /// ✅ Applied in CatalogSearchView.swift line 72
  public static let searchField = "search.searchField"
  
  /// ⚠️ Not yet applied - TODO
  public static let clearButton = "search.clearButton"
}
```

---

## 📋 **Current Status (Post-Fix):**

### **✅ IDs Actually Applied in App:**

**Tab Bar:**
- ⚠️ Uses text labels (SwiftUI behavior):
  - "Catalog", "My Books", "Reservations", "Settings"

**Catalog:**
- ✅ `catalog.searchButton` (toolbar button)
- ✅ `catalog.accountButton` (toolbar button)
- ✅ `catalog.libraryLogo` (logo image)
- ✅ `catalog.scrollView` (main content)
- ✅ `catalog.loadingIndicator` (skeleton)
- ✅ `catalog.errorView` (error text)

**Search:**
- ✅ `search.searchField` (search TextField) ← Just added!
- ✅ `search.cancelButton` (cancel button in toolbar)

**My Books:**
- ✅ `myBooks.sortButton` (sort button)
- ✅ `myBooks.gridView` (book grid)
- ✅ `myBooks.searchButton` (search button)
- ✅ `myBooks.emptyStateView` (empty state)

**Book Detail:**
- ✅ `bookDetail.coverImage` (book cover)
- ✅ `bookDetail.title` (title text)
- ✅ `bookDetail.author` (author text)
- ✅ ALL action buttons (GET, READ, DELETE, etc.) via BookButtonsView

### **❌ IDs Defined But Not Yet Applied:**

- ⚠️ Book cells (individual book accessibility)
- ⚠️ Search results
- ⚠️ Audiobook player (needs IDs added to PalaceAudiobookToolkit)
- ⚠️ PDF reader elements
- ⚠️ EPUB reader elements

---

## 🔄 **Workflow: Adding New IDs**

### **When You Need a New Accessibility ID:**

**Step 1: Check if it already exists**
```bash
# Search in app code
grep -r "elementName" Palace/ --include="*.swift"

# Check AccessibilityIdentifiers.swift
cat Palace/Utilities/Testing/AccessibilityIdentifiers.swift | grep -i "elementName"
```

**Step 2: If it doesn't exist, add to app first**
```swift
// In the actual UI file (e.g., MyBooksView.swift):
Button("Sort") { }
  .accessibilityIdentifier("myBooks.sortButton")
```

**Step 3: Add to AccessibilityIdentifiers.swift**
```swift
public enum MyBooks {
  /// ✅ Applied in MyBooksView.swift line 97
  public static let sortButton = "myBooks.sortButton"
}
```

**Step 4: Use in tests**
```swift
let sortButton = app.buttons[AccessibilityID.MyBooks.sortButton]
XCTAssertTrue(sortButton.exists)
```

---

## 📝 **Best Practices:**

### **DO:**

✅ **Check app first** - See what IDs/labels exist  
✅ **Use text labels** for system UI (tabs, alerts)  
✅ **Add IDs incrementally** - As you need them for tests  
✅ **Document in AccessibilityIdentifiers.swift** - Mark as ✅ or ⚠️  
✅ **Keep IDs simple** - "screen.element" pattern  

### **DON'T:**

❌ **Don't define IDs before applying** - App is source of truth  
❌ **Don't override system labels** - Use what SwiftUI provides  
❌ **Don't duplicate** - One ID per element  
❌ **Don't change IDs in tests** - Tests adapt to app  

---

## 🎯 **Summary:**

**✅ Updated:**
- AccessibilityIdentifiers.swift now documents tab label reality
- Tests now use actual app labels
- Search field has accessibility ID added

**✅ Next:**
- Clean and rebuild Palace app (⌘⇧K, ⌘B)
- Run tests (⌘U)
- Add more IDs as tests need them (incrementally)

---

**The file is now accurate - app is source of truth!** 🎯


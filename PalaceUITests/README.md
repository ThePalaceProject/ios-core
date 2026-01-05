# Palace iOS UI Tests

**Minimal smoke tests for verifying critical app functionality.**

## 🎯 Overview

This directory contains **minimal smoke tests** that verify the app launches and basic navigation works. The majority of testing is now done through **unit tests** and **integration tests** in the `PalaceTests` target.

### Testing Strategy

Following the **testing pyramid** approach:

```
        /\
       /  \     E2E/Smoke Tests (PalaceUITests)
      /    \    - App launches
     /------\   - Basic navigation
    /        \  - ~7 tests, ~2 min
   /  Unit &   \ 
  / Integration \ Unit & Integration Tests (PalaceTests)
 /    Tests      \ - ~80+ tests
/________________\ - ViewModel logic, business logic, bookmarks, etc.
```

| Layer | Location | Tests | Purpose |
|-------|----------|-------|---------|
| E2E/Smoke | `PalaceUITests/` | ~7 | App launches, navigation works |
| Unit/Integration | `PalaceTests/` | ~80+ | Business logic, ViewModels, data layer |
| Snapshot | `PalaceTests/Snapshots/` | ~20 | Visual regression detection |

---

## 📁 Directory Structure

```
PalaceUITests/
├── Tests/
│   └── SmokeTests.swift      # Minimal smoke tests
├── Helpers/
│   ├── BaseTestCase.swift    # Base test class
│   ├── SystemAlertHandler.swift  # System alert handling
│   ├── AuthenticationHelper.swift # Auth helpers
│   └── TestHelpers.swift     # Utility functions
├── Extensions/
│   └── XCUIElement+Extensions.swift
└── README.md
```

---

## 🚀 Running Tests

### Smoke Tests (Recommended for PRs)

```bash
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PalaceUITests/SmokeTests
```

### In Xcode

1. Open `Palace.xcodeproj`
2. Select `Palace` scheme
3. Select iPhone simulator
4. Press `⌘U` to run all tests

---

## 🧪 Test Coverage

### Smoke Tests (`SmokeTests.swift`)

| Test | Description | Duration |
|------|-------------|----------|
| `testAppLaunches_ShowsMainInterface` | App launches successfully | ~5s |
| `testNavigateToMyBooks_ShowsScreen` | My Books tab accessible | ~3s |
| `testNavigateToSettings_ShowsScreen` | Settings tab accessible | ~3s |
| `testNavigateToCatalog_ShowsScreen` | Catalog tab accessible | ~3s |
| `testNavigateToReservations_ShowsScreen` | Reservations tab accessible | ~3s |
| `testSearchButton_IsAccessible` | Search is available | ~3s |
| `testBasicNavigation_NoCrash` | No crash during navigation | ~5s |

**Total: ~2 minutes**

---

## 🧪 Unit/Integration Tests (PalaceTests)

For comprehensive testing, see the `PalaceTests` target:

### Audio/Audiobook Tests
- `AudiobookBookmarkBusinessLogicTests` - Position saving, sync, restoration
- `AudiobookPlaybackTests` - Skip, speed, timer calculations
- `AudiobookTrackerTests` - Time tracking

### EPUB/Reader Tests
- `EPUBPositionTests` - Page position save/restore
- `EPUBSearchTests` - In-book search functionality
- `TPPReaderBookmarksBusinessLogicTests` - Bookmark CRUD

### Catalog Tests
- `FacetFilteringTests` - Catalog filtering and sorting
- `CatalogViewModelTests` - Catalog UI logic

### My Books Tests
- `MyBooksViewModelTests` - Sorting, filtering, returns

### Settings Tests
- `SettingsViewModelTests` - Account validation, auth states

### Snapshot Tests
- `BookDetailSnapshotTests` - Book detail UI consistency
- `CatalogSnapshotTests` - Catalog UI consistency

---

## 🔧 Adding New Tests

### For Business Logic → Add to PalaceTests

```swift
// PalaceTests/NewFeatureTests.swift
import XCTest
@testable import Palace

class NewFeatureTests: XCTestCase {
  func testFeatureLogic() {
    // Test business logic without UI
  }
}
```

### For Critical Navigation → Add to SmokeTests

```swift
// PalaceUITests/Tests/SmokeTests.swift
func testNewCriticalPath_Works() throws {
  // Only for truly critical user paths
  // Keep minimal!
}
```

---

## 📊 Why This Approach?

### Benefits Over E2E-Heavy Testing

| Problem with E2E Tests | Solution |
|----------------------|----------|
| Slow (minutes per test) | Unit tests run in milliseconds |
| Flaky (timing, network) | Unit tests are deterministic |
| Expensive to maintain | Logic changes don't break UI tests |
| Hard to debug | Unit tests have clear failures |
| Requires app running | Unit tests run independently |

### When to Use E2E Tests

- ✅ App launches correctly
- ✅ Critical navigation paths work
- ✅ Tabs are accessible
- ❌ Testing business logic (use unit tests)
- ❌ Testing data transformations (use unit tests)
- ❌ Testing ViewModel behavior (use unit tests)

---

## 📚 Related Resources

- **Unit Tests**: `PalaceTests/` directory
- **Accessibility IDs**: `Palace/Utilities/Testing/AccessibilityIdentifiers.swift`
- **Test Mocks**: `PalaceTests/Mocks/`
- **Test Fixtures**: `PalaceTests/Fixtures/`

---

*Updated: January 2026*

# Palace iOS UI Tests - Setup Guide

**Complete setup guide for running and developing UI tests**

---

## 🚀 Quick Start (5 Minutes)

### Prerequisites

- macOS 14+ (Sonoma or later)
- Xcode 15.2+
- Git
- Palace iOS codebase cloned

### 1. Open Project

```bash
cd /path/to/ios-core
open Palace.xcodeproj
```

### 2. Select Scheme

1. In Xcode, select **Palace** scheme (top-left)
2. Select **iPhone 15 Pro** simulator

### 3. Run Smoke Tests

Press `⌘U` or:

Product → Test

**That's it!** Tests will run automatically.

---

## 🛠️ Detailed Setup

### Step 1: Clone Repository

```bash
git clone https://github.com/your-org/ios-core.git
cd ios-core
git submodule update --init --recursive
```

### Step 2: Install Dependencies

```bash
# Optional: Install SwiftLint for code quality
brew install swiftlint

# Optional: Install xcpretty for better test output
gem install xcpretty
```

### Step 3: Configure Test Environment

#### Option A: Use Default Test Credentials

No setup needed! Tests will use default test account.

#### Option B: Use Custom Test Credentials

1. Open Xcode
2. Select **Palace** scheme → **Edit Scheme...** (`⌘<`)
3. Go to **Test** section
4. Select **Arguments** tab
5. Add **Environment Variables**:

| Name | Value | Description |
|------|-------|-------------|
| `LYRASIS_BARCODE` | Your test barcode | Test account for Lyrasis library |
| `LYRASIS_PIN` | Your test PIN | Test account PIN |
| `TEST_MODE` | `1` | Enable test mode features |
| `SKIP_ANIMATIONS` | `1` | Disable animations for faster tests |

6. Click **Close**

### Step 4: Add PalaceUITests to Project (If Not Already Added)

The test target should already exist. If it doesn't:

1. File → New → Target
2. Select **iOS UI Testing Bundle**
3. Name: `PalaceUITests`
4. Add to **Palace** scheme
5. Add test files from `PalaceUITests/` folder

---

## 🧪 Running Tests

### In Xcode

#### Run All Tests
1. Press `⌘U`
2. Or: Product → Test

#### Run Specific Test Class
1. Open test file (e.g., `SmokeTests.swift`)
2. Click diamond icon next to class name
3. Or: Press `⌘U` with file open

#### Run Single Test
1. Open test file
2. Click diamond icon next to test method
3. Or: Place cursor in test method and press `⌘U`

### Command Line

#### Run Smoke Tests
```bash
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PalaceUITests/SmokeTests
```

#### Run All UI Tests
```bash
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -testPlan PalaceUITests
```

#### With Pretty Output
```bash
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PalaceUITests/SmokeTests \
  | xcpretty --color --report html --output test-report.html
```

---

## 🔧 Troubleshooting

### Issue: "No such module 'XCTest'"

**Solution:** Make sure you're running tests (⌘U), not building (⌘B). XCTest is only available during test runs.

---

### Issue: Simulator boots but tests don't start

**Solution:**
1. Quit Simulator
2. Reset simulator:
   ```bash
   xcrun simctl erase all
   ```
3. Try again

---

### Issue: "Element not found" errors

**Cause:** Accessibility identifiers not added to UI elements

**Solution:**
1. Check `AccessibilityIdentifiers.swift` for the ID
2. Verify it's applied in the app code:
   ```swift
   .accessibilityIdentifier(AccessibilityID.xxx)
   ```
3. Rebuild app (⌘B)
4. Run tests again

---

### Issue: Tests are very slow

**Solutions:**
1. Enable animation skipping:
   - Edit Scheme → Test → Environment Variables
   - Add `SKIP_ANIMATIONS` = `1`

2. Use simulator instead of device

3. Close other apps (free up resources)

---

### Issue: Tests fail on CI but pass locally

**Common Causes:**
- Different simulator versions
- Missing environment variables
- Network issues
- Timing differences (slower CI machines)

**Solutions:**
1. Increase timeouts for CI:
   ```swift
   #if targetEnvironment(simulator)
     let timeout = 10.0  // CI machines may be slower
   #else
     let timeout = 5.0
   #endif
   ```

2. Check GitHub Actions logs for specific errors

3. Ensure all dependencies are installed on CI

---

### Issue: Cannot see test results

**Solution:**
1. Open **Test Navigator** (⌘6)
2. Select failed test
3. View logs and screenshots
4. Or check `~/Library/Developer/Xcode/DerivedData/.../Logs/Test/`

---

## 📊 Viewing Test Results

### Xcode Test Navigator

1. Press `⌘6` to open Test Navigator
2. Green ✓ = passed
3. Red ✗ = failed
4. Click test for details

### Test Reports (HTML)

```bash
# Generate HTML report
xcodebuild test ... | xcpretty --report html

# Open report
open build/reports/tests.html
```

### Screenshots

Screenshots are automatically captured on:
- Test failures (all failed tests)
- Manual calls to `takeScreenshot(named:)`

**Location:**
```
~/Library/Developer/Xcode/DerivedData/Palace-xxx/Logs/Test/Attachments/
```

Or view in Xcode Test Navigator.

---

## 🔐 Test Credentials

### Default Test Accounts

| Library | Barcode | PIN | Description |
|---------|---------|-----|-------------|
| Lyrasis Reads | `01230000000002` | `Lyrtest123` | Multi-distributor test library |
| Palace Bookshelf | N/A | N/A | No authentication required |
| A1QA Test Library | Set in env vars | Set in env vars | QA library (optional) |

### Using Custom Credentials

1. Set environment variables in Xcode scheme
2. Or use `.xcconfig` file (gitignored):

```
// TestCredentials.xcconfig (create this file)
LYRASIS_BARCODE = 01230000000002
LYRASIS_PIN = Lyrtest123
```

3. Add to scheme: Build Settings → Configuration

---

## 🎯 Best Practices

### Before Running Tests

1. ✅ Close unnecessary apps (free RAM)
2. ✅ Use iPhone 15 Pro simulator (recommended)
3. ✅ Disable animations (faster tests)
4. ✅ Ensure stable network (for library catalog)

### During Development

1. ✅ Run smoke tests frequently (fast feedback)
2. ✅ Take screenshots on key steps
3. ✅ Use descriptive test names
4. ✅ Reset app state between tests
5. ✅ Use accessibility identifiers (not XPath)

### Before Committing

1. ✅ Run full smoke test suite
2. ✅ Ensure all tests pass
3. ✅ Add accessibility IDs for new UI elements
4. ✅ Update documentation if needed

---

## 🚨 Common Mistakes

### ❌ Don't Do This

```swift
// ❌ Hard sleeps
sleep(3)

// ❌ Direct element access without waiting
app.buttons["GET"].tap()

// ❌ XPath locators
app.buttons.matching(NSPredicate(format: "label CONTAINS 'GET'"))

// ❌ No test isolation
// (not resetting state between tests)
```

### ✅ Do This Instead

```swift
// ✅ Wait for element
let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
XCTAssertTrue(getButton.waitForExistence(timeout: 10.0))
getButton.tap()

// ✅ Use accessibility identifiers
app.buttons[AccessibilityID.BookDetail.getButton]

// ✅ Reset state in setUp()
override func setUp() throws {
  try super.setUp()
  resetAppState()
}
```

---

## 📚 Additional Resources

- [Main README](./README.md) - Full test framework documentation
- [Migration Guide](./MIGRATION_GUIDE.md) - Java/Appium → Swift guide
- [AccessibilityIdentifiers.swift](../Palace/Utilities/Testing/AccessibilityIdentifiers.swift) - All test IDs
- [Apple XCTest Documentation](https://developer.apple.com/documentation/xctest)

---

## 🆘 Getting Help

### Self-Service

1. Check this guide
2. Review existing smoke tests for patterns
3. Search Xcode documentation (⌥-click on symbol)
4. Check GitHub issues

### Ask for Help

1. **Slack**: `#ios-testing` channel
2. **Email**: ios-team@palaceproject.org
3. **GitHub**: Open issue with `[UI Tests]` prefix

### Report Issues

Include:
- Xcode version
- Simulator used
- Test name
- Error message
- Screenshots (if applicable)
- Steps to reproduce

---

*Last updated: November 2025*
*Palace iOS Testing Team*


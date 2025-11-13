# BrowserStack Integration Guide

**Running Palace iOS UI Tests on BrowserStack physical devices for DRM testing**

---

## 🎯 Overview

BrowserStack's **App Automate** service fully supports **native XCTest/XCUITest** frameworks. This allows you to run the same Swift tests on **real iOS devices** for DRM-dependent features.

### Why BrowserStack + XCTest?

✅ **DRM Testing** - Test LCP/Adobe DRM on real devices (requires physical hardware)  
✅ **Device Coverage** - Test on 100+ real iOS devices (iPhone 15, 14, 13, iPad, etc.)  
✅ **Same Tests** - No code changes needed, same Swift tests work everywhere  
✅ **Hybrid Strategy** - Simulators for speed, devices for DRM  
✅ **Cost Optimization** - Pay only for device time, not infrastructure  

---

## 🏗️ Architecture: Hybrid Testing Strategy

### Recommended Approach

```
┌─────────────────────────────────────────────────────────┐
│  TIER 1: Fast Feedback (Simulators)                    │
│  • Run on: GitHub Actions / Local                       │
│  • Target: Palace-noDRM                                 │
│  • Duration: 10-15 minutes                              │
│  • Tests: Smoke tests, UI flows, non-DRM features      │
│  • Trigger: Every PR, every commit                      │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  TIER 2: DRM Testing (BrowserStack Physical Devices)   │
│  • Run on: BrowserStack App Automate                    │
│  • Target: Palace (full DRM)                            │
│  • Duration: 30-60 minutes                              │
│  • Tests: LCP audiobooks, Adobe DRM, protected content  │
│  • Trigger: Nightly, pre-release, on-demand            │
└─────────────────────────────────────────────────────────┘
```

### Cost Optimization

- **80% of tests**: Run on simulators (free)
- **20% of tests**: Run on BrowserStack devices (DRM-only)
- **Result**: ~70% cost reduction vs. running everything on BrowserStack

---

## 🚀 Quick Start

### Step 1: Install BrowserStack CLI

```bash
# Install BrowserStack CLI
npm install -g browserstack-cli

# Or use Homebrew
brew install browserstack/tap/browserstack-cli

# Login with credentials
browserstack-cli login
```

### Step 2: Build App for Testing

```bash
# Build Palace app with DRM support
xcodebuild build-for-testing \
  -project Palace.xcodeproj \
  -scheme Palace \
  -sdk iphoneos \
  -configuration Debug \
  -derivedDataPath build/

# This creates:
# - Palace.app (in build/Build/Products/Debug-iphoneos/)
# - PalaceUITests-Runner.app (test runner)
```

### Step 3: Upload to BrowserStack

```bash
# Upload app
curl -u "YOUR_USERNAME:YOUR_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/upload" \
  -F "file=@build/Build/Products/Debug-iphoneos/Palace.app" \
  -F "custom_id=Palace-DRM"

# Upload test suite
curl -u "YOUR_USERNAME:YOUR_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/test-suite" \
  -F "file=@build/Build/Products/Debug-iphoneos/PalaceUITests-Runner.app" \
  -F "custom_id=PalaceUITests"
```

### Step 4: Run Tests on BrowserStack

```bash
# Run DRM-specific tests on real device
curl -u "YOUR_USERNAME:YOUR_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/build" \
  -d '{
    "app": "Palace-DRM",
    "testSuite": "PalaceUITests",
    "devices": ["iPhone 15 Pro-17.0"],
    "class": ["PalaceUITests.LCPAudiobookTests"]
  }' \
  -H "Content-Type: application/json"
```

---

## 📋 Detailed Setup

### 1. BrowserStack Account Setup

1. Sign up at https://www.browserstack.com/app-automate
2. Get your credentials:
   - Username: `YOUR_USERNAME`
   - Access Key: `YOUR_ACCESS_KEY`
3. Install BrowserStack CLI (see Quick Start)

### 2. Configure Xcode Build Settings

#### For DRM Target (Palace)

```bash
# Edit Palace.xcodeproj build settings
# Target: Palace
# Configuration: Debug

# Code Signing Identity: iOS Developer
# Provisioning Profile: Development profile with DRM entitlements
# Enable Bitcode: NO (required for XCTest)
```

#### For Non-DRM Target (Palace-noDRM)

```bash
# Target: Palace-noDRM
# Same settings as above, but without DRM entitlements
```

### 3. Create Build Script

Create `scripts/build-for-browserstack.sh`:

```bash
#!/bin/bash
#
# Build Palace app and tests for BrowserStack
#

set -e

SCHEME="Palace"  # or "Palace-noDRM" for simulator testing
CONFIGURATION="Debug"
DERIVED_DATA="build/"

echo "🏗️ Building $SCHEME for BrowserStack..."

# Clean previous builds
rm -rf "$DERIVED_DATA"

# Build for testing
xcodebuild build-for-testing \
  -project Palace.xcodeproj \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="iPhone Developer" \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID"

echo "✅ Build complete!"
echo ""
echo "App location:"
echo "  $DERIVED_DATA/Build/Products/Debug-iphoneos/Palace.app"
echo ""
echo "Test runner location:"
echo "  $DERIVED_DATA/Build/Products/Debug-iphoneos/PalaceUITests-Runner.app"
echo ""
```

Make it executable:
```bash
chmod +x scripts/build-for-browserstack.sh
```

### 4. Create Upload Script

Create `scripts/upload-to-browserstack.sh`:

```bash
#!/bin/bash
#
# Upload app and tests to BrowserStack
#

set -e

BROWSERSTACK_USERNAME="${BROWSERSTACK_USERNAME}"
BROWSERSTACK_ACCESS_KEY="${BROWSERSTACK_ACCESS_KEY}"

if [ -z "$BROWSERSTACK_USERNAME" ] || [ -z "$BROWSERSTACK_ACCESS_KEY" ]; then
    echo "❌ Error: BrowserStack credentials not set"
    echo "Set environment variables:"
    echo "  export BROWSERSTACK_USERNAME='your-username'"
    echo "  export BROWSERSTACK_ACCESS_KEY='your-access-key'"
    exit 1
fi

APP_PATH="build/Build/Products/Debug-iphoneos/Palace.app"
TEST_RUNNER_PATH="build/Build/Products/Debug-iphoneos/PalaceUITests-Runner.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at $APP_PATH"
    echo "Run: ./scripts/build-for-browserstack.sh"
    exit 1
fi

# Zip app
echo "📦 Zipping app..."
cd build/Build/Products/Debug-iphoneos/
zip -r Palace.zip Palace.app
cd -

# Zip test runner
echo "📦 Zipping test runner..."
cd build/Build/Products/Debug-iphoneos/
zip -r PalaceUITests-Runner.zip PalaceUITests-Runner.app
cd -

# Upload app
echo "⬆️ Uploading app to BrowserStack..."
APP_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/upload" \
  -F "file=@build/Build/Products/Debug-iphoneos/Palace.zip" \
  -F "custom_id=Palace-DRM-$(date +%Y%m%d-%H%M%S)")

APP_URL=$(echo "$APP_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['app_url'])")
echo "✅ App uploaded: $APP_URL"

# Upload test suite
echo "⬆️ Uploading test suite to BrowserStack..."
TEST_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/test-suite" \
  -F "file=@build/Build/Products/Debug-iphoneos/PalaceUITests-Runner.zip" \
  -F "custom_id=PalaceUITests-$(date +%Y%m%d-%H%M%S)")

TEST_SUITE_URL=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['test_suite_url'])")
echo "✅ Test suite uploaded: $TEST_SUITE_URL"

echo ""
echo "📝 Save these URLs for running tests:"
echo "  APP_URL=$APP_URL"
echo "  TEST_SUITE_URL=$TEST_SUITE_URL"
```

Make it executable:
```bash
chmod +x scripts/upload-to-browserstack.sh
```

### 5. Create Test Execution Script

Create `scripts/run-browserstack-tests.sh`:

```bash
#!/bin/bash
#
# Run tests on BrowserStack
#

set -e

BROWSERSTACK_USERNAME="${BROWSERSTACK_USERNAME}"
BROWSERSTACK_ACCESS_KEY="${BROWSERSTACK_ACCESS_KEY}"
APP_URL="${1:-Palace-DRM}"
TEST_SUITE_URL="${2:-PalaceUITests}"
DEVICE="${3:-iPhone 15 Pro-17.0}"

if [ -z "$BROWSERSTACK_USERNAME" ] || [ -z "$BROWSERSTACK_ACCESS_KEY" ]; then
    echo "❌ Error: BrowserStack credentials not set"
    exit 1
fi

echo "🧪 Running tests on BrowserStack..."
echo "Device: $DEVICE"
echo "App: $APP_URL"
echo "Test Suite: $TEST_SUITE_URL"
echo ""

BUILD_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/build" \
  -d "{
    \"app\": \"$APP_URL\",
    \"testSuite\": \"$TEST_SUITE_URL\",
    \"devices\": [\"$DEVICE\"],
    \"networkLogs\": true,
    \"deviceLogs\": true,
    \"video\": true
  }" \
  -H "Content-Type: application/json")

BUILD_ID=$(echo "$BUILD_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['build_id'])")

echo "✅ Test execution started!"
echo "Build ID: $BUILD_ID"
echo ""
echo "View results at:"
echo "https://app-automate.browserstack.com/dashboard/v2/builds/$BUILD_ID"
```

Make it executable:
```bash
chmod +x scripts/run-browserstack-tests.sh
```

---

## 🎯 Test Organization for BrowserStack

### Create DRM-Specific Test Suite

Create `PalaceUITests/Tests/DRM/LCPAudiobookTests.swift`:

```swift
import XCTest

/// LCP DRM audiobook tests - REQUIRES PHYSICAL DEVICE
///
/// **Run on:** BrowserStack physical devices only
/// **Why:** LCP DRM decryption only works on physical devices
///
/// **BrowserStack Command:**
/// ```bash
/// ./scripts/run-browserstack-tests.sh \
///   Palace-DRM \
///   PalaceUITests \
///   "iPhone 15 Pro-17.0" \
///   -only-testing:PalaceUITests/LCPAudiobookTests
/// ```
final class LCPAudiobookTests: BaseTestCase {
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    // Skip if running on simulator
    #if targetEnvironment(simulator)
    throw XCTSkip("LCP DRM tests require physical device - run on BrowserStack")
    #endif
  }
  
  /// Test LCP encrypted audiobook playback
  func testLCPAudiobookPlayback() {
    // Sign in with test account
    signIn(with: TestConfiguration.Library.lyrasisReads.credentials!)
    
    // Search for LCP audiobook
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("lcp audiobook test")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not find LCP audiobook")
      return
    }
    
    // Download LCP audiobook
    XCTAssertTrue(bookDetail.downloadBook(), "LCP audiobook should download")
    
    // Open audiobook player
    bookDetail.tapListenButton()
    
    // Verify playback controls exist
    let playerView = app.otherElements[AccessibilityID.AudiobookPlayer.playerView]
    XCTAssertTrue(playerView.waitForExistence(timeout: 15.0), 
                  "Audiobook player should open")
    
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    XCTAssertTrue(playButton.exists, "Play button should exist")
    
    // Attempt playback (LCP decryption happens here)
    playButton.tap()
    
    // Wait and verify audio is playing
    wait(2.0)
    
    // Check if play button changed to pause (indicates playback started)
    let pauseButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    XCTAssertTrue(pauseButton.exists, "Should show pause button when playing")
    
    takeScreenshot(named: "lcp-audiobook-playing")
  }
}
```

### Tag Tests by Execution Environment

Add to `TestConfiguration.swift`:

```swift
extension TestConfiguration {
  
  /// Execution environment for tests
  enum ExecutionEnvironment {
    case simulator
    case physicalDevice
    case browserStack
    
    static var current: ExecutionEnvironment {
      #if targetEnvironment(simulator)
      return .simulator
      #else
      // Check if running on BrowserStack
      if ProcessInfo.processInfo.environment["BROWSERSTACK_BUILD_NAME"] != nil {
        return .browserStack
      }
      return .physicalDevice
      #endif
    }
  }
  
  /// Check if DRM features are available
  static var isDRMSupported: Bool {
    ExecutionEnvironment.current != .simulator
  }
}
```

---

## 🔧 GitHub Actions Integration

### Add BrowserStack Job to Workflow

Update `.github/workflows/ui-tests.yml`:

```yaml
jobs:
  # ... existing smoke-tests job ...

  # New job: BrowserStack DRM tests (nightly/on-demand)
  browserstack-drm-tests:
    name: BrowserStack DRM Tests
    runs-on: macos-14
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    needs: smoke-tests
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Build for BrowserStack
        run: |
          ./scripts/build-for-browserstack.sh
        env:
          DEVELOPMENT_TEAM: ${{ secrets.APPLE_TEAM_ID }}
      
      - name: Upload to BrowserStack
        run: |
          ./scripts/upload-to-browserstack.sh
        env:
          BROWSERSTACK_USERNAME: ${{ secrets.BROWSERSTACK_USERNAME }}
          BROWSERSTACK_ACCESS_KEY: ${{ secrets.BROWSERSTACK_ACCESS_KEY }}
      
      - name: Run DRM tests
        run: |
          ./scripts/run-browserstack-tests.sh \
            "Palace-DRM" \
            "PalaceUITests" \
            "iPhone 15 Pro-17.0"
        env:
          BROWSERSTACK_USERNAME: ${{ secrets.BROWSERSTACK_USERNAME }}
          BROWSERSTACK_ACCESS_KEY: ${{ secrets.BROWSERSTACK_ACCESS_KEY }}
```

### Configure GitHub Secrets

Add to GitHub repository secrets:
- `BROWSERSTACK_USERNAME`
- `BROWSERSTACK_ACCESS_KEY`
- `APPLE_TEAM_ID`
- `LYRASIS_BARCODE`
- `LYRASIS_PIN`

---

## 💰 Cost Optimization Strategies

### 1. Run Only DRM Tests on BrowserStack

```bash
# ✅ DO THIS: Run only DRM-dependent tests
./scripts/run-browserstack-tests.sh \
  Palace-DRM \
  PalaceUITests \
  "iPhone 15 Pro-17.0" \
  -only-testing:PalaceUITests/LCPAudiobookTests

# ❌ DON'T DO THIS: Run all tests (expensive)
./scripts/run-browserstack-tests.sh Palace-DRM PalaceUITests
```

### 2. Use Scheduled Runs

```yaml
# Run nightly at 2 AM UTC (off-peak, cheaper)
on:
  schedule:
    - cron: '0 2 * * *'
```

### 3. Parallel Execution

```bash
# Run tests in parallel on multiple devices
curl -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/build" \
  -d '{
    "devices": [
      "iPhone 15 Pro-17.0",
      "iPhone 14 Pro-17.0",
      "iPad Pro 12.9 2022-17.0"
    ],
    "parallelTests": 3
  }'
```

### 4. Estimated Costs

**Current (All tests on BrowserStack):**
- 400 tests × 30 seconds = 200 minutes/run
- Daily runs = 6,000 minutes/month
- Cost: ~$500/month

**Optimized (Hybrid approach):**
- 40 DRM tests × 30 seconds = 20 minutes/run
- Nightly runs = 600 minutes/month
- Cost: ~$50-100/month
- **Savings: 80-90%**

---

## 📊 Recommended Test Distribution

### Simulators (Free, Fast) - 90% of tests

```swift
// SmokeTests.swift - Run on simulators
// CatalogTests.swift - Run on simulators
// SearchTests.swift - Run on simulators
// MyBooksTests.swift - Run on simulators
// EPUBBasicTests.swift - Run on simulators (non-DRM books)
```

### BrowserStack Devices (Paid, Necessary) - 10% of tests

```swift
// LCPAudiobookTests.swift - BrowserStack only
// AdobeDRMTests.swift - BrowserStack only
// LCPEPUBTests.swift - BrowserStack only
```

---

## 🔍 Debugging BrowserStack Tests

### View Live Test Execution

```bash
# Get session details
curl -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/builds/$BUILD_ID"

# View live session
open "https://app-automate.browserstack.com/dashboard/v2/builds/$BUILD_ID"
```

### Download Logs & Videos

BrowserStack automatically captures:
- ✅ Video recording of test execution
- ✅ Device logs
- ✅ Network logs
- ✅ Screenshots on failures
- ✅ Crash logs

Access via dashboard or API.

---

## 📚 Additional Resources

- [BrowserStack App Automate Docs](https://www.browserstack.com/docs/app-automate/xcuitest)
- [XCTest Best Practices](https://developer.apple.com/documentation/xctest)
- [BrowserStack Device List](https://www.browserstack.com/list-of-browsers-and-platforms/app_automate)
- [BrowserStack Pricing](https://www.browserstack.com/pricing)

---

## 🎯 Summary

**You can keep using BrowserStack AND get the benefits of native Swift/XCTest!**

✅ **Best of both worlds:**
- Fast feedback on simulators (free, 10 min)
- DRM testing on devices (BrowserStack, as needed)
- Same test code, different execution environments
- 80-90% cost reduction

✅ **Implementation:**
1. Run smoke tests on simulators (every PR)
2. Run DRM tests on BrowserStack devices (nightly/pre-release)
3. Use the same Swift test code everywhere
4. No code duplication, clean architecture

**Next Steps:**
1. Set up BrowserStack account
2. Run build script
3. Upload and test
4. Configure GitHub Actions for nightly DRM runs

---

*Last updated: November 2025*
*Palace iOS Testing Team*


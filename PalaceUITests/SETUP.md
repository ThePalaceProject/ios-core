# PalaceUITests Target Setup

## Current State

The Palace.xcscheme already contains a TestableReference for `PalaceUITests` (BlueprintIdentifier: `E58EAE132ECCC4F700CDA626`, currently `skipped="YES"`). However, the corresponding native target does **not** exist in `Palace.xcodeproj/project.pbxproj`. This means the scheme entry is either a forward reference or a stale artifact.

## Manual Steps to Add the UI Test Target in Xcode

### 1. Add the Target

1. Open `Palace.xcodeproj` (or `PalaceR2.xcworkspace`) in Xcode.
2. Select the project in the Project Navigator (top-level blue icon).
3. Click the **+** button at the bottom of the targets list.
4. Choose **iOS > Test > UI Testing Bundle**.
5. Set the following:
   - **Product Name:** `PalaceUITests`
   - **Target to be Tested:** `Palace`
   - **Language:** Swift
   - **Bundle Identifier:** `org.thepalaceproject.palaceUITests`
6. Click **Finish**.

### 2. Replace the Auto-Generated Test File

Xcode will create a default test file. Replace its contents with the existing `PalaceUITests/PalaceUITests.swift` from this directory, or simply delete the generated file and drag in the one from this directory.

### 3. Verify Build Settings

In the new target's **Build Settings**, confirm:

- **IPHONEOS_DEPLOYMENT_TARGET:** `16.0` (must match the main app target)
- **TEST_TARGET_NAME:** `Palace`
- **SWIFT_VERSION:** Match the project default (currently `4.2` in PalaceTests, but `5.0` is recommended for new targets)
- **DEVELOPMENT_TEAM:** `88CBA74T8K`
- **CODE_SIGN_STYLE:** `Manual`

### 4. Update the Scheme

The scheme already has a `<TestableReference>` for PalaceUITests. After adding the target:

1. Go to **Product > Scheme > Edit Scheme...**
2. Select the **Test** action.
3. If PalaceUITests does not appear, click **+** and add it.
4. Uncheck **skipped** if you want it to run by default.
5. Optionally enable **parallelizable** for faster execution.

### 5. Key Differences from Unit Tests (PalaceTests)

| Setting | PalaceTests (unit) | PalaceUITests (UI) |
|---|---|---|
| `productType` | `com.apple.product-type.bundle.unit-test` | `com.apple.product-type.bundle.ui-testing` |
| `TEST_HOST` | `$(BUILT_PRODUCTS_DIR)/Palace.app/Palace` | *(not set)* |
| `BUNDLE_LOADER` | `$(TEST_HOST)` | *(not set)* |
| `TEST_TARGET_NAME` | *(not set)* | `Palace` |

UI test bundles run as a **separate process** that drives the app via XCUIApplication, so they do not load inside the app's process (no `TEST_HOST`/`BUNDLE_LOADER`).

### 6. Running UI Tests

```bash
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
  -only-testing:PalaceUITests
```

### 7. CI Considerations

- UI tests require a booted simulator with a GUI session (or `xcrun simctl boot`).
- They are significantly slower than unit tests; consider running them in a separate CI job.
- The scheme currently has `skipped="YES"` for PalaceUITests, so CI will not run them until that flag is changed.

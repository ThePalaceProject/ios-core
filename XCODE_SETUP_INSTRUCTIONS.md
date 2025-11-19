# Xcode Project Setup - PalaceUITests Target

**Step-by-step guide to add PalaceUITests target and files to Palace.xcodeproj**

---

## 🎯 What We're Adding

- ✅ New **PalaceUITests** target (UI test bundle)
- ✅ All test files (15+ Swift files)
- ✅ .feature files (Gherkin scenarios)
- ✅ Dependencies (Cucumberish + swift-snapshot-testing)
- ✅ AccessibilityIdentifiers.swift to Palace target

---

## 📋 Step-by-Step Instructions

### **Step 1: Create PalaceUITests Target (5 minutes)**

**In Xcode (should be open):**

1. Select **Palace** project (blue icon, left sidebar)
2. At bottom of **TARGETS** list, click **+** button
3. Select **iOS** → **UI Testing Bundle**
4. Click **Next**
5. **Product Name:** `PalaceUITests`
6. **Team:** Select your team
7. **Project:** Palace
8. **Target to be Tested:** Palace
9. Click **Finish**

✅ New `PalaceUITests` target created!

---

### **Step 2: Add Swift Package Dependencies (5 minutes)**

**Add Cucumberish:**

1. File → Add Package Dependencies
2. Search: `https://github.com/Ahmed-Ali/Cucumberish.git`
3. **Dependency Rule:** Up to Next Major Version: 4.0.0
4. Click **Add Package**
5. **Add to Target:** Check ✅ **PalaceUITests**
6. Click **Add Package**

**Add swift-snapshot-testing:**

1. File → Add Package Dependencies
2. Search: `https://github.com/pointfreeco/swift-snapshot-testing.git`
3. **Dependency Rule:** Up to Next Major Version: 1.15.0
4. Click **Add Package**
5. **Add to Target:** Check ✅ **PalaceUITests**
6. Click **Add Package**

✅ Dependencies added!

---

### **Step 3: Add Test Files to PalaceUITests Target (10 minutes)**

**In Project Navigator:**

1. **Right-click** `PalaceUITests` folder (left sidebar)
2. **Delete** the auto-generated `PalaceUITestsLaunchTests.swift` file
3. **Right-click** `PalaceUITests` folder again
4. Select **Add Files to "PalaceUITests"...**
5. Navigate to `/Users/mauricework/PalaceProject/ios-core/PalaceUITests/`
6. **Select ALL folders:**
   - ✅ Features/
   - ✅ Steps/
   - ✅ Screens/
   - ✅ Helpers/
   - ✅ Extensions/
   - ✅ Tests/
   - ✅ PalaceUITests.swift
   - ✅ Info.plist
7. **Options:**
   - ✅ **Copy items if needed:** YES
   - ✅ **Create groups:** YES
   - ✅ **Add to targets:** Check **PalaceUITests** only
8. Click **Add**

✅ All test files added!

---

### **Step 4: Add AccessibilityIdentifiers.swift to Palace Target (3 minutes)**

**This is CRITICAL - the app needs these identifiers to compile!**

1. In Project Navigator, navigate to `Palace` group
2. **Right-click** `Utilities` folder
3. Select **New Group** → Name it `Testing`
4. **Right-click** the new `Testing` folder
5. Select **Add Files to "Palace"...**
6. Navigate to and select:
   ```
   /Users/mauricework/PalaceProject/ios-core/Palace/Utilities/Testing/AccessibilityIdentifiers.swift
   ```
7. **Options:**
   - ✅ **Copy items if needed:** NO (already in right location)
   - ✅ **Create groups:** YES
   - ✅ **Add to targets:** Check ✅ **Palace** and ✅ **Palace-noDRM**
   - ❌ **Uncheck PalaceUITests** (tests import from main app)
8. Click **Add**

✅ AccessibilityIdentifiers added to Palace target!

---

### **Step 5: Configure Test Scheme (3 minutes)**

1. Product → Scheme → **Edit Scheme...** (or press `⌘<`)
2. Select **Test** section (left sidebar)
3. Click **+** button (bottom left)
4. Select **PalaceUITests** → Click **Add**
5. Expand **PalaceUITests** → You should see:
   - `CucumberishInitializer`
   - `SmokeTests`
   - Other test classes
6. **Check all test classes**
7. Select **Arguments** tab
8. Add **Environment Variables:**
   - `TEST_MODE` = `1`
   - `SKIP_ANIMATIONS` = `1`
   - `LYRASIS_BARCODE` = `01230000000002` (optional, or use secret)
   - `LYRASIS_PIN` = `Lyrtest123` (optional, or use secret)
9. Click **Close**

✅ Test scheme configured!

---

### **Step 6: Build and Verify (2 minutes)**

1. Select **Palace** scheme (top left)
2. Select **iPhone 15 Pro** simulator
3. **Build:** Press `⌘B`
4. **Verify:** Build succeeds without errors

✅ If build succeeds, Accessibility IDs are properly integrated!

---

### **Step 7: Add .feature Files as Resources (5 minutes)**

**Important: Cucumberish needs to find .feature files!**

1. Select **PalaceUITests** target (middle panel)
2. Select **Build Phases** tab
3. Expand **Copy Bundle Resources**
4. Click **+** button
5. **Add Files...**
6. Navigate to `PalaceUITests/Features/`
7. Select all **.feature** files:
   - SmokeTests.feature
   - AudiobookPlayback.feature
8. Click **Add**

✅ .feature files will be bundled with tests!

---

## ✅ Verification Checklist

After completing all steps, verify:

- [ ] **PalaceUITests** target exists
- [ ] **Cucumberish** package added
- [ ] **swift-snapshot-testing** package added
- [ ] All test files visible in Project Navigator under PalaceUITests
- [ ] **AccessibilityIdentifiers.swift** in Palace/Utilities/Testing
- [ ] **AccessibilityIdentifiers.swift** has Palace target membership
- [ ] .feature files in **Copy Bundle Resources** build phase
- [ ] Test scheme includes PalaceUITests
- [ ] Build succeeds (⌘B)

---

## 🧪 Run Your First Test!

Once setup is complete:

```bash
# Option 1: Run in Xcode
# Press ⌘U to run all tests

# Option 2: Run specific feature
# In Xcode, navigate to Features/SmokeTests.feature
# Click the diamond icon next to a scenario
# Or press ⌘U with file open

# Option 3: Command line
xcodebuild test \
  -project Palace.xcodeproj \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PalaceUITests
```

---

## 🐛 Troubleshooting

### Issue: "Cannot find 'Cucumberish' in scope"

**Solution:**
- Verify Cucumberish package is added
- Check PalaceUITests target has Cucumberish in dependencies
- Clean build folder: `⌘⇧K`
- Rebuild: `⌘B`

### Issue: "Cannot find 'AccessibilityID' in scope"

**Solution:**
- Verify AccessibilityIdentifiers.swift is added to **Palace** target (not PalaceUITests)
- Check target membership in File Inspector (right sidebar)
- Rebuild Palace target

### Issue: "Feature files not found"

**Solution:**
- Verify .feature files are in **Copy Bundle Resources** build phase
- Check they're in PalaceUITests/Features/ directory
- Rebuild

### Issue: Build fails with accessibility identifier errors in app code

**Solution:**
- AccessibilityIdentifiers.swift must be in Palace target
- Open AppTabHostView.swift - verify it imports correctly
- Check File Inspector shows Palace target membership

---

## 📝 File Structure (After Setup)

```
Palace.xcodeproj
├── Palace (target)
│   └── Utilities/
│       └── Testing/
│           └── AccessibilityIdentifiers.swift ✅ Added
│
└── PalaceUITests (target) ✅ Created
    ├── Features/                    ✅ Added
    │   ├── SmokeTests.feature
    │   └── AudiobookPlayback.feature
    ├── Steps/                       ✅ Added
    │   ├── PalaceNavigationSteps.swift
    │   ├── PalaceSearchSteps.swift
    │   ├── PalaceBookActionSteps.swift
    │   ├── PalaceAudiobookSteps.swift
    │   └── PalaceAssertionSteps.swift
    ├── Screens/                     ✅ Added
    │   ├── BaseScreen.swift
    │   ├── CatalogScreen.swift
    │   ├── SearchScreen.swift
    │   ├── BookDetailScreen.swift
    │   ├── MyBooksScreen.swift
    │   └── AudiobookPlayerScreen.swift
    ├── Helpers/                     ✅ Added
    │   ├── TestHelpers.swift
    │   ├── BaseTestCase.swift
    │   └── TestConfiguration.swift
    ├── Extensions/                  ✅ Added
    │   └── XCUIElement+Extensions.swift
    ├── Tests/                       ✅ Added
    │   └── Smoke/
    │       └── SmokeTests.swift
    ├── PalaceUITests.swift          ✅ Added (Cucumberish runner)
    └── Info.plist                   ✅ Added
```

---

## 🎉 When Complete

You'll have:
- ✅ Working Cucumberish integration
- ✅ Sample .feature files
- ✅ Complete step library
- ✅ Audiobook playback testing
- ✅ Ready for visual snapshot tests

**Run tests with:** `⌘U` in Xcode

---

*Follow these steps carefully and you'll have a working test suite!*



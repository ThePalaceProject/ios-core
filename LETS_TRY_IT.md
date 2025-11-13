# Let's Try BrowserStack! 🚀

**Hands-on walkthrough to run your first test on BrowserStack**

---

## 📋 Checklist

Before we start, you need:
- [ ] BrowserStack account (free trial available)
- [ ] Your BrowserStack username and access key
- [ ] Xcode 15.2+ installed
- [ ] Palace project on your Mac

---

## 🎯 Step-by-Step Guide

### Step 1: Get BrowserStack Credentials (5 minutes)

**Option A: Already have an account?**
1. Go to https://app-automate.browserstack.com/dashboard
2. Click your name (top right) → "Access Key"
3. Copy your Username and Access Key

**Option B: Need an account?**
1. Go to https://www.browserstack.com/users/sign_up
2. Sign up (free trial available)
3. Once logged in, get your credentials from dashboard

### Step 2: Set Your Credentials (1 minute)

Open Terminal and run:

```bash
cd /Users/mauricework/PalaceProject/ios-core
source ./scripts/setup-browserstack-env.sh
```

This will:
- Prompt for your username and access key
- Set them for this session
- Optionally save to `~/.zshrc` for future sessions

**Verify it worked:**
```bash
echo $BROWSERSTACK_USERNAME
# Should show your username
```

### Step 3: Build Palace for BrowserStack (5-10 minutes)

**Build the app with DRM support:**

```bash
./scripts/build-for-browserstack.sh Palace
```

**What this does:**
- Builds Palace.app with full DRM support
- Builds PalaceUITests-Runner.app (test suite)
- Prepares for physical device testing
- Saves to `build/` directory

**Expected output:**
```
🏗️  Building Palace for BrowserStack...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🧹 Cleaning previous builds...
🔨 Building Palace...
✅ Build successful!
```

**⏱️ This takes 5-10 minutes - grab a coffee!**

### Step 4: Upload to BrowserStack (2 minutes)

**Upload your app and tests:**

```bash
./scripts/upload-to-browserstack.sh
```

**What this does:**
- Zips Palace.app and PalaceUITests-Runner.app
- Uploads both to BrowserStack
- Returns custom IDs for running tests

**Expected output:**
```
📦 Preparing upload to BrowserStack...
⬆️  Uploading app to BrowserStack...
✅ App uploaded successfully
   Custom ID: Palace-DRM-20251112-113000

⬆️  Uploading test suite to BrowserStack...
✅ Test suite uploaded successfully
   Custom ID: PalaceUITests-20251112-113000
```

**💡 Save these IDs!** The script auto-saves them to `build/` directory.

### Step 5: Run a Test on BrowserStack! (5-10 minutes)

**Option A: Run ALL tests (longer)**
```bash
./scripts/run-browserstack-tests.sh
```

**Option B: Run SMOKE tests only (recommended for first try)**
```bash
./scripts/run-browserstack-tests.sh \
  $(cat build/.last-app-id) \
  $(cat build/.last-test-id) \
  "iPhone 15 Pro-17.0" \
  "PalaceUITests.SmokeTests"
```

**What this does:**
- Starts test execution on a real iPhone 15 Pro
- Records video of the test
- Captures device logs
- Takes screenshots on failures

**Expected output:**
```
🧪 Running tests on BrowserStack...
Device: iPhone 15 Pro-17.0
Test Class: PalaceUITests.SmokeTests

✅ Test execution started!
Build ID: abc123def456

📊 View live results:
https://app-automate.browserstack.com/dashboard/v2/builds/abc123def456
```

### Step 6: Watch Your Tests Run! (Live)

**Open the BrowserStack dashboard:**

1. Click the link from Step 5 output
2. Or go to: https://app-automate.browserstack.com/dashboard
3. Find your build (should be running)
4. Click to watch **LIVE video** of tests executing on real iPhone!

**You'll see:**
- 📹 Live video feed from physical iPhone
- 📊 Test progress and results
- 🖼️ Screenshots at each step
- 📝 Device logs
- 🌐 Network traffic

---

## 🎬 What You'll See in BrowserStack

### While Tests Are Running:

```
┌─────────────────────────────────────┐
│  iPhone 15 Pro (Physical Device)   │
│  iOS 17.0                           │
│                                     │
│  [Live Video Stream]                │
│   Your app opening...               │
│   Tests executing...                │
│   Tapping buttons...                │
│                                     │
│  Status: Running (3/10 tests)      │
└─────────────────────────────────────┘
```

### When Complete:

```
✅ Test Results
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
10 tests run
9 passed ✅
1 failed ❌

📹 Video: Download
📝 Logs: Download
🖼️ Screenshots: View
```

---

## 🚨 Troubleshooting

### Issue: "BrowserStack credentials not set"

**Solution:**
```bash
# Make sure you ran this first:
source ./scripts/setup-browserstack-env.sh

# Verify:
echo $BROWSERSTACK_USERNAME
```

---

### Issue: "App not found at build path"

**Solution:**
```bash
# Build first:
./scripts/build-for-browserstack.sh Palace

# Then upload:
./scripts/upload-to-browserstack.sh
```

---

### Issue: Build fails with code signing error

**Solution:**

You need a valid iOS development certificate. Quick fix:

```bash
# Build with automatic signing
./scripts/build-for-browserstack.sh Palace

# If that fails, check Xcode:
open Palace.xcodeproj
# Go to Signing & Capabilities
# Select your Team
# Enable "Automatically manage signing"
```

---

### Issue: "Custom ID not found"

**Solution:**

The upload probably failed. Check the output of `upload-to-browserstack.sh`.

Or manually specify IDs:
```bash
./scripts/run-browserstack-tests.sh \
  "your-app-id" \
  "your-test-id" \
  "iPhone 15 Pro-17.0"
```

---

## 💰 Cost Estimate

### Free Trial:
- BrowserStack offers **100 minutes free** trial
- Perfect for testing this setup!

### After Trial:
- **$29/month** (Starter) - 100 minutes/month
- **$99/month** (Professional) - Unlimited parallel tests

### For Your Use Case:
- Run **40 DRM tests nightly** = ~20 min/day = **600 min/month**
- Recommended: **Professional plan** (~$99/month)
- **Savings:** $400/month vs running all tests on devices

---

## 🎯 Quick Commands Summary

```bash
# 1. Set credentials (first time only)
source ./scripts/setup-browserstack-env.sh

# 2. Build app for BrowserStack
./scripts/build-for-browserstack.sh Palace

# 3. Upload to BrowserStack
./scripts/upload-to-browserstack.sh

# 4. Run tests
./scripts/run-browserstack-tests.sh

# 5. View results
# Click the link in the output or go to:
# https://app-automate.browserstack.com/dashboard
```

---

## 🎓 Next Steps After First Success

### 1. Create DRM-Specific Tests

Create `PalaceUITests/Tests/DRM/LCPAudiobookTests.swift`:

```swift
final class LCPAudiobookTests: BaseTestCase {
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    // Skip if running on simulator
    #if targetEnvironment(simulator)
    throw XCTSkip("LCP DRM tests require physical device")
    #endif
  }
  
  func testLCPAudiobookPlayback() {
    // Your LCP audiobook test here
    signIn(with: TestConfiguration.Library.lyrasisReads.credentials!)
    // ... download and play LCP audiobook
  }
}
```

### 2. Set Up Nightly Runs

Add to `.github/workflows/ui-tests.yml`:

```yaml
  browserstack-nightly:
    name: BrowserStack DRM Tests (Nightly)
    runs-on: macos-14
    if: github.event.schedule
    
    steps:
      - name: Build for BrowserStack
        run: ./scripts/build-for-browserstack.sh Palace
      
      - name: Upload and Run
        run: |
          ./scripts/upload-to-browserstack.sh
          ./scripts/run-browserstack-tests.sh
        env:
          BROWSERSTACK_USERNAME: ${{ secrets.BROWSERSTACK_USERNAME }}
          BROWSERSTACK_ACCESS_KEY: ${{ secrets.BROWSERSTACK_ACCESS_KEY }}
```

### 3. Optimize Costs

Run only DRM-dependent tests on BrowserStack:

```bash
# Only run LCP tests (saves money)
./scripts/run-browserstack-tests.sh \
  "app-id" \
  "test-id" \
  "iPhone 15 Pro-17.0" \
  "PalaceUITests.LCPAudiobookTests"
```

---

## 🎉 Success Indicators

You'll know it's working when you see:

✅ **Build completes** without errors  
✅ **Upload succeeds** with custom IDs  
✅ **BrowserStack dashboard** shows your build  
✅ **Live video** shows your app running  
✅ **Tests execute** on real iPhone  
✅ **Results appear** in dashboard  

---

## 📞 Need Help?

### Documentation:
- Full guide: `cat PalaceUITests/BROWSERSTACK_INTEGRATION.md`
- Quick ref: `cat BROWSERSTACK_SETUP.md`

### BrowserStack Support:
- Docs: https://www.browserstack.com/docs/app-automate/xcuitest
- Support: https://www.browserstack.com/contact

### Palace Team:
- Slack: `#ios-testing`
- GitHub: Open issue with `[BrowserStack]` prefix

---

## 🚀 Let's Go!

**Ready?** Run these 4 commands:

```bash
cd /Users/mauricework/PalaceProject/ios-core
source ./scripts/setup-browserstack-env.sh
./scripts/build-for-browserstack.sh Palace
./scripts/upload-to-browserstack.sh
./scripts/run-browserstack-tests.sh
```

**Then open:** https://app-automate.browserstack.com/dashboard

**Watch your tests run on a real iPhone! 🎬📱**

---

*Created: November 2025*  
*Palace iOS Testing Team*


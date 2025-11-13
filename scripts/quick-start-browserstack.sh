#!/bin/bash
#
# Interactive quick-start for BrowserStack testing
# Run: ./scripts/quick-start-browserstack.sh
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo ""
echo "╔═══════════════════════════════════════════════════╗"
echo "║   🚀 BrowserStack Quick Start for Palace iOS   ║"
echo "╚═══════════════════════════════════════════════════╝"
echo ""
echo "This script will help you run your first test on BrowserStack!"
echo ""

# Check if we're in the right directory
cd "$PROJECT_ROOT"

# Step 1: Check BrowserStack credentials
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: BrowserStack Credentials"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -z "$BROWSERSTACK_USERNAME" ] || [ -z "$BROWSERSTACK_ACCESS_KEY" ]; then
    echo "❌ BrowserStack credentials not set"
    echo ""
    echo "Do you have a BrowserStack account?"
    echo "  1) Yes, I have credentials"
    echo "  2) No, I need to sign up first"
    echo ""
    echo -n "Choose (1 or 2): "
    read ACCOUNT_CHOICE
    
    if [ "$ACCOUNT_CHOICE" = "2" ]; then
        echo ""
        echo "📝 Go to: https://www.browserstack.com/users/sign_up"
        echo "   Sign up for free trial, then come back here"
        echo ""
        echo -n "Press Enter when you have your credentials..."
        read
    fi
    
    echo ""
    echo "Let's set your credentials:"
    echo ""
    echo -n "BrowserStack Username: "
    read BROWSERSTACK_USERNAME
    echo -n "BrowserStack Access Key (hidden): "
    read -s BROWSERSTACK_ACCESS_KEY
    echo ""
    
    export BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"
    export BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"
    
    echo ""
    echo -n "Save credentials to ~/.zshrc? (y/n): "
    read SAVE_CHOICE
    
    if [ "$SAVE_CHOICE" = "y" ] || [ "$SAVE_CHOICE" = "Y" ]; then
        if ! grep -q "BROWSERSTACK_USERNAME" ~/.zshrc 2>/dev/null; then
            echo "" >> ~/.zshrc
            echo "# BrowserStack credentials" >> ~/.zshrc
            echo "export BROWSERSTACK_USERNAME=\"$BROWSERSTACK_USERNAME\"" >> ~/.zshrc
            echo "export BROWSERSTACK_ACCESS_KEY=\"$BROWSERSTACK_ACCESS_KEY\"" >> ~/.zshrc
            echo "✅ Saved to ~/.zshrc"
        fi
    fi
else
    echo "✅ Credentials already set"
    echo "   Username: $BROWSERSTACK_USERNAME"
fi

echo ""
echo -n "Press Enter to continue to Step 2..."
read
echo ""

# Step 2: Build
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Build Palace for BrowserStack"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "We'll build Palace.app with DRM support for testing."
echo "⏱️  This takes 5-10 minutes..."
echo ""
echo -n "Ready to build? (y/n): "
read BUILD_CHOICE

if [ "$BUILD_CHOICE" != "y" ] && [ "$BUILD_CHOICE" != "Y" ]; then
    echo ""
    echo "No problem! Run this script again when ready."
    exit 0
fi

echo ""
echo "🏗️  Building..."
./scripts/build-for-browserstack.sh Palace

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Build failed. Check the error messages above."
    echo ""
    echo "Common fixes:"
    echo "  1. Open Xcode: open Palace.xcodeproj"
    echo "  2. Go to Signing & Capabilities"
    echo "  3. Select your Team"
    echo "  4. Enable 'Automatically manage signing'"
    echo ""
    exit 1
fi

echo ""
echo -n "Press Enter to continue to Step 3..."
read
echo ""

# Step 3: Upload
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Upload to BrowserStack"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Now we'll upload your app and tests to BrowserStack."
echo "⏱️  This takes 1-2 minutes..."
echo ""
echo -n "Ready to upload? (y/n): "
read UPLOAD_CHOICE

if [ "$UPLOAD_CHOICE" != "y" ] && [ "$UPLOAD_CHOICE" != "Y" ]; then
    echo ""
    echo "No problem! You can upload later with:"
    echo "  ./scripts/upload-to-browserstack.sh"
    exit 0
fi

echo ""
echo "⬆️  Uploading..."
./scripts/upload-to-browserstack.sh

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Upload failed. Check the error messages above."
    exit 1
fi

echo ""
echo -n "Press Enter to continue to Step 4..."
read
echo ""

# Step 4: Run tests
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Run Tests on BrowserStack!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Which tests would you like to run?"
echo "  1) All smoke tests (recommended for first try)"
echo "  2) Single test (fastest)"
echo "  3) All tests (longest)"
echo ""
echo -n "Choose (1, 2, or 3): "
read TEST_CHOICE

case $TEST_CHOICE in
    1)
        TEST_CLASS="PalaceUITests.SmokeTests"
        echo ""
        echo "Running all 10 smoke tests (~10 minutes)"
        ;;
    2)
        TEST_CLASS="PalaceUITests.SmokeTests/testAppLaunchAndTabNavigation"
        echo ""
        echo "Running single test (~1 minute)"
        ;;
    3)
        TEST_CLASS=""
        echo ""
        echo "Running ALL tests (~30 minutes)"
        ;;
    *)
        TEST_CLASS="PalaceUITests.SmokeTests"
        echo ""
        echo "Running smoke tests by default"
        ;;
esac

echo ""
echo "Device: iPhone 15 Pro (iOS 17.0)"
echo ""
echo -n "Ready to run? (y/n): "
read RUN_CHOICE

if [ "$RUN_CHOICE" != "y" ] && [ "$RUN_CHOICE" != "Y" ]; then
    echo ""
    echo "No problem! You can run tests later with:"
    echo "  ./scripts/run-browserstack-tests.sh"
    exit 0
fi

echo ""
echo "🧪 Starting test execution..."
echo ""

if [ -n "$TEST_CLASS" ]; then
    ./scripts/run-browserstack-tests.sh \
        "$(cat build/.last-app-id)" \
        "$(cat build/.last-test-id)" \
        "iPhone 15 Pro-17.0" \
        "$TEST_CLASS"
else
    ./scripts/run-browserstack-tests.sh \
        "$(cat build/.last-app-id)" \
        "$(cat build/.last-test-id)" \
        "iPhone 15 Pro-17.0"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Test execution started!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎬 Watch your tests run LIVE at:"
echo "   https://app-automate.browserstack.com/dashboard"
echo ""
echo "You'll see:"
echo "  📹 Live video from real iPhone"
echo "  📊 Test progress in real-time"
echo "  🖼️  Screenshots at each step"
echo "  📝 Device logs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎉 Congratulations! Your first BrowserStack test is running!"
echo ""
echo "Next steps:"
echo "  1. Watch the dashboard for results"
echo "  2. Read: cat LETS_TRY_IT.md"
echo "  3. Create DRM-specific tests"
echo ""


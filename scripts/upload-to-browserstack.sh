#!/bin/bash
#
# Upload app and tests to BrowserStack
#

set -e

# Check credentials
BROWSERSTACK_USERNAME="${BROWSERSTACK_USERNAME}"
BROWSERSTACK_ACCESS_KEY="${BROWSERSTACK_ACCESS_KEY}"

if [ -z "$BROWSERSTACK_USERNAME" ] || [ -z "$BROWSERSTACK_ACCESS_KEY" ]; then
    echo "❌ Error: BrowserStack credentials not set"
    echo ""
    echo "Set environment variables:"
    echo "  export BROWSERSTACK_USERNAME='your-username'"
    echo "  export BROWSERSTACK_ACCESS_KEY='your-access-key'"
    echo ""
    echo "Or add to your ~/.zshrc or ~/.bashrc:"
    echo "  export BROWSERSTACK_USERNAME='your-username'"
    echo "  export BROWSERSTACK_ACCESS_KEY='your-access-key'"
    exit 1
fi

# Paths
APP_PATH="build/Build/Products/Debug-iphoneos/Palace.app"
TEST_RUNNER_PATH="build/Build/Products/Debug-iphoneos/PalaceUITests-Runner.app"
APP_ZIP="build/Palace-$(date +%Y%m%d-%H%M%S).zip"
TEST_ZIP="build/PalaceUITests-$(date +%Y%m%d-%H%M%S).zip"

# Check if build artifacts exist
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at $APP_PATH"
    echo "Run: ./scripts/build-for-browserstack.sh"
    exit 1
fi

if [ ! -d "$TEST_RUNNER_PATH" ]; then
    echo "❌ Error: Test runner not found at $TEST_RUNNER_PATH"
    echo "Run: ./scripts/build-for-browserstack.sh"
    exit 1
fi

echo "📦 Preparing upload to BrowserStack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Zip app
echo "📦 Zipping app..."
cd build/Build/Products/Debug-iphoneos/
zip -r -q "../../../../$APP_ZIP" Palace.app
cd - > /dev/null

# Zip test runner
echo "📦 Zipping test runner..."
cd build/Build/Products/Debug-iphoneos/
zip -r -q "../../../../$TEST_ZIP" PalaceUITests-Runner.app
cd - > /dev/null

echo ""
echo "⬆️  Uploading app to BrowserStack..."

# Upload app
APP_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/upload" \
  -F "file=@$APP_ZIP" \
  -F "custom_id=Palace-DRM-$(date +%Y%m%d-%H%M%S)")

# Parse response
if echo "$APP_RESPONSE" | grep -q "app_url"; then
    APP_URL=$(echo "$APP_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['app_url'])" 2>/dev/null || echo "")
    CUSTOM_ID=$(echo "$APP_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['custom_id'])" 2>/dev/null || echo "")
    
    echo "✅ App uploaded successfully"
    echo "   App URL: $APP_URL"
    echo "   Custom ID: $CUSTOM_ID"
else
    echo "❌ App upload failed"
    echo "$APP_RESPONSE"
    exit 1
fi

echo ""
echo "⬆️  Uploading test suite to BrowserStack..."

# Upload test suite
TEST_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/test-suite" \
  -F "file=@$TEST_ZIP" \
  -F "custom_id=PalaceUITests-$(date +%Y%m%d-%H%M%S)")

# Parse response
if echo "$TEST_RESPONSE" | grep -q "test_suite_url"; then
    TEST_SUITE_URL=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['test_suite_url'])" 2>/dev/null || echo "")
    TEST_CUSTOM_ID=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['custom_id'])" 2>/dev/null || echo "")
    
    echo "✅ Test suite uploaded successfully"
    echo "   Test URL: $TEST_SUITE_URL"
    echo "   Custom ID: $TEST_CUSTOM_ID"
else
    echo "❌ Test suite upload failed"
    echo "$TEST_RESPONSE"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Upload complete!"
echo ""
echo "📝 Run tests with:"
echo "   ./scripts/run-browserstack-tests.sh '$CUSTOM_ID' '$TEST_CUSTOM_ID'"
echo ""
echo "Or use custom IDs:"
echo "   ./scripts/run-browserstack-tests.sh '$CUSTOM_ID' '$TEST_CUSTOM_ID' 'iPhone 15 Pro-17.0'"
echo ""

# Save for easy access
echo "$CUSTOM_ID" > build/.last-app-id
echo "$TEST_CUSTOM_ID" > build/.last-test-id

echo "💾 IDs saved to build/ directory for convenience"
echo ""


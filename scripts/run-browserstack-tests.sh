#!/bin/bash
#
# Run tests on BrowserStack physical devices
#

set -e

# Configuration
BROWSERSTACK_USERNAME="${BROWSERSTACK_USERNAME}"
BROWSERSTACK_ACCESS_KEY="${BROWSERSTACK_ACCESS_KEY}"

# Arguments
APP_ID="${1}"
TEST_SUITE_ID="${2}"
DEVICE="${3:-iPhone 15 Pro-17.0}"
TEST_CLASS="${4:-}"  # Optional: specific test class

# Try to load last uploaded IDs if not provided
if [ -z "$APP_ID" ] && [ -f "build/.last-app-id" ]; then
    APP_ID=$(cat build/.last-app-id)
    echo "📝 Using last uploaded app: $APP_ID"
fi

if [ -z "$TEST_SUITE_ID" ] && [ -f "build/.last-test-id" ]; then
    TEST_SUITE_ID=$(cat build/.last-test-id)
    echo "📝 Using last uploaded test suite: $TEST_SUITE_ID"
fi

# Validate inputs
if [ -z "$BROWSERSTACK_USERNAME" ] || [ -z "$BROWSERSTACK_ACCESS_KEY" ]; then
    echo "❌ Error: BrowserStack credentials not set"
    echo ""
    echo "Set environment variables:"
    echo "  export BROWSERSTACK_USERNAME='your-username'"
    echo "  export BROWSERSTACK_ACCESS_KEY='your-access-key'"
    exit 1
fi

if [ -z "$APP_ID" ] || [ -z "$TEST_SUITE_ID" ]; then
    echo "❌ Error: Missing app ID or test suite ID"
    echo ""
    echo "Usage:"
    echo "  $0 <app-id> <test-suite-id> [device] [test-class]"
    echo ""
    echo "Example:"
    echo "  $0 Palace-DRM-20250101 PalaceUITests-20250101 'iPhone 15 Pro-17.0' PalaceUITests.LCPAudiobookTests"
    echo ""
    echo "Or upload first:"
    echo "  ./scripts/upload-to-browserstack.sh"
    exit 1
fi

echo "🧪 Running tests on BrowserStack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Configuration:"
echo "  App:        $APP_ID"
echo "  Test Suite: $TEST_SUITE_ID"
echo "  Device:     $DEVICE"
if [ -n "$TEST_CLASS" ]; then
    echo "  Test Class: $TEST_CLASS"
fi
echo ""

# Build request payload
if [ -n "$TEST_CLASS" ]; then
    # Run specific test class
    PAYLOAD=$(cat <<EOF
{
  "app": "$APP_ID",
  "testSuite": "$TEST_SUITE_ID",
  "devices": ["$DEVICE"],
  "class": ["$TEST_CLASS"],
  "networkLogs": true,
  "deviceLogs": true,
  "video": true,
  "project": "Palace iOS UI Tests",
  "build": "$(git rev-parse --short HEAD 2>/dev/null || echo 'local')"
}
EOF
)
else
    # Run all tests
    PAYLOAD=$(cat <<EOF
{
  "app": "$APP_ID",
  "testSuite": "$TEST_SUITE_ID",
  "devices": ["$DEVICE"],
  "networkLogs": true,
  "deviceLogs": true,
  "video": true,
  "project": "Palace iOS UI Tests",
  "build": "$(git rev-parse --short HEAD 2>/dev/null || echo 'local')"
}
EOF
)
fi

# Start test execution
echo "🚀 Starting test execution..."
echo ""

BUILD_RESPONSE=$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/xcuitest/v2/build" \
  -d "$PAYLOAD" \
  -H "Content-Type: application/json")

# Parse response
if echo "$BUILD_RESPONSE" | grep -q "build_id"; then
    BUILD_ID=$(echo "$BUILD_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['build_id'])" 2>/dev/null || echo "")
    
    echo "✅ Test execution started!"
    echo ""
    echo "Build ID: $BUILD_ID"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 View live results:"
    echo ""
    echo "   https://app-automate.browserstack.com/dashboard/v2/builds/$BUILD_ID"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⏳ Waiting for tests to complete..."
    echo "   (This may take 5-30 minutes depending on test count)"
    echo ""
    
    # Save build ID
    echo "$BUILD_ID" > build/.last-build-id
    
    # Optional: Poll for completion
    if command -v jq &> /dev/null; then
        echo "💡 Tip: Install jq for automatic status updates"
        echo "   brew install jq"
    fi
    
    echo ""
    echo "To check status manually:"
    echo "  curl -u \$BROWSERSTACK_USERNAME:\$BROWSERSTACK_ACCESS_KEY \\"
    echo "    https://api-cloud.browserstack.com/app-automate/xcuitest/v2/builds/$BUILD_ID | jq"
    echo ""
    
else
    echo "❌ Test execution failed"
    echo ""
    echo "Response:"
    echo "$BUILD_RESPONSE"
    exit 1
fi


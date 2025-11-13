#!/bin/bash
#
# Build Palace app and tests for BrowserStack
# Supports both DRM and non-DRM targets
#

set -e

# Configuration
SCHEME="${1:-Palace}"  # Default to Palace (DRM), can specify Palace-noDRM
CONFIGURATION="Debug"
DERIVED_DATA="$(xcodebuild -showBuildSettings -project Palace.xcodeproj -scheme Palace | grep -m 1 BUILD_DIR | awk '{print $3}' | sed 's/\/Build\/Products//')"
PROJECT="Palace.xcodeproj"
CUSTOM_BUILD_DIR="build/"

echo "🏗️  Building $SCHEME for BrowserStack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if project exists
if [ ! -f "$PROJECT/project.pbxproj" ]; then
    echo "❌ Error: $PROJECT not found"
    echo "Run this script from the ios-core directory"
    exit 1
fi

# Clean previous custom builds
echo "🧹 Cleaning previous builds..."
rm -rf "$CUSTOM_BUILD_DIR"
mkdir -p "$CUSTOM_BUILD_DIR"

# Build for testing (using Xcode's default DerivedData for better SPM support)
echo "🔨 Building $SCHEME..."
echo ""

xcodebuild build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration "$CONFIGURATION" \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  | xcpretty || true

# Find build products in DerivedData
echo ""
echo "🔍 Locating build products..."
DERIVED_DATA_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Palace-* -type d -name "Debug-iphoneos" 2>/dev/null | head -1)

if [ -z "$DERIVED_DATA_PATH" ]; then
  echo "❌ Could not find Debug-iphoneos directory"
  exit 1
fi

SOURCE_APP_PATH="$DERIVED_DATA_PATH/Palace.app"
SOURCE_TEST_RUNNER_PATH="$DERIVED_DATA_PATH/PalaceUITests-Runner.app"

# Copy to our custom build directory for easier access
echo "📦 Copying build products to $CUSTOM_BUILD_DIR..."

if [ -d "$SOURCE_APP_PATH" ]; then
  cp -R "$SOURCE_APP_PATH" "$CUSTOM_BUILD_DIR/"
  APP_PATH="$CUSTOM_BUILD_DIR/Palace.app"
else
  echo "❌ App not found at $SOURCE_APP_PATH"
  exit 1
fi

if [ -d "$SOURCE_TEST_RUNNER_PATH" ]; then
  cp -R "$SOURCE_TEST_RUNNER_PATH" "$CUSTOM_BUILD_DIR/"
  TEST_RUNNER_PATH="$CUSTOM_BUILD_DIR/PalaceUITests-Runner.app"
else
  echo "⚠️  Test runner not found at $SOURCE_TEST_RUNNER_PATH"
  echo "   (This is OK if PalaceUITests target doesn't exist yet)"
  TEST_RUNNER_PATH=""
fi

if [ ! -d "$APP_PATH" ]; then
    echo ""
    echo "❌ Build failed: App not found at $APP_PATH"
    exit 1
fi

if [ ! -d "$TEST_RUNNER_PATH" ]; then
    echo ""
    echo "❌ Build failed: Test runner not found at $TEST_RUNNER_PATH"
    exit 1
fi

echo ""
echo "✅ Build successful!"
echo ""
echo "📦 Build artifacts:"
echo "  App:         $APP_PATH"
echo "  Test Runner: $TEST_RUNNER_PATH"
echo ""
echo "📝 Next steps:"
echo "  1. Upload to BrowserStack:"
echo "     ./scripts/upload-to-browserstack.sh"
echo ""
echo "  2. Run tests:"
echo "     ./scripts/run-browserstack-tests.sh"
echo ""


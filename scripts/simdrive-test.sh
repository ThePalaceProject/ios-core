#!/bin/bash
#
# simdrive-test.sh — Build Palace and run simdrive integration tests
#
# Usage:
#   ./scripts/simdrive-test.sh                    # Build + test
#   ./scripts/simdrive-test.sh --skip-build        # Test only (use last build)
#   ./scripts/simdrive-test.sh --sim-id <UDID>     # Use a specific source sim
#
# Prerequisites:
#   - pip install --pre simdrive
#   - Xcode 26 with iOS Simulator booted
#   - Source sim should have libraries pre-configured (see README)
#
# The script:
#   1. Builds Palace-noDRM for the target simulator
#   2. Locates the .app bundle in DerivedData
#   3. Prints the app_path for use with simdrive MCP tools
#
# For CI/CD, this script prepares the build. The actual test execution
# happens via Claude Code + simdrive MCP tools (AI-driven testing).

set -euo pipefail

# Defaults
SCHEME="Palace-noDRM"
PROJECT="Palace.xcodeproj"
BUNDLE_ID="org.thepalaceproject.palace"
SKIP_BUILD=false

# Source simulator — iPhone 17 Pro (iOS 26) with libraries pre-configured
# Override with --sim-id
SIM_ID="${SIMDRIVE_SIM_ID:-0423F115-F7CE-4406-BB2B-877DFFCEED1C}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-build) SKIP_BUILD=true; shift ;;
    --sim-id) SIM_ID="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== simdrive Test Runner ==="
echo "  Scheme:    $SCHEME"
echo "  Source Sim: $SIM_ID"
echo ""

# Step 1: Build
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building $SCHEME..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_ID" \
    -derivedDataPath "$REPO_ROOT/.build/simdrive" \
    -quiet \
    build

  if [ $? -ne 0 ]; then
    echo "ERROR: Build failed"
    exit 1
  fi
  echo ">>> Build succeeded"
else
  echo ">>> Skipping build (--skip-build)"
fi

# Step 2: Find .app bundle
APP_PATH=""

# Check our dedicated build dir first
if [ -d "$REPO_ROOT/.build/simdrive/Build/Products/Debug-iphonesimulator/Palace.app" ]; then
  APP_PATH="$REPO_ROOT/.build/simdrive/Build/Products/Debug-iphonesimulator/Palace.app"
fi

# Fallback: check Xcode DerivedData
if [ -z "$APP_PATH" ]; then
  APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Palace-*/Build/Products/Debug-iphonesimulator/Palace.app \
    -maxdepth 0 -type d 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Could not find Palace.app — build first"
  exit 1
fi

# Verify bundle
VERSION=$(plutil -p "$APP_PATH/Info.plist" | grep CFBundleShortVersionString | awk -F'"' '{print $4}')
BUILD=$(plutil -p "$APP_PATH/Info.plist" | grep CFBundleVersion | awk -F'"' '{print $4}')
echo ">>> Found Palace.app v${VERSION} (${BUILD})"
echo "    Path: $APP_PATH"

# Step 3: Install on source sim (so clone inherits it)
echo ">>> Installing on source sim $SIM_ID..."
xcrun simctl install "$SIM_ID" "$APP_PATH"
echo ">>> Installed successfully"

# Step 4: Output config for simdrive
echo ""
echo "=== Ready for simdrive ==="
echo ""
echo "  Start a session in Claude Code with:"
echo ""
echo "    bundle_id: $BUNDLE_ID"
echo "    device_id: $SIM_ID"
echo "    app_path:  $APP_PATH"
echo ""
echo "  Or set these environment variables:"
echo ""
echo "    export SIMDRIVE_APP_PATH=\"$APP_PATH\""
echo "    export SIMDRIVE_SIM_ID=\"$SIM_ID\""
echo "    export SIMDRIVE_BUNDLE_ID=\"$BUNDLE_ID\""
echo ""

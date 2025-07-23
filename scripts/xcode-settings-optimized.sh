#!/bin/bash

# SUMMARY
#   Optimized configuration for building Palace app with performance improvements.
#
# USAGE
#   Source this script from other scripts (e.g. xcode-archive.sh)
#
# PERFORMANCE IMPROVEMENTS
#   - Caches build settings queries to avoid repeated xcodebuild calls
#   - Provides parallel execution helpers
#   - Optimizes environment variables for faster builds

set -eo pipefail

fatal()
{
  echo "$0 error: $1" 1>&2
  exit 1
}

# Performance: Cache directory for build settings
CACHE_DIR=".build-cache"
mkdir -p "$CACHE_DIR"
BUILD_SETTINGS_CACHE="$CACHE_DIR/build-settings.cache"
PROJECT_HASH_FILE="$CACHE_DIR/project.hash"

# Calculate project file hash for cache invalidation
calculate_project_hash() {
  if [ -f "Palace.xcodeproj/project.pbxproj" ]; then
    shasum -a 256 "Palace.xcodeproj/project.pbxproj" | cut -d' ' -f1
  else
    echo "no-project"
  fi
}

# Set Xcode version if specified
if [ -n "$XCODE_VERSION" ]; then
  export DEVELOPER_DIR="/Applications/Xcode_${XCODE_VERSION}.app/Contents/Developer"
  if [ ! -d "$DEVELOPER_DIR" ]; then
    fatal "Xcode ${XCODE_VERSION} not found at ${DEVELOPER_DIR}"
  fi
else
  # Default to Xcode 16.2 if not specified
  export DEVELOPER_DIR="/Applications/Xcode_16.2.app/Contents/Developer"

  if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "Warning: Xcode 16.2 not found at ${DEVELOPER_DIR}, falling back to system default"
    unset DEVELOPER_DIR
  fi
fi

# Performance: Set optimal build environment
export FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT=600
export FASTLANE_XCODEBUILD_SETTINGS_RETRIES=2

# Enable Xcode build optimizations
export COMPILER_INDEX_STORE_ENABLE=NO  # Disable indexing during builds
export CLANG_INDEX_STORE_ENABLE=NO
export SWIFT_INDEX_STORE_ENABLE=NO

# Optimize for current architecture in debug builds
if [ "$CONFIGURATION" == "Debug" ] || [ "$BUILD_CONTEXT" == "dev" ]; then
  export ONLY_ACTIVE_ARCH=YES
  export DEBUG_INFORMATION_FORMAT=dwarf  # Faster than dwarf-with-dsym
fi

# determine which app we're going to work on
TARGET_NAME=Palace
SCHEME=Palace

# app-agnostic settings
APP_NAME="Palace"
PROV_PROFILES_DIR_PATH="$HOME/Library/MobileDevice/Provisioning Profiles"
PROJECT_NAME=Palace.xcodeproj
BUILD_PATH="./Build"

# Performance: Use cached build settings if project hasn't changed
CURRENT_PROJECT_HASH=$(calculate_project_hash)
CACHED_PROJECT_HASH=""

if [ -f "$PROJECT_HASH_FILE" ]; then
  CACHED_PROJECT_HASH=$(cat "$PROJECT_HASH_FILE" 2>/dev/null || echo "")
fi

if [ -f "$BUILD_SETTINGS_CACHE" ] && [ "$CURRENT_PROJECT_HASH" == "$CACHED_PROJECT_HASH" ]; then
  echo "⚡ Using cached build settings"
  source "$BUILD_SETTINGS_CACHE"
else
  echo "🔍 Querying build settings..."
  BUILD_SETTINGS="`xcodebuild -project $PROJECT_NAME -showBuildSettings -target \"$TARGET_NAME\"`"
  VERSION_NUM=`echo "$BUILD_SETTINGS" | grep "MARKETING_VERSION" | sed 's/[ ]*MARKETING_VERSION = //'`
  BUILD_NUM=`echo "$BUILD_SETTINGS" | grep "CURRENT_PROJECT_VERSION" | sed 's/[ ]*CURRENT_PROJECT_VERSION = //'`
  
  # Cache the results
  cat > "$BUILD_SETTINGS_CACHE" << EOF
VERSION_NUM="$VERSION_NUM"
BUILD_NUM="$BUILD_NUM"
EOF
  echo "$CURRENT_PROJECT_HASH" > "$PROJECT_HASH_FILE"
  echo "💾 Cached build settings"
fi

# Derived variables
ARCHIVE_NAME="$APP_NAME-$VERSION_NUM.$BUILD_NUM"
ARCHIVE_FILENAME="$ARCHIVE_NAME.xcarchive"
ARCHIVE_DIR="$BUILD_PATH/$ARCHIVE_NAME"
ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_FILENAME"
ADHOC_EXPORT_PATH="$ARCHIVE_DIR/exports-adhoc"
APPSTORE_EXPORT_PATH="$ARCHIVE_DIR/exports-appstore"
PAYLOAD_DIR_NAME="$ARCHIVE_NAME-payload"
PAYLOAD_PATH="$ARCHIVE_DIR/$PAYLOAD_DIR_NAME"
DSYMS_PATH="$PAYLOAD_PATH"
UPLOAD_FILENAME="${ARCHIVE_NAME}.zip"

# Performance helpers
parallel_execute() {
  local pids=()
  for cmd in "$@"; do
    eval "$cmd" &
    pids+=($!)
  done
  
  # Wait for all background processes
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
}

# Function to check if we can skip certain build steps
should_skip_clean() {
  # Skip clean if in development mode and no significant changes detected
  if [ "$BUILD_CONTEXT" == "dev" ] && [ -d "$BUILD_PATH" ]; then
    return 0  # true - skip clean
  fi
  return 1  # false - don't skip clean
}

echo "📊 Build configuration:"
echo "  Version: $VERSION_NUM"
echo "  Build: $BUILD_NUM"
echo "  Archive: $ARCHIVE_NAME"
echo "  Target: $TARGET_NAME" 
#!/bin/bash

# SUMMARY
#   Configures common environment variables for building Palace app.
#
# USAGE
#   Source this script from other scripts (e.g. xcode-archive.sh)
#
#   in xcode-archive.sh:
#     source "path/to/xcode-settings.sh"
#     ...
#
#   invocation:
#     xcode-archive.sh
#
# ENVIRONMENT VARIABLES

#   XCODE_VERSION - Optional. The version of Xcode to use (e.g. "16.2")
#                   If not set, uses the system default Xcode

set -eo pipefail

# --- Safe DEVELOPER_DIR defaults for CI & local runs -----------------------
# If CI sets MD_APPLE_SDK_ROOT (e.g., /Applications/Xcode_16.2.app), prefer it
# and map to the 'Contents/Developer' path. Otherwise, fall back to xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -n "${MD_APPLE_SDK_ROOT:-}" ]; then
    # strip any trailing slash then append /Contents/Developer
    _sdk_root="${MD_APPLE_SDK_ROOT%/}"
    export DEVELOPER_DIR="${_sdk_root}/Contents/Developer"
  else
    export DEVELOPER_DIR="$(
      /usr/bin/xcode-select -p 2>/dev/null || true
    )"
  fi
fi

fatal()
{
  echo "$0 error: $1" 1>&2
  exit 1
}

# Respect DEVELOPER_DIR if already set (e.g., by CI setup-xcode action)
if [ -n "$DEVELOPER_DIR" ] && [ -d "$DEVELOPER_DIR" ]; then
  : # keep existing DEVELOPER_DIR
else
  # Use explicit Xcode if requested
  if [ -n "$XCODE_VERSION" ]; then
    export DEVELOPER_DIR="/Applications/Xcode_${XCODE_VERSION}.app/Contents/Developer"
    if [ ! -d "$DEVELOPER_DIR" ]; then
      fatal "Xcode ${XCODE_VERSION} not found at ${DEVELOPER_DIR}"
    fi
  else
    # Prefer newer Xcode that includes Swift 6 and recent iOS SDKs; fall back if unavailable
    for XVER in 16.4 16.3 16.2; do
      CANDIDATE="/Applications/Xcode_${XVER}.app/Contents/Developer"
      if [ -d "$CANDIDATE" ]; then
        export DEVELOPER_DIR="$CANDIDATE"
        break
      fi
    done
    # If none found, rely on system default Xcode
    if [ -z "$DEVELOPER_DIR" ] || [ ! -d "$DEVELOPER_DIR" ]; then
      echo "Info: No preferred Xcode (16.4/16.3/16.2) found, using system default Xcode"
      unset DEVELOPER_DIR
    fi
  fi
fi

# Inject C++ compatibility shim for vendored code without editing vendor files
# Use -include via build settings flags (no -Xcc for xcodebuild)
export EXTRA_COMPILER_FLAGS="-include \\\$(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp"

# determine which app we're going to work on
TARGET_NAME=Palace
SCHEME=Palace

# app-agnostic settings
APP_NAME="Palace"
PROV_PROFILES_DIR_PATH="$HOME/Library/MobileDevice/Provisioning Profiles"
PROJECT_NAME=Palace.xcodeproj
BUILD_PATH="./Build"
BUILD_SETTINGS="`xcodebuild -project $PROJECT_NAME -showBuildSettings -target \"$TARGET_NAME\"`"
VERSION_NUM=`echo "$BUILD_SETTINGS" | grep "MARKETING_VERSION" | sed 's/[ ]*MARKETING_VERSION = //'`
BUILD_NUM=`echo "$BUILD_SETTINGS" | grep "CURRENT_PROJECT_VERSION" | sed 's/[ ]*CURRENT_PROJECT_VERSION = //'`
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

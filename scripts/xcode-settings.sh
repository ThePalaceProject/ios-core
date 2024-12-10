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

set -eo pipefail

fatal()
{
  echo "$0 error: $1" 1>&2
  exit 1
}

# Set Xcode to version 15 explicitly
export DEVELOPER_DIR="/Applications/Xcode_15.4.app/Contents/Developer"

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

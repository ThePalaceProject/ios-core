#!/bin/bash

# SUMMARY
#   Exports an archive for The Palace Project generating the related ipa.
#
# SYNOPSIS
#   xcode-export-adhoc.sh
#
# PARAMETERS
#   See xcode-settings.sh for possible parameters.
#
# USAGE
#   Run this script from the root of `ios-core` repo, e.g.:
#
#     ./scripts/xcode-export-adhoc.sh
#
# RESULTS
#   The generated .ipa is placed in its own directory inside
#   `./Build/Palace-<version>` folder.

source "$(dirname $0)/xcode-settings.sh"

echo "Exporting $ARCHIVE_NAME for Ad-Hoc distribution..."

# Ensure required iOS SDK is present to avoid CI image platform issues
if ! xcodebuild -showsdks | grep -q "iphoneos"; then
  echo "error: iPhoneOS SDK not found in selected Xcode at ${DEVELOPER_DIR:-$(xcode-select -p)}" 1>&2
  xcodebuild -showsdks | cat
  exit 70
fi

# Force iPhoneOS SDK usage to avoid generic destination resolution problems
FASTLANE_XCARGS="-sdk iphoneos"

fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR xcargs:"$FASTLANE_XCARGS"

echo "Uploading archive:"

./scripts/ios-binaries-upload.sh
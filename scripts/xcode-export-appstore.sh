#!/bin/bash

# SUMMARY
#   Exports The Palace Projects archive for App Store distribution
#   generating the related ipa.
#
# SYNOPSIS
#   xcode-export-appstore.sh
#
# USAGE
#   Run this script from the root of `ios-core` repo, e.g.:
#
#     ./scripts/xcode-export-appstore.sh
#
# RESULTS
#   The generated .ipa is uploaded to TestFlight.

# Make Xcode/tooling selection consistent with adhoc
source "$(dirname $0)/xcode-settings.sh"

# Ensure required iOS SDK is present
if ! xcodebuild -showsdks | grep -q "iphoneos"; then
  echo "error: iPhoneOS SDK not found in selected Xcode at ${DEVELOPER_DIR:-$(xcode-select -p)}" 1>&2
  xcodebuild -showsdks | cat
  exit 70
fi

# Force iPhoneOS SDK usage and inject compatibility shim
FASTLANE_XCARGS="-sdk iphoneos OTHER_CFLAGS=\"$EXTRA_COMPILER_FLAGS\" OTHER_CPLUSPLUSFLAGS=\"$EXTRA_COMPILER_FLAGS\""

CHANGELOG=$(<"$CHANGELOG_PATH")
fastlane ios appstore changelog:"$CHANGELOG" xcargs:"$FASTLANE_XCARGS"

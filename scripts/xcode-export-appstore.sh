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

# Prepare an xcconfig to inject compatibility shim via build settings
mkdir -p "$BUILD_PATH"
XC_CFG_PATH="$BUILD_PATH/ci-compat.xcconfig"
cat > "$XC_CFG_PATH" <<'EOF'
OTHER_CFLAGS = $(inherited) -include $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
OTHER_CPLUSPLUSFLAGS = $(inherited) -include $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
OTHER_SWIFT_FLAGS = $(inherited) -Xcc -include -Xcc $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
EOF

# Force iPhoneOS SDK usage and pass xcconfig
FASTLANE_XCARGS="-sdk iphoneos -xcconfig $XC_CFG_PATH"

CHANGELOG=$(<"$CHANGELOG_PATH")
fastlane ios appstore changelog:"$CHANGELOG" xcargs:"$FASTLANE_XCARGS"

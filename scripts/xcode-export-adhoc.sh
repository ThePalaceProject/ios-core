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

# Prepare an xcconfig to inject compatibility shim via build settings
mkdir -p "$BUILD_PATH"
XC_CFG_PATH="$BUILD_PATH/ci-compat.xcconfig"
cat > "$XC_CFG_PATH" <<'EOF'
OTHER_CFLAGS = $(inherited) -include $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
OTHER_CPLUSPLUSFLAGS = $(inherited) -include $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
OTHER_SWIFT_FLAGS = $(inherited) -Xcc -include -Xcc $(SRCROOT)/Palace/BuildSupport/cpp_compat.hpp
EOF

# Force iPhoneOS SDK usage and pass xcconfig (avoid complex quoting in xcargs)
FASTLANE_XCARGS="-sdk iphoneos -xcconfig $XC_CFG_PATH"

fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR xcargs:"$FASTLANE_XCARGS"

echo "Uploading archive:"

./scripts/ios-binaries-upload.sh

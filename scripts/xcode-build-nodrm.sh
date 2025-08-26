#!/bin/bash

# SUMMARY
#   Builds Palace without DRM support.
#
# SYNOPSIS
#   xcode-build-nodrm.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-build-nodrm.sh


echo "Building Palace without DRM support..."

set -euo pipefail

# Build for iOS Simulator SDK without selecting a specific destination
# This avoids requiring any installed simulator runtime
BUILD_CMD=(
  xcodebuild
  -project Palace.xcodeproj
  -scheme Palace-noDRM
  -configuration Debug
  -sdk iphonesimulator
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ONLY_ACTIVE_ARCH=YES
)

# Use xcbeautify if available for nicer logs
if command -v xcbeautify >/dev/null 2>&1; then
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

echo "✅ no-DRM build completed (iphonesimulator)."

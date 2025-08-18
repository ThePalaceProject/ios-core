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

xcodebuild \
  -project Palace.xcodeproj \
  -scheme Palace-noDRM \
  -destination 'platform=iOS Simulator,name=iPhone 13,OS=16.1' \
  -configuration Debug \
  build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

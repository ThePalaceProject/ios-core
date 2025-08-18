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
  -destination 'platform=iOS Simulator,id=00E82424-9E89-403B-B393-ACF5F521158A' \
  -configuration Debug \
  build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

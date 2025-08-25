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

# Ensure Fastlane/xcodebuild use a consistent Xcode that has simulator runtimes in CI
if [ "${BUILD_CONTEXT:-}" = "ci" ] && [ -d "/Applications/Xcode_16.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode_16.app/Contents/Developer"
  echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"
fi

fastlane ios nodrm

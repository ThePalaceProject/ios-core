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

# Ensure Fastlane/xcodebuild use an Xcode with simulator runtimes in CI
if [ "${BUILD_CONTEXT:-}" = "ci" ]; then
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
      export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
      echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"
    elif [ -d "/Applications/Xcode_16.app/Contents/Developer" ]; then
      export DEVELOPER_DIR="/Applications/Xcode_16.app/Contents/Developer"
      echo "Using fallback DEVELOPER_DIR=$DEVELOPER_DIR"
    fi
  else
    echo "DEVELOPER_DIR preset to $DEVELOPER_DIR"
  fi
fi

# Prefer running via Bundler if Gemfile is present
if [ -f "Gemfile" ]; then
  echo "Invoking via bundle exec fastlane"
  bundle exec fastlane ios nodrm
else
  fastlane ios nodrm
fi

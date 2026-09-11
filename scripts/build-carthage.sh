#!/bin/bash

# SUMMARY
#   Sets up and build dependencies for the Palace and Palace-noDRM targets
#
# SYNOPSIS
#     ./scripts/build-carthage.sh [--no-private ]
#
# PARAMETERS
#     --no-private: skips building private repos.
#
# USAGE
#   Make sure to run this script from a clean checkout and from the root
#   of ios-core, e.g.:
#
#     git checkout Cartfile
#     git checkout Cartfile.resolved
#     ./scripts/build-carthage.sh
#
set -eo pipefail

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Building Carthage..."
else
  echo "Building Carthage for [$BUILD_CONTEXT]..."
fi

# deep clean to avoid any caching issues
rm -rf ~/Library/Caches/org.carthage.CarthageKit
rm -rf Carthage

# for DRM-enabled build only: AddLCP.swift lives in the private
# mobile-certificates repo, which a --no-private checkout does not have.
if [ "$1" != "--no-private" ]; then
  if [ "$BUILD_CONTEXT" == "ci" ]; then
    CERTIFICATES_PATH_PREFIX="."
  else
    CERTIFICATES_PATH_PREFIX=".."
  fi

  swift $CERTIFICATES_PATH_PREFIX/mobile-certificates/Certificates/Palace/iOS/AddLCP.swift
fi

# For BOTH builds. Findaway's AudioEngine SDK is a public, unauthenticated
# download (cdn.audioengine.io), so --no-private does not exclude it.
# PalaceAudiobookToolkit weak-links AudioEngine.xcframework, and a weak link
# still needs the framework present at link time — without it the noDRM build
# stops at `There is no XCFramework found at 'Carthage/Build/AudioEngine.xcframework'`.
# The Palace-noDRM target does not EMBED the framework (only the Palace target
# does), so the noDRM product ships without Findaway's SDK and
# `FindawaySupport.isAvailable` turns Findaway off at runtime;
# scripts/check-nodrm-app-excludes-audioengine.sh asserts both after the build.
./scripts/fetch-audioengine.sh

echo "Carthage build..."
carthage bootstrap --use-xcframeworks --platform ios


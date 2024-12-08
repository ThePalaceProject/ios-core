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
# NOTES
#   If working on R2 integration, use the `build-carthage-R2-integration.sh`
#   script instead.

set -eo pipefail

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Building Carthage..."
else
  echo "Building Carthage for [$BUILD_CONTEXT]..."
fi

# deep clean to avoid any caching issues
rm -rf ~/Library/Caches/org.carthage.CarthageKit
rm -rf Carthage

# for DRM-enabled build only
if [ "$1" != "--no-private" ]; then
  if [ "$BUILD_CONTEXT" == "ci" ]; then
    CERTIFICATES_PATH_PREFIX="."
  else
    CERTIFICATES_PATH_PREFIX=".."
  fi

  swift $CERTIFICATES_PATH_PREFIX/mobile-certificates/Certificates/Palace/iOS/AddLCP.swift
fi

./scripts/fetch-audioengine.sh

echo "Carthage build..."
carthage bootstrap --use-xcframeworks --platform ios


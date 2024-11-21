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

echo "Clearing Derived Data..."
rm -rf ~/Library/Developer/Xcode/DerivedData/*

echo "Building Palace without DRM support..."

fastlane ios nodrm

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

set -eo pipefail

echo "Building Palace without DRM support..."

xcodebuild -project Palace.xcodeproj \
           -scheme Palace-noDRM \
           -destination platform=iOS\ Simulator,OS=14.4,name=iPhone\ 12\ Pro\
           clean build | \
           if command -v xcpretty &> /dev/null; then xcpretty; else cat; fi

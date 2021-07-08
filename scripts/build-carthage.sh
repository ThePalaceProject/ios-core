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

./ios-drm-audioengine/scripts/fetch-audioengine.sh

# make NYPLAEToolkit use the same carthage folder as SimplyE by adding a
# symlink if that's missing
cd ios-drm-audioengine
if [[ ! -L ./Carthage ]]; then
  ln -s ../Carthage ./Carthage
fi
echo "ios-drm-audioengine contents:"
ls -l . Carthage/
cd ..

echo "Carthage build..."
carthage bootstrap --use-xcframeworks --platform ios


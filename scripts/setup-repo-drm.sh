#!/bin/bash

# SUMMARY
#   Sets up the Simplified-iOS repo for running SimplyE and Open eBooks
#   with DRM support.
#
# USAGE
#   You only have to run this script once after checking out the related repos.
#   Run it from the root of Simplified-iOS, e.g.:
#
#     ./scripts/setup-repo-drm.sh
#

set -xeo pipefail

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Setting up repo for building with DRM support..."
else
  echo "Setting up repo for building with DRM support for [$BUILD_CONTEXT]..."
fi

if [ "$BUILD_CONTEXT" != "ci" ]; then
  git submodule update --init --recursive
fi

if [ "$BUILD_CONTEXT" == "ci" ]; then
  ADOBE_SDK_PATH=./mobile-drm-adeptconnector
else
  ADOBE_SDK_PATH=../mobile-drm-adeptconnector
fi

if [ ! -d "$ADOBE_SDK_PATH" ]; then
  echo "Error: Adobe SDK path $ADOBE_SDK_PATH does not exist."
  exit 1
fi

ln -sf $ADOBE_SDK_PATH/uncompressed adobe-rmsdk

cd $ADOBE_SDK_PATH
if [ -f "./uncompress.sh" ]; then
  ./uncompress.sh
else
  echo "Error: uncompress.sh not found in $ADOBE_SDK_PATH"
  exit 1
fi

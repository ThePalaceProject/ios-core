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

set -eo pipefail

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Setting up repo for building with DRM support..."
else
  echo "Setting up repo for building with DRM support for [$BUILD_CONTEXT]..."
fi

if [ "$BUILD_CONTEXT" != "ci" ]; then
  git submodule update --init --recursive
fi

if [ "$BUILD_CONTEXT" == "ci" ]; then
  ADOBE_SDK_PATH=./ios-drm-adeptconnector
else
  ADOBE_SDK_PATH=../ios-drm-adeptconnector
fi

# -n replaces an existing adobe-rmsdk link instead of following it and
# creating a second link inside the connector checkout.
ln -sfn $ADOBE_SDK_PATH/connector adobe-rmsdk

# Stop if the linked connector is not the commit CI builds.
python3 scripts/drm_connector.py check

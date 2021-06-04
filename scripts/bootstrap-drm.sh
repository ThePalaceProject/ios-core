#!/bin/bash

# SUMMARY
#   Checks out all dependent repos and sets them up for developing
#   SimplyE or Open eBooks with DRM support.
#
# USAGE
#   You only have to run this script once.
#   Run it from the root of Simplified-iOS, e.g.:
#
#     ./scripts/bootstrap-drm.sh
#

cd ..
git clone git@github.com:ThePalaceProject/mobile-certificates.git
git clone git@github.com:ThePalaceProject/android-drm-adeptconnector.git

cd ios-core
git checkout develop

./scripts/setup-repo-drm.sh

./scripts/build-3rd-party-dependencies.sh

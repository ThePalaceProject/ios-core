#!/bin/bash

# SUMMARY
#   Checks out all dependent repos and sets them up for developing
#   Palace with DRM support.
#
# USAGE
#   You only have to run this script once.
#   Run it from the root of ios-core, e.g.:
#
#     ./scripts/bootstrap-drm.sh
#

set -eo pipefail

cd ..
git clone git@github.com:ThePalaceProject/mobile-certificates.git
git clone git@github.com:ThePalaceProject/ios-drm-adeptconnector.git
git clone git@github.com:ThePalaceProject/ios-audiobook-overdrive.git

cd ios-drm-adeptconnector
git lfs pull

cd ../ios-core

./scripts/setup-repo-drm.sh
./scripts/build-3rd-party-dependencies.sh

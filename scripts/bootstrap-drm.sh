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

ROOT="$(pwd)"
# Read the connector record (.github/actions/checkout-adobe/action.yml) before
# cloning anything, so a bad record stops here rather than mid-setup.
python3 "$ROOT/scripts/drm_connector.py" --repo-root "$ROOT" get sha >/dev/null

cd ..
git clone git@github.com:ThePalaceProject/mobile-certificates.git
# Clones the connector and checks out the recorded commit, then pulls its LFS
# objects. CI builds the same commit.
python3 "$ROOT/scripts/drm_connector.py" --repo-root "$ROOT" clone ios-drm-adeptconnector
git clone git@github.com:ThePalaceProject/ios-audiobook-overdrive.git

cd "$ROOT"

./scripts/setup-repo-drm.sh
./scripts/build-3rd-party-dependencies.sh

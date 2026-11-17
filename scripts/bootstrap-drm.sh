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

# Use the same connector branch CI builds with, so the linked connector matches
# AdobeConnectorGeneration.current.
CONNECTOR_REF=$(awk '/^  ref:/{f=1} f && /^    default:/{gsub(/["[:space:]]/,"",$2); print $2; exit}' .github/actions/checkout-adobe/action.yml)
[ -n "$CONNECTOR_REF" ] || { echo "Could not read the connector ref from .github/actions/checkout-adobe/action.yml" >&2; exit 1; }

cd ..
git clone git@github.com:ThePalaceProject/mobile-certificates.git
git clone --branch "$CONNECTOR_REF" git@github.com:ThePalaceProject/ios-drm-adeptconnector.git
git clone git@github.com:ThePalaceProject/ios-audiobook-overdrive.git

cd ios-drm-adeptconnector
git lfs pull

cd ../ios-core

./scripts/setup-repo-drm.sh
./scripts/build-3rd-party-dependencies.sh

#!/bin/bash

# SUMMARY
#   Checks out all dependent repos and sets them up for developing
#   Palace with DRM support.
#
# USAGE
#   You only have to run this script once; running it again is safe. Sibling
#   checkouts that already exist are left as they are, and setup-repo-drm.sh
#   reports a connector checkout that is not at the recorded commit.
#   Run it from the root of ios-core, e.g.:
#
#     ./scripts/bootstrap-drm.sh
#

set -eo pipefail

ROOT="$(pwd)"
# Read the connector record (.github/actions/checkout-adobe/action.yml) before
# cloning anything, so a bad record stops here rather than mid-setup.
python3 "$ROOT/scripts/drm_connector.py" --repo-root "$ROOT" get sha >/dev/null

# Runs the clone command unless the directory already exists.
clone_once() {  # clone_once <dir> <command...>
  local dir="$1"
  shift
  if [ -e "$dir" ]; then
    echo "$dir already exists; leaving it as it is"
  else
    "$@"
  fi
}

cd ..
clone_once mobile-certificates git clone git@github.com:ThePalaceProject/mobile-certificates.git
# Clones the connector and checks out the recorded commit, then pulls its LFS
# objects. CI builds the same commit.
clone_once ios-drm-adeptconnector \
  python3 "$ROOT/scripts/drm_connector.py" --repo-root "$ROOT" clone ios-drm-adeptconnector
clone_once ios-audiobook-overdrive git clone git@github.com:ThePalaceProject/ios-audiobook-overdrive.git

cd "$ROOT"

./scripts/setup-repo-drm.sh
./scripts/build-3rd-party-dependencies.sh

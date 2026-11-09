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
RECORDS="$ROOT/scripts/drm_connector.py"
# Read the records (.github/actions/checkout-adobe and checkout-certificates)
# before cloning anything, so a bad record stops here rather than mid-setup.
python3 "$RECORDS" --repo-root "$ROOT" get sha >/dev/null
python3 "$RECORDS" --repo-root "$ROOT" get --input certificates sha >/dev/null
# The sibling overdrive checkout matches the commit the submodule records.
OVERDRIVE_SHA="$(git -C "$ROOT" rev-parse HEAD:ios-audiobook-overdrive)"

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

clone_overdrive() {
  git clone git@github.com:ThePalaceProject/ios-audiobook-overdrive.git ios-audiobook-overdrive
  git -C ios-audiobook-overdrive checkout --detach "$OVERDRIVE_SHA"
}

cd ..
# Each clone checks out the recorded commit (and pulls LFS objects where the
# repository has them). CI builds the same commits.
clone_once mobile-certificates \
  python3 "$RECORDS" --repo-root "$ROOT" clone --input certificates mobile-certificates
clone_once ios-drm-adeptconnector \
  python3 "$RECORDS" --repo-root "$ROOT" clone ios-drm-adeptconnector
clone_once ios-audiobook-overdrive clone_overdrive

cd "$ROOT"

./scripts/setup-repo-drm.sh
./scripts/build-3rd-party-dependencies.sh

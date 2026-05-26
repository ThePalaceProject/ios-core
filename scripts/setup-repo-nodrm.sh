#!/bin/bash

# SUMMARY
#   Sets up the ios-core repo for running Palace without DRM support.
#
# USAGE
#   You only have to run this script once after checking out the related repos.
#   Run it from the root of ios-core, e.g.:
#
#     ./scripts/setup-repo-nodrm.sh
#
# NOTES
#   1. On a fresh checkout this script will produce some errors while trying
#      to deinit the adobe repos. This is expected and does not affect the
#      build process.

set -eo pipefail

echo "Setting up repo for non-DRM build"

# Remove the private DRM submodules from the working tree. Idempotent: each
# block is guarded so a second run is silent rather than printing "did not
# match any files" errors. `git submodule deinit` returns 0 on a missing
# submodule (just prints to stderr), but `git rm -rf` returns 128 — without
# the guard the second run is noisy.
remove_drm_submodule() {
  local path="$1"
  if [ -e "$path" ] || git submodule status "$path" >/dev/null 2>&1; then
    git submodule deinit -f "$path" 2>/dev/null || true
    git rm -rf "$path" 2>/dev/null || true
  fi
}

remove_drm_submodule adept-ios
remove_drm_submodule adobe-content-filter
remove_drm_submodule ios-drm-audioengine
remove_drm_submodule ios-audiobook-overdrive

git submodule update --init --recursive

# Remove private repos from Cartfile and Cartfile.resolved.
sed -i '' "s#.*lcp.*##" Cartfile
sed -i '' "s#.*lcp.*##" Cartfile.resolved

if [ ! -f "APIKeys.swift" ]; then
  cp Palace/AppInfrastructure/APIKeys.swift.example Palace/AppInfrastructure/APIKeys.swift
fi

# These will need to be filled in with real values
if [ ! -f "PalaceConfig/GoogleService-Info.plist" ]; then
  cp PalaceConfig/GoogleService-Info.plist.example PalaceConfig/GoogleService-Info.plist
fi
if [ ! -f "PalaceConfig/ReaderClientCert.sig" ]; then
  cp PalaceConfig/ReaderClientCert.sig.example PalaceConfig/ReaderClientCert.sig
fi

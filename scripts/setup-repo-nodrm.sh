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

git submodule deinit adept-ios
git rm -rf adept-ios
git submodule deinit adobe-content-filter
git rm -rf adobe-content-filter
git submodule deinit ios-drm-audioengine
git rm -rf ios-drm-audioengine
git submodule deinit ios-audiobook-overdrive
git rm -rf ios-audiobook-overdrive
git submodule deinit ios-audiobook-toolkit
git rm -rf ios-audiobook-toolkit

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

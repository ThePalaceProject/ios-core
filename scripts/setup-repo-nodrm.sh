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
set -eo pipefail

echo "Setting up repo for non-DRM build"

# Drop the private DRM submodules and fetch the public ones without
# credentials, as a fork pull request must.
./scripts/fetch-nodrm-submodules.sh

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

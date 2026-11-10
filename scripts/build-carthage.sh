#!/bin/bash

# SUMMARY
#   Sets up and build dependencies for the Palace and Palace-noDRM targets
#
# SYNOPSIS
#     ./scripts/build-carthage.sh [--no-private ]
#
# PARAMETERS
#     --no-private: skips building private repos.
#
# USAGE
#   Make sure to run this script from a clean checkout and from the root
#   of ios-core, e.g.:
#
#     git checkout Cartfile
#     git checkout Cartfile.resolved
#     ./scripts/build-carthage.sh
#
set -eo pipefail

# The liblcp binary Carthage downloads for the DRM build (AddLCP.swift in
# mobile-certificates adds it to the Cartfile). Carthage does not verify
# binary-only frameworks, so the archive is checked here. To move to a new
# version, change both values together after checking the new archive, and
# check that a DRM build opens an LCP-protected book.
LIBLCP_VERSION="4.1.0"
LIBLCP_SHA256="e12923e47e0f7d20f4c39c3dda4004785a176cc3e81a8520a17969f147dee17a"

# Prints versions, hashes and cache paths only: the download URL is licensed.
verify_liblcp()
{
  local resolved actual archives
  resolved=$(sed -n 's/^binary ".*\/liblcp\.json" "\(.*\)"$/\1/p' Cartfile.resolved)
  if [ "$resolved" != "$LIBLCP_VERSION" ]; then
    echo "$0: Cartfile.resolved has liblcp ${resolved:-<none>}, but this script records $LIBLCP_VERSION; update LIBLCP_VERSION and LIBLCP_SHA256 together" 1>&2
    exit 1
  fi
  # The cache was emptied at the start of this script, so the only archive
  # here is the one this run downloaded.
  archives=("$HOME/Library/Caches/org.carthage.CarthageKit/binaries/liblcp/$LIBLCP_VERSION/"*.zip)
  if [ "${#archives[@]}" -ne 1 ] || [ ! -f "${archives[0]}" ]; then
    echo "$0: expected one downloaded liblcp $LIBLCP_VERSION archive in Carthage's cache" 1>&2
    exit 1
  fi
  actual=$(shasum -a 256 "${archives[0]}" | cut -d' ' -f1)
  if [ "$actual" != "$LIBLCP_SHA256" ]; then
    rm -rf Carthage/Build/R2LCPClient.xcframework
    echo "$0: liblcp $LIBLCP_VERSION archive has SHA-256 $actual, expected $LIBLCP_SHA256; removed the framework built from it" 1>&2
    exit 1
  fi
  echo "liblcp $LIBLCP_VERSION archive SHA-256 matches the record"
}

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Building Carthage..."
else
  echo "Building Carthage for [$BUILD_CONTEXT]..."
fi

# deep clean to avoid any caching issues
rm -rf ~/Library/Caches/org.carthage.CarthageKit
rm -rf Carthage

# for DRM-enabled build only: AddLCP.swift lives in the private
# mobile-certificates repo, which a --no-private checkout does not have.
if [ "$1" != "--no-private" ]; then
  if [ "$BUILD_CONTEXT" == "ci" ]; then
    CERTIFICATES_PATH_PREFIX="."
  else
    CERTIFICATES_PATH_PREFIX=".."
  fi

  swift $CERTIFICATES_PATH_PREFIX/mobile-certificates/Certificates/Palace/iOS/AddLCP.swift
fi

# For BOTH builds. Findaway's AudioEngine SDK is a public, unauthenticated
# download (cdn.audioengine.io), so --no-private does not exclude it.
# PalaceAudiobookToolkit weak-links AudioEngine.xcframework, and a weak link
# still needs the framework present at link time — without it the noDRM build
# stops at `There is no XCFramework found at 'Carthage/Build/AudioEngine.xcframework'`.
# The Palace-noDRM target does not EMBED the framework (only the Palace target
# does), so the noDRM product ships without Findaway's SDK and
# `FindawaySupport.isAvailable` turns Findaway off at runtime;
# scripts/check-nodrm-app-excludes-audioengine.sh asserts both after the build.
./scripts/fetch-audioengine.sh

echo "Carthage build..."
carthage bootstrap --use-xcframeworks --platform ios

if [ "$1" != "--no-private" ]; then
  verify_liblcp
fi


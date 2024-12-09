#!/bin/bash

# SUMMARY
#   This scripts wipes your Carthage folder, checks out and rebuilds
#   all Carthage dependencies for working on R2 integration.
#
# SYNOPSIS
#     ./scripts/build-carthage-R2-integration.sh
#
# USAGE
#   Run this script from the root of Simplified-iOS repo.
#   Use this script in conjuction with the SimplifiedR2.workspace. This
#   assumes that you have the R2 repos checked out as siblings of
#   Simplified-iOS.
#
# NOTES
#   This is meant to be used locally. It won't work in a GitHub Actions CI
#   context. For the latter, use `build-carthage.sh` instead.

echo "Building Carthages for R2 dependencies..."

# deep clean to avoid any caching issues
rm -rf ~/Library/Caches/org.carthage.CarthageKit
rm -rf Carthage

echo "Building r2-lcp-swift Carthage dependencies..."
cd ../r2-lcp-swift
git checkout 2.0.0-beta.1
rm -rf Carthage
swift ../Certificates/SimplyE/iOS/LCPLib.swift
carthage checkout
carthage build --platform iOS

carthage checkout
./scripts/fetch-audioengine.sh

# also update SimplyE's dependencies so the framework versions all match
carthage build --platform ios

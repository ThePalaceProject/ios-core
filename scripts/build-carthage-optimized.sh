#!/bin/bash

# SUMMARY
#   Optimized Carthage build script that uses intelligent caching
#   to avoid unnecessary rebuilds and significantly reduce build times.
#
# SYNOPSIS
#     ./scripts/build-carthage-optimized.sh [--no-private] [--force-clean]
#
# PARAMETERS
#     --no-private: skips building private repos.
#     --force-clean: forces a complete clean rebuild (use sparingly)
#
# PERFORMANCE IMPROVEMENTS
#   - Uses Cartfile.resolved hash to detect when dependencies changed
#   - Only cleans when dependencies actually change
#   - Leverages carthage's built-in caching mechanisms
#   - Avoids clearing system-wide Carthage cache unless necessary

set -eo pipefail

FORCE_CLEAN=false
NO_PRIVATE=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --force-clean)
      FORCE_CLEAN=true
      shift
      ;;
    --no-private)
      NO_PRIVATE=true
      shift
      ;;
  esac
done

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Building Carthage (optimized)..."
else
  echo "Building Carthage (optimized) for [$BUILD_CONTEXT]..."
fi

# Create cache directory and hash file
CACHE_DIR=".carthage-cache"
mkdir -p "$CACHE_DIR"
CARTFILE_HASH_FILE="$CACHE_DIR/cartfile.hash"
CURRENT_HASH=""

# Calculate current Cartfile hash
if [ -f "Cartfile.resolved" ]; then
  CURRENT_HASH=$(shasum -a 256 Cartfile.resolved Cartfile 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
fi

# Check if dependencies changed
DEPENDENCIES_CHANGED=true
if [ -f "$CARTFILE_HASH_FILE" ] && [ "$FORCE_CLEAN" != "true" ]; then
  CACHED_HASH=$(cat "$CARTFILE_HASH_FILE" 2>/dev/null || echo "")
  if [ "$CURRENT_HASH" == "$CACHED_HASH" ] && [ -d "Carthage" ]; then
    echo "✅ Dependencies unchanged, using cached build"
    DEPENDENCIES_CHANGED=false
  fi
fi

# Only clean if dependencies changed or forced
if [ "$DEPENDENCIES_CHANGED" == "true" ] || [ "$FORCE_CLEAN" == "true" ]; then
  echo "🧹 Dependencies changed or clean forced, rebuilding..."
  
  # Only remove local Carthage, preserve system cache unless forced
  rm -rf Carthage
  
  if [ "$FORCE_CLEAN" == "true" ]; then
    echo "🗑️  Force clean: removing system Carthage cache"
    rm -rf ~/Library/Caches/org.carthage.CarthageKit
  fi
else
  echo "⚡ Using existing Carthage build"
  exit 0
fi

# DRM-enabled build dependencies
if [ "$NO_PRIVATE" != "true" ]; then
  if [ "$BUILD_CONTEXT" == "ci" ]; then
    CERTIFICATES_PATH_PREFIX="."
  else
    CERTIFICATES_PATH_PREFIX=".."
  fi

  swift $CERTIFICATES_PATH_PREFIX/mobile-certificates/Certificates/Palace/iOS/AddLCP.swift
  ./scripts/fetch-audioengine.sh
fi

echo "🏗️  Building Carthage dependencies..."
# Use update instead of bootstrap for better incremental builds
if [ -f "Cartfile.resolved" ]; then
  carthage update --use-xcframeworks --platform ios --cache-builds
else
  carthage bootstrap --use-xcframeworks --platform ios --cache-builds
fi

# Cache the hash for next run
echo "$CURRENT_HASH" > "$CARTFILE_HASH_FILE"
echo "✅ Carthage build complete and cached" 
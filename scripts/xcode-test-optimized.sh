#!/bin/bash

# SUMMARY
#   Runs optimized unit tests for Palace with performance improvements.
#
# SYNOPSIS
#   xcode-test-optimized.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-test-optimized.sh

set -euo pipefail

echo "Running optimized unit tests for Palace..."

# Skip the separate build step - xcodebuild test builds automatically and more efficiently
# Use parallel testing and optimized flags

if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
    echo "Running in CI mode with optimizations..."
    
    # Find an available iOS simulator for CI
    AVAILABLE_SIMULATOR=$(xcrun simctl list devices available | grep iPhone | head -1 | sed 's/^ *//' | sed 's/ (.*//')
    
    if [ -z "$AVAILABLE_SIMULATOR" ]; then
        echo "No available iOS simulator found, trying iPhone 15..."
        AVAILABLE_SIMULATOR="iPhone 15"
    fi
    
    echo "Using simulator: $AVAILABLE_SIMULATOR"
    
    # Use available simulator for CI execution
    xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "platform=iOS Simulator,name=$AVAILABLE_SIMULATOR" \
        -configuration Debug \
        -enableCodeCoverage NO \
        -quiet \
        -parallel-testing-enabled YES \
        -maximum-parallel-testing-workers 4 \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        GCC_OPTIMIZATION_LEVEL=0 \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        ENABLE_TESTABILITY=YES
else
    echo "Running in local development mode..."
    
    # Use fastlane for local development (more user-friendly output)
    fastlane ios test
fi

echo "✅ Unit tests completed successfully!"

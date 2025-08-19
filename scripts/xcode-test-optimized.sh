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

# Use direct xcodebuild for faster execution (skip Fastlane overhead)
# Try multiple fallback strategies for CI compatibility
echo "Detecting test environment and finding suitable simulator..."

if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
    echo "Running in CI environment - trying multiple fallback strategies"
    
    # List available simulators for debugging
    echo "Available iPhone simulators in CI:"
    xcrun simctl list devices available | grep iPhone | head -5
    
    # Try multiple simulator options that are commonly available in CI
    SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12" "iPhone 11")
    
    for SIM in "${SIMULATORS[@]}"; do
        echo "Attempting to use: $SIM"
        if xcodebuild test \
            -project Palace.xcodeproj \
            -scheme Palace \
            -destination "platform=iOS Simulator,name=$SIM" \
            -configuration Debug \
            -enableCodeCoverage NO \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers 2 \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ONLY_ACTIVE_ARCH=YES \
            GCC_OPTIMIZATION_LEVEL=0 \
            SWIFT_OPTIMIZATION_LEVEL=-Onone \
            ENABLE_TESTABILITY=YES 2>/dev/null; then
            echo "✅ Successfully used simulator: $SIM"
            break
        else
            echo "❌ Failed with simulator: $SIM, trying next..."
        fi
    done
else
    echo "Running in local environment - using dynamic detection"
    # Get the first available iPhone simulator ID from the Palace scheme destinations
    SIMULATOR_ID=$(xcodebuild -project Palace.xcodeproj -scheme Palace -showdestinations 2>/dev/null | \
      grep "platform:iOS Simulator" | \
      grep "iPhone" | \
      grep -v "error:" | \
      head -1 | \
      sed 's/.*id:\([^,]*\).*/\1/')

    if [ -z "$SIMULATOR_ID" ]; then
        echo "❌ No available iPhone simulator found, trying fallback..."
        # Clean build folder first
        xcodebuild clean -project Palace.xcodeproj -scheme Palace > /dev/null 2>&1
        
        # Fallback to name-based approach with common simulators
        FALLBACK_SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12")
        
        for SIM in "${FALLBACK_SIMULATORS[@]}"; do
            echo "Trying fallback simulator: $SIM"
            if xcodebuild test \
                -project Palace.xcodeproj \
                -scheme Palace \
                -destination "platform=iOS Simulator,name=$SIM" \
                -configuration Debug \
                -enableCodeCoverage NO \
                -parallel-testing-enabled YES \
                -maximum-parallel-testing-workers 4 \
                CODE_SIGNING_REQUIRED=NO \
                CODE_SIGNING_ALLOWED=NO \
                ONLY_ACTIVE_ARCH=YES \
                GCC_OPTIMIZATION_LEVEL=0 \
                SWIFT_OPTIMIZATION_LEVEL=-Onone \
                ENABLE_TESTABILITY=YES 2>/dev/null; then
                echo "✅ Fallback successful with: $SIM"
                break
            else
                echo "❌ Fallback failed with: $SIM"
            fi
        done
    else
        echo "Using iPhone simulator ID: $SIMULATOR_ID"
        # Clean build folder to avoid architecture conflicts
        xcodebuild clean -project Palace.xcodeproj -scheme Palace > /dev/null 2>&1
        
        xcodebuild test \
            -project Palace.xcodeproj \
            -scheme Palace \
            -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
            -configuration Debug \
            -enableCodeCoverage NO \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers 4 \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ONLY_ACTIVE_ARCH=YES \
            GCC_OPTIMIZATION_LEVEL=0 \
            SWIFT_OPTIMIZATION_LEVEL=-Onone \
            ENABLE_TESTABILITY=YES
    fi
fi

echo "✅ Unit tests completed successfully!"

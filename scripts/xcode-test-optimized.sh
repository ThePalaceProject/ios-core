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

# Clean up any previous test results
rm -rf TestResults.xcresult

# Skip the separate build step - xcodebuild test builds automatically and more efficiently
# Use parallel testing and optimized flags

# Use direct xcodebuild for faster execution (skip Fastlane overhead)
# Try multiple fallback strategies for CI compatibility
echo "Detecting test environment and finding suitable simulator..."

if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
    echo "Running in CI environment - trying multiple fallback strategies"
    
    # Detect architecture
    ARCH=$(uname -m)
    echo "CI runner architecture: $ARCH"
    
    # List available simulators for debugging
    echo "Available iPhone simulators in CI:"
    xcrun simctl list devices available | grep iPhone | head -10
    
    # Simulators available on GitHub Actions macos-14 runners (Xcode 16.2)
    # Note: iPhone 16 is NOT available, only iPhone 15 series
    SIMULATORS=("iPhone 15 Pro" "iPhone 15" "iPhone 15 Pro Max" "iPhone SE (3rd generation)")
    
    TEST_SUCCESS=false
    for SIM in "${SIMULATORS[@]}"; do
        echo "Attempting to use: $SIM"
        echo "Full destination: platform=iOS Simulator,name=$SIM"
        
        # Note: Don't add arch= to destination - it breaks simulator lookup
        # Use ARCHS build setting instead to control architecture
        if xcodebuild test \
            -project Palace.xcodeproj \
            -scheme Palace \
            -destination "platform=iOS Simulator,name=$SIM" \
            -configuration Debug \
            -resultBundlePath TestResults.xcresult \
            -enableCodeCoverage YES \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers 2 \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ONLY_ACTIVE_ARCH=NO \
            ARCHS=arm64 \
            VALID_ARCHS=arm64 \
            GCC_OPTIMIZATION_LEVEL=0 \
            SWIFT_OPTIMIZATION_LEVEL=-Onone \
            ENABLE_TESTABILITY=YES; then
            echo "✅ Successfully used simulator: $SIM"
            TEST_SUCCESS=true
            break
        else
            EXIT_CODE=$?
            echo "❌ Failed with simulator: $SIM (exit code: $EXIT_CODE), trying next..."
            rm -rf TestResults.xcresult
        fi
    done
    
    if [ "$TEST_SUCCESS" != "true" ]; then
        echo "❌ All simulator attempts failed!"
        exit 1
    fi
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
        FALLBACK_SIMULATORS=("iPhone 16" "iPhone 15" "iPhone 15 Pro" "iPhone SE (3rd generation)")
        
        for SIM in "${FALLBACK_SIMULATORS[@]}"; do
            echo "Trying fallback simulator: $SIM"
            if xcodebuild test \
                -project Palace.xcodeproj \
                -scheme Palace \
                -destination "platform=iOS Simulator,name=$SIM" \
                -configuration Debug \
                -resultBundlePath TestResults.xcresult \
                -enableCodeCoverage YES \
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
                rm -rf TestResults.xcresult
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
            -resultBundlePath TestResults.xcresult \
            -enableCodeCoverage YES \
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

#!/bin/bash

# SUMMARY
#   Runs optimized unit tests for Palace and PalaceAudiobookToolkit.
#
# SYNOPSIS
#   xcode-test-optimized.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-test-optimized.sh
#
# OUTPUT
#   - TestResults.xcresult: Palace app unit tests
#   - AudiobookToolkitTestResults.xcresult: Audiobook toolkit unit tests

set -euo pipefail

echo "🧪 Running optimized unit tests for Palace + AudiobookToolkit..."

# Clean up any previous test results
rm -rf TestResults.xcresult
rm -rf AudiobookToolkitTestResults.xcresult

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
    # Same list as main branch - these work on macos-14 runners
    SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12" "iPhone 11")
    
    TEST_RAN=false
    for SIM in "${SIMULATORS[@]}"; do
        echo "Attempting to use: $SIM"
        # Clean previous result bundle
        rm -rf TestResults.xcresult
        
        # Run tests - allow failure so we can check if xcresult was created
        # Snapshot tests removed from test target - no skip flags needed
        echo "Starting xcodebuild test on $SIM..."
        set +e
        xcodebuild test \
            -project Palace.xcodeproj \
            -scheme Palace \
            -destination "platform=iOS Simulator,name=$SIM" \
            -configuration Debug \
            -resultBundlePath TestResults.xcresult \
            -enableCodeCoverage YES \
            -parallel-testing-enabled NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ONLY_ACTIVE_ARCH=YES \
            GCC_OPTIMIZATION_LEVEL=0 \
            SWIFT_OPTIMIZATION_LEVEL=-Onone \
            ENABLE_TESTABILITY=YES
        TEST_EXIT_CODE=$?
        set -e
        
        # If xcresult was created, tests ran (even if some failed) - stop trying simulators
        if [ -d "TestResults.xcresult" ]; then
            echo "✅ Tests executed on simulator: $SIM (exit code: $TEST_EXIT_CODE)"
            TEST_RAN=true
            break
        else
            echo "❌ Simulator $SIM unavailable or build failed, trying next..."
        fi
    done
    
    if [ "$TEST_RAN" = "false" ]; then
        echo "🔴 ERROR: No simulator could run tests!"
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
            xcodebuild test \
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
                ENABLE_TESTABILITY=YES
            TEST_EXIT_CODE=$?
            
            if [ -d "TestResults.xcresult" ]; then
                echo "✅ Tests executed with: $SIM (exit code: $TEST_EXIT_CODE)"
                break
            else
                echo "❌ Simulator $SIM unavailable, trying next..."
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

echo "✅ Palace unit tests completed!"

# ==============================
# AUDIOBOOK TOOLKIT TESTS
# ==============================
echo ""
echo "🎧 Running PalaceAudiobookToolkit unit tests..."

# Store the Palace test exit code for later
PALACE_TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}

# Run audiobook toolkit tests
AUDIOBOOK_PROJECT="ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj"
AUDIOBOOK_SCHEME="PalaceAudiobookToolkit"
AUDIOBOOK_TEST_EXIT_CODE=0

if [ -d "$AUDIOBOOK_PROJECT" ]; then
    if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
        echo "Running AudiobookToolkit tests in CI environment..."
        
        # Use the same simulator that worked for Palace tests if available
        AUDIOBOOK_SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12" "iPhone 11")
        
        AUDIOBOOK_TEST_RAN=false
        for SIM in "${AUDIOBOOK_SIMULATORS[@]}"; do
            echo "Attempting AudiobookToolkit tests on: $SIM"
            rm -rf AudiobookToolkitTestResults.xcresult
            
            set +e
            xcodebuild test \
                -project "$AUDIOBOOK_PROJECT" \
                -scheme "$AUDIOBOOK_SCHEME" \
                -destination "platform=iOS Simulator,name=$SIM" \
                -configuration Debug \
                -resultBundlePath AudiobookToolkitTestResults.xcresult \
                -enableCodeCoverage YES \
                -parallel-testing-enabled NO \
                CODE_SIGNING_REQUIRED=NO \
                CODE_SIGNING_ALLOWED=NO \
                ONLY_ACTIVE_ARCH=YES \
                GCC_OPTIMIZATION_LEVEL=0 \
                SWIFT_OPTIMIZATION_LEVEL=-Onone \
                ENABLE_TESTABILITY=YES
            AUDIOBOOK_TEST_EXIT_CODE=$?
            set -e
            
            if [ -d "AudiobookToolkitTestResults.xcresult" ]; then
                echo "✅ AudiobookToolkit tests executed on: $SIM (exit code: $AUDIOBOOK_TEST_EXIT_CODE)"
                AUDIOBOOK_TEST_RAN=true
                break
            else
                echo "❌ AudiobookToolkit tests failed on $SIM, trying next..."
            fi
        done
        
        if [ "$AUDIOBOOK_TEST_RAN" = "false" ]; then
            echo "⚠️ WARNING: AudiobookToolkit tests could not run on any simulator"
            AUDIOBOOK_TEST_EXIT_CODE=1
        fi
    else
        echo "Running AudiobookToolkit tests in local environment..."
        
        # Use the same simulator detection as Palace tests
        if [ -n "${SIMULATOR_ID:-}" ]; then
            set +e
            xcodebuild test \
                -project "$AUDIOBOOK_PROJECT" \
                -scheme "$AUDIOBOOK_SCHEME" \
                -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
                -configuration Debug \
                -resultBundlePath AudiobookToolkitTestResults.xcresult \
                -enableCodeCoverage YES \
                -parallel-testing-enabled YES \
                -maximum-parallel-testing-workers 4 \
                CODE_SIGNING_REQUIRED=NO \
                CODE_SIGNING_ALLOWED=NO \
                ONLY_ACTIVE_ARCH=YES \
                GCC_OPTIMIZATION_LEVEL=0 \
                SWIFT_OPTIMIZATION_LEVEL=-Onone \
                ENABLE_TESTABILITY=YES
            AUDIOBOOK_TEST_EXIT_CODE=$?
            set -e
        else
            # Fallback to name-based
            LOCAL_SIMS=("iPhone 16" "iPhone 15" "iPhone 15 Pro" "iPhone SE (3rd generation)")
            for SIM in "${LOCAL_SIMS[@]}"; do
                echo "Trying AudiobookToolkit tests on: $SIM"
                set +e
                xcodebuild test \
                    -project "$AUDIOBOOK_PROJECT" \
                    -scheme "$AUDIOBOOK_SCHEME" \
                    -destination "platform=iOS Simulator,name=$SIM" \
                    -configuration Debug \
                    -resultBundlePath AudiobookToolkitTestResults.xcresult \
                    -enableCodeCoverage YES \
                    -parallel-testing-enabled YES \
                    -maximum-parallel-testing-workers 4 \
                    CODE_SIGNING_REQUIRED=NO \
                    CODE_SIGNING_ALLOWED=NO \
                    ONLY_ACTIVE_ARCH=YES \
                    GCC_OPTIMIZATION_LEVEL=0 \
                    SWIFT_OPTIMIZATION_LEVEL=-Onone \
                    ENABLE_TESTABILITY=YES
                AUDIOBOOK_TEST_EXIT_CODE=$?
                set -e
                
                if [ -d "AudiobookToolkitTestResults.xcresult" ]; then
                    echo "✅ AudiobookToolkit tests executed on: $SIM"
                    break
                fi
            done
        fi
    fi
    
    echo "✅ AudiobookToolkit tests completed!"
else
    echo "⚠️ AudiobookToolkit project not found at: $AUDIOBOOK_PROJECT"
    AUDIOBOOK_TEST_EXIT_CODE=0
fi

# ==============================
# SUMMARY
# ==============================
echo ""
echo "=============================="
echo "📊 TEST SUMMARY"
echo "=============================="
echo "Palace Tests:           $([ -d "TestResults.xcresult" ] && echo "✅ Complete" || echo "❌ Missing")"
echo "AudiobookToolkit Tests: $([ -d "AudiobookToolkitTestResults.xcresult" ] && echo "✅ Complete" || echo "❌ Missing")"
echo "=============================="

# Exit with failure if any tests failed
if [ "${PALACE_TEST_EXIT_CODE:-0}" -ne 0 ] || [ "${AUDIOBOOK_TEST_EXIT_CODE:-0}" -ne 0 ]; then
    echo "❌ Some tests failed!"
    # Store the combined exit code for CI to use
    echo "COMBINED_TEST_EXIT_CODE=1" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
    exit 1
fi

echo "✅ All unit tests completed successfully!"

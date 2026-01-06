#!/bin/bash

# SUMMARY
#   Runs optimized unit tests for Palace with performance improvements.
#   Generates test results in xcresult format for CI reporting.
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

# Common xcodebuild flags for testing
COMMON_FLAGS=(
    -project Palace.xcodeproj
    -scheme Palace
    -configuration Debug
    -resultBundlePath TestResults.xcresult
    -enableCodeCoverage NO
    -parallel-testing-enabled YES
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
    ONLY_ACTIVE_ARCH=YES
    GCC_OPTIMIZATION_LEVEL=0
    SWIFT_OPTIMIZATION_LEVEL=-Onone
    ENABLE_TESTABILITY=YES
)

run_tests_with_simulator() {
    local simulator_name="$1"
    local max_workers="$2"
    
    echo "Attempting to run tests with: $simulator_name"
    
    xcodebuild test \
        "${COMMON_FLAGS[@]}" \
        -destination "platform=iOS Simulator,name=$simulator_name" \
        -maximum-parallel-testing-workers "$max_workers"
}

if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
    echo "Running in CI environment - trying multiple fallback strategies"
    
    # List available simulators for debugging
    echo "Available iPhone simulators in CI:"
    xcrun simctl list devices available | grep iPhone | head -5
    
    # Try multiple simulator options that are commonly available in CI
    SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12" "iPhone 11")
    
    TEST_PASSED=false
    for SIM in "${SIMULATORS[@]}"; do
        if run_tests_with_simulator "$SIM" 2; then
            echo "✅ Successfully used simulator: $SIM"
            TEST_PASSED=true
            break
        else
            echo "❌ Failed with simulator: $SIM, trying next..."
            # Remove failed result bundle to try again
            rm -rf TestResults.xcresult
        fi
    done
    
    if [ "$TEST_PASSED" = false ]; then
        echo "❌ All simulator attempts failed"
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
        
        # Fallback to name-based approach with common simulators
        FALLBACK_SIMULATORS=("iPhone SE (3rd generation)" "iPhone 14" "iPhone 13" "iPhone 12")
        
        TEST_PASSED=false
        for SIM in "${FALLBACK_SIMULATORS[@]}"; do
            echo "Trying fallback simulator: $SIM"
            if run_tests_with_simulator "$SIM" 4; then
                echo "✅ Fallback successful with: $SIM"
                TEST_PASSED=true
                break
            else
                echo "❌ Fallback failed with: $SIM"
                rm -rf TestResults.xcresult
            fi
        done
        
        if [ "$TEST_PASSED" = false ]; then
            echo "❌ All fallback attempts failed"
            exit 1
        fi
    else
        echo "Using iPhone simulator ID: $SIMULATOR_ID"
        
        xcodebuild test \
            "${COMMON_FLAGS[@]}" \
            -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
            -maximum-parallel-testing-workers 4
    fi
fi

# Print test summary
if [ -d "TestResults.xcresult" ]; then
    echo ""
    echo "📊 Test Results Summary:"
    xcrun xcresulttool get --path TestResults.xcresult --format json 2>/dev/null | \
        python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    metrics = data.get('metrics', {})
    tests = metrics.get('testsCount', {}).get('_value', 'N/A')
    failures = metrics.get('testsFailedCount', {}).get('_value', '0')
    print(f'  Total Tests: {tests}')
    print(f'  Passed: {int(tests) - int(failures) if tests != \"N/A\" else \"N/A\"}')
    print(f'  Failed: {failures}')
except Exception as e:
    print(f'  Unable to parse results: {e}')
" 2>/dev/null || echo "  Unable to parse test results"
fi

echo ""
echo "✅ Unit tests completed successfully!"

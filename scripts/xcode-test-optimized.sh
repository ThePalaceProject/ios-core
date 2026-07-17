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

# Opt-in clean. The local paths below ran `xcodebuild clean` UNCONDITIONALLY,
# discarding warm DerivedData and forcing a full cold rebuild (tens of minutes)
# on every "CI-parity" local run. Off by default — set PALACE_TEST_CLEAN=1 (or
# pass --clean) only when you actually suspect a stale-artifact / arch conflict.
CLEAN_BUILD="${PALACE_TEST_CLEAN:-0}"
for arg in "$@"; do
    [ "$arg" = "--clean" ] && CLEAN_BUILD=1
done
maybe_clean() {
    if [ "$CLEAN_BUILD" = "1" ]; then
        echo "Cleaning build folder (PALACE_TEST_CLEAN / --clean set)..."
        xcodebuild clean -project Palace.xcodeproj -scheme Palace > /dev/null 2>&1
    fi
}

# Clean up any previous test results
rm -rf TestResults.xcresult

# Skip the separate build step - xcodebuild test builds automatically and more efficiently
# Use parallel testing and optimized flags

# Use direct xcodebuild for faster execution (skip Fastlane overhead)
# Try multiple fallback strategies for CI compatibility
echo "Detecting test environment and finding suitable simulator..."

if [ "${BUILD_CONTEXT:-}" == "ci" ]; then
    echo "Running in CI environment"

    # List available simulators for debugging
    echo "Available iPhone simulators in CI:"
    xcrun simctl list devices available | grep iPhone | head -10

    # Pick the first available iPhone simulator by UDID — never rely on device names
    # since those vary across Xcode / macOS image versions.
    # Use grep -oE with a UUID regex to extract just the UDID, not the trailing
    # state word "(Shutdown)" which a greedy sed match would capture instead.
    # Also print installed runtimes for debugging in case no devices are found.
    echo "Installed simulator runtimes:"
    xcrun simctl list runtimes | grep iOS || echo "(none found)"

    SIMULATOR_ID=$(xcrun simctl list devices available \
        | grep "iPhone" \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1)

    if [ -z "$SIMULATOR_ID" ]; then
        echo "🔴 ERROR: No iPhone simulator available in this CI environment!"
        echo "Full simctl device list:"
        xcrun simctl list devices available
        exit 1
    fi

    SIMULATOR_NAME=$(xcrun simctl list devices available \
        | grep "$SIMULATOR_ID" \
        | sed 's/^[[:space:]]*//' \
        | sed 's/ (.*//' \
        | head -1)
    echo "Using simulator: $SIMULATOR_NAME ($SIMULATOR_ID)"

    # Forward CI-detection env vars into the simulator child process so the
    # in-test isRunningInCI check (GITHUB_ACTIONS / CI / BUILD_CONTEXT) sees
    # them. Without SIMCTL_CHILD_*, host env does not reach launchd_sim.
    export SIMCTL_CHILD_GITHUB_ACTIONS="${GITHUB_ACTIONS:-true}"
    export SIMCTL_CHILD_CI="${CI:-true}"
    export SIMCTL_CHILD_BUILD_CONTEXT="ci"

    # Execution isolation — test-pollution fix (docs/Testing/test-pollution-investigation-handoff.md).
    # CI previously ran serial single-process (all ~7k tests in ONE process/singleton-set), which
    # AMPLIFIES cross-test pollution: an early polluter that aborts mid-teardown leaves a process-global
    # (suspended queue, active mock scenario, stale registry) broken for thousands of later tests, so a
    # different, shifting victim set fails every run (AccountsManagerLaunchSnapshot / Borrow* etc.).
    # Parallel testing spawns simulator CLONES = SEPARATE PROCESSES: global state is per-clone, cross-shard
    # bleed is impossible, and any leak's blast radius is bounded to one clone's subset. The local path
    # already runs this way (workers=4) successfully; Xcode merges the clones into the single
    # TestResults.xcresult so the downstream summary.failed gate is unchanged. Tune via CI_TEST_WORKERS if a
    # runner has fewer cores (Xcode caps workers to available cores regardless).
    set +e
    xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "id=$SIMULATOR_ID" \
        -configuration Debug \
        -resultBundlePath TestResults.xcresult \
        -enableCodeCoverage YES \
        -retry-tests-on-failure \
        -test-iterations 3 \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 120 \
        -maximum-test-execution-time-allowance 300 \
        -parallel-testing-enabled YES \
        -maximum-parallel-testing-workers "${CI_TEST_WORKERS:-4}" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        GCC_OPTIMIZATION_LEVEL=0 \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        ENABLE_TESTABILITY=YES
    TEST_EXIT_CODE=$?
    set -e

    if [ ! -d "TestResults.xcresult" ]; then
        echo "🔴 ERROR: No xcresult produced — build likely failed before tests ran."
        exit 1
    fi

    echo "✅ Tests executed on: $SIMULATOR_NAME (exit code: $TEST_EXIT_CODE)"

    # Propagate the test exit code so CI detects failures
    if [ "$TEST_EXIT_CODE" -ne 0 ]; then
        echo "🔴 Tests failed with exit code: $TEST_EXIT_CODE"
        exit $TEST_EXIT_CODE
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
        maybe_clean
        
        # Fallback to name-based approach with common simulators
        # Updated for Xcode 26 / iOS 26 compatibility
        FALLBACK_SIMULATORS=("iPhone 16e" "iPhone 17" "iPhone 17 Pro" "iPhone 16" "iPhone 15" "iPhone 15 Pro")
        
        for SIM in "${FALLBACK_SIMULATORS[@]}"; do
            echo "Trying fallback simulator: $SIM"
            xcodebuild test \
                -project Palace.xcodeproj \
                -scheme Palace \
                -destination "platform=iOS Simulator,name=$SIM" \
                -configuration Debug \
                -resultBundlePath TestResults.xcresult \
                -enableCodeCoverage YES \
                -retry-tests-on-failure \
                -test-iterations 3 \
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
        # Clean only when explicitly requested (arch-conflict recovery); default
        # reuses warm DerivedData for a fast incremental local run.
        maybe_clean
        
        xcodebuild test \
            -project Palace.xcodeproj \
            -scheme Palace \
            -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
            -configuration Debug \
            -resultBundlePath TestResults.xcresult \
            -retry-tests-on-failure \
            -test-iterations 3 \
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

echo "✅ Unit tests execution completed."

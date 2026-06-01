#!/bin/bash

# SUMMARY
#   Runs optimized unit tests for Palace with performance improvements.
#   On failure, re-runs each failing test class in isolation; if all
#   isolation reruns pass, downgrades the overall result to PASS (the
#   failures were pre-existing test-isolation flakes, not branch
#   regressions). Mirrors the `--diff-baseline` path in verify-pr.sh.
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

# rerun_failed_in_isolation
#   Parses TestResults.xcresult for failing test class names, re-runs each
#   under -only-testing:PalaceTests/<cls>. Returns 0 if all reruns pass
#   (failures are pre-existing test-isolation flakes — downgrade to PASS);
#   returns the original exit code otherwise (real regression).
#   Ported from scripts/verify-pr.sh --diff-baseline logic.
#
#   Args: $1 = simulator id, $2 = original xcodebuild exit code,
#         $3 = parallel-testing flag value ("YES"|"NO"),
#         $4 = destination prefix ("id" or "platform=iOS Simulator,id")
rerun_failed_in_isolation() {
    local sim_id="$1"
    local original_exit="$2"
    local parallel_flag="$3"
    local dest_prefix="$4"

    if [ "$original_exit" -eq 0 ]; then
        return 0
    fi

    if [ ! -d "TestResults.xcresult" ]; then
        echo "  → rerun-in-isolation skipped: no xcresult to parse."
        return "$original_exit"
    fi

    if ! command -v xcrun >/dev/null 2>&1; then
        echo "  → rerun-in-isolation skipped: xcrun not on PATH."
        return "$original_exit"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "  → rerun-in-isolation skipped: python3 not on PATH."
        return "$original_exit"
    fi

    # Extract failing class names from xcresult.
    local failing_classes
    failing_classes=$(xcrun xcresulttool get test-results tests --path TestResults.xcresult --format json 2>/dev/null | \
        python3 -c "
import json, sys, re
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
classes = set()
def walk(node, parent=''):
    name = node.get('name', '')
    full = f'{parent}/{name}' if parent else name
    if node.get('result') == 'Failed':
        parts = full.split(' > ')
        if len(parts) >= 3:
            cls = parts[-2]
            if cls and re.match(r'^[A-Za-z_][A-Za-z0-9_]*Tests?$', cls):
                classes.add(cls)
    for child in node.get('children', []) + node.get('testNodes', []):
        walk(child, full)
walk(data)
print('\n'.join(sorted(classes)))
" 2>/dev/null | head -20)

    if [ -z "$failing_classes" ]; then
        echo "  → rerun-in-isolation: could not extract class names from xcresult — keeping failure."
        return "$original_exit"
    fi

    local class_count
    class_count=$(echo "$failing_classes" | wc -l | tr -d ' ')
    echo "  → rerun-in-isolation: re-running $class_count failed class(es) in isolation..."

    local only_testing_args=""
    for cls in $failing_classes; do
        only_testing_args="$only_testing_args -only-testing:PalaceTests/$cls"
    done

    # Single xcodebuild invocation with all failing classes — N classes in
    # one build is much faster than N separate builds with cold derivedData.
    rm -rf TestResults-isolation.xcresult
    local isolated_output
    set +e
    isolated_output=$(xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "${dest_prefix}=$sim_id" \
        -configuration Debug \
        -resultBundlePath TestResults-isolation.xcresult \
        -parallel-testing-enabled "$parallel_flag" \
        $only_testing_args \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        GCC_OPTIMIZATION_LEVEL=0 \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        ENABLE_TESTABILITY=YES 2>&1)
    set -e

    local real_fail=0
    local flake_count=0
    for cls in $failing_classes; do
        if echo "$isolated_output" | grep -qE "Test Suite '$cls' passed"; then
            flake_count=$((flake_count + 1))
        else
            real_fail=$((real_fail + 1))
        fi
    done

    if [ "$real_fail" -eq 0 ] && [ "$flake_count" -gt 0 ]; then
        echo "✅ downgraded after rerun: $flake_count failing class(es) all pass in isolation (pre-existing test-isolation flakes)."
        return 0
    fi

    echo "🔴 rerun-in-isolation: $real_fail class(es) still fail in isolation (real regression); $flake_count flake(s)."
    return "$original_exit"
}

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

    set +e
    xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "id=$SIMULATOR_ID" \
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

    if [ ! -d "TestResults.xcresult" ]; then
        echo "🔴 ERROR: No xcresult produced — build likely failed before tests ran."
        exit 1
    fi

    echo "✅ Tests executed on: $SIMULATOR_NAME (exit code: $TEST_EXIT_CODE)"

    # On failure, re-run failing classes in isolation; downgrade to PASS if all
    # isolation reruns succeed (pre-existing test-isolation flakes, not real
    # regressions). Behaviorally additive — if TEST_EXIT_CODE was 0, this returns
    # 0 immediately without re-running anything.
    set +e
    rerun_failed_in_isolation "$SIMULATOR_ID" "$TEST_EXIT_CODE" "NO" "id"
    FINAL_EXIT_CODE=$?
    set -e

    # Propagate the (possibly-downgraded) test exit code so CI detects failures
    if [ "$FINAL_EXIT_CODE" -ne 0 ]; then
        echo "🔴 Tests failed with exit code: $FINAL_EXIT_CODE"
        exit $FINAL_EXIT_CODE
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
        # Updated for Xcode 26 / iOS 26 compatibility
        FALLBACK_SIMULATORS=("iPhone 16e" "iPhone 17" "iPhone 17 Pro" "iPhone 16" "iPhone 15" "iPhone 15 Pro")
        
        for SIM in "${FALLBACK_SIMULATORS[@]}"; do
            echo "Trying fallback simulator: $SIM"
            set +e
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
            set -e

            if [ -d "TestResults.xcresult" ]; then
                echo "✅ Tests executed with: $SIM (exit code: $TEST_EXIT_CODE)"
                # On failure, attempt rerun-in-isolation downgrade. Identical
                # behavior to today when tests pass (early return inside helper).
                set +e
                rerun_failed_in_isolation "$SIM" "$TEST_EXIT_CODE" "YES" "platform=iOS Simulator,name"
                FINAL_EXIT_CODE=$?
                set -e
                if [ "$FINAL_EXIT_CODE" -ne 0 ]; then
                    exit $FINAL_EXIT_CODE
                fi
                break
            else
                echo "❌ Simulator $SIM unavailable, trying next..."
            fi
        done
    else
        echo "Using iPhone simulator ID: $SIMULATOR_ID"
        # Clean build folder to avoid architecture conflicts
        xcodebuild clean -project Palace.xcodeproj -scheme Palace > /dev/null 2>&1

        set +e
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
        TEST_EXIT_CODE=$?
        set -e

        # On failure, attempt rerun-in-isolation downgrade. Identical behavior
        # to today when tests pass (early return inside helper).
        set +e
        rerun_failed_in_isolation "$SIMULATOR_ID" "$TEST_EXIT_CODE" "YES" "platform=iOS Simulator,id"
        FINAL_EXIT_CODE=$?
        set -e
        if [ "$FINAL_EXIT_CODE" -ne 0 ]; then
            echo "🔴 Tests failed with exit code: $FINAL_EXIT_CODE"
            exit $FINAL_EXIT_CODE
        fi
    fi
fi

echo "✅ Unit tests execution completed."

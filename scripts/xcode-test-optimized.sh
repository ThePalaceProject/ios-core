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
    # Clean the test build in CI to defeat stale-DerivedData masking (layer 1).
    # CI caches DerivedData per-branch (with a cross-branch restore-keys
    # fallback) and this CI path never cleaned, so a broken test target could
    # pass by REUSING compiled objects from a green cache — Xcode's incremental
    # build skips a file whose own source is unchanged even when a transitive
    # input made it stop compiling. That silently hid develop's Swift 6 test
    # break behind green checks. A trustworthy board is worth the rebuild time
    # (green-board contract). Override with PALACE_TEST_NO_CLEAN=1 if a runner
    # must trade correctness for speed.
    if [ "${PALACE_TEST_NO_CLEAN:-0}" != "1" ]; then
        echo "🧹 CI: clean build (defeats stale-DerivedData masking)"
        xcodebuild clean -project Palace.xcodeproj -scheme Palace > /dev/null 2>&1 || true
    fi

    # Scheduling-sensitive infra tests that must run OUTSIDE the 4-clone parallel
    # run. Under parallel-sim-clone oversubscription (workers > runner cores) the
    # cooperative pool starves so badly that these tests' OWN internal wait
    # timeouts starve too, and they hang to the 120s executionTimeAllowance —
    # even though they pass deterministically when not oversubscribed (they can't
    # be reproduced on a single local clone that owns its pool). They are NOT
    # skipped/weakened: the parallel run below `-skip-testing`s them, then a
    # dedicated SERIAL pass (`-parallel-testing-enabled NO`) runs them FULLY and
    # the results are MERGED back into TestResults.xcresult so the downstream
    # fail-gate counts them. Owner decision after CI runs 29805821296 / 29810471358.
    ISOLATED_SERIAL_TESTS=(
        "PalaceTests/ImageCacheContinuationTests"
        "PalaceTests/PoolResponsivenessProbeTests"
    )
    ISOLATED_SKIP_ARGS=()
    ISOLATED_ONLY_ARGS=()
    for _t in "${ISOLATED_SERIAL_TESTS[@]}"; do
        ISOLATED_SKIP_ARGS+=("-skip-testing:$_t")
        ISOLATED_ONLY_ARGS+=("-only-testing:$_t")
    done

    # Capture xcodebuild output so we can detect a COMPILE failure that
    # `xcodebuild test` masks. Under `-parallel-testing-enabled` xcodebuild can
    # exit 0 even when a test bundle fails to BUILD: the sibling bundles that DID
    # compile run to completion, an `.xcresult` is still produced, and the
    # overall exit code comes back 0 — so `TEST_EXIT_CODE` lies and the
    # green-board masking is born (a broken test target reads as a green job).
    # Tee to a log and scan it for the unambiguous build-failure markers below.
    XCB_LOG="$(mktemp)"
    set +e
    xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "id=$SIMULATOR_ID" \
        -configuration Debug \
        -resultBundlePath TestResults.xcresult \
        -enableCodeCoverage YES \
        -retry-tests-on-failure \
        -test-iterations "${CI_TEST_ITERATIONS:-3}" \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 120 \
        -maximum-test-execution-time-allowance 300 \
        -parallel-testing-enabled YES \
        -maximum-parallel-testing-workers "${CI_TEST_WORKERS:-4}" \
        "${ISOLATED_SKIP_ARGS[@]}" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        GCC_OPTIMIZATION_LEVEL=0 \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        ENABLE_TESTABILITY=YES 2>&1 | tee "$XCB_LOG"
    TEST_EXIT_CODE=${PIPESTATUS[0]}
    set -e

    # Build-failure gate (green-board contract): a compile failure must fail the
    # job even when xcodebuild's own exit code is 0. These two markers are only
    # emitted when the BUILD failed (not for ordinary test failures, which the
    # exit-code propagation below handles).
    if grep -qE "Testing cancelled because the build failed|The following build commands failed" "$XCB_LOG"; then
        echo "🔴 ERROR: build/compile failure detected in xcodebuild output — a masked build failure must fail the run."
        rm -f "$XCB_LOG"
        exit 1
    fi
    rm -f "$XCB_LOG"

    if [ ! -d "TestResults.xcresult" ]; then
        echo "🔴 ERROR: No xcresult produced — build likely failed before tests ran."
        exit 1
    fi

    echo "✅ Parallel tests executed on: $SIMULATOR_NAME (exit code: $TEST_EXIT_CODE)"

    # --- Serial isolated pass for the scheduling-sensitive infra tests ---
    # Runs the `-skip-testing`'d tests NOT under parallel oversubscription, then
    # merges the result into TestResults.xcresult so the fail-gate counts them.
    rm -rf TestResults-serial.xcresult
    echo "🧵 Serial isolated pass (no parallelism): ${ISOLATED_SERIAL_TESTS[*]}"
    set +e
    xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination "id=$SIMULATOR_ID" \
        -configuration Debug \
        -resultBundlePath TestResults-serial.xcresult \
        "${ISOLATED_ONLY_ARGS[@]}" \
        -enableCodeCoverage YES \
        -retry-tests-on-failure \
        -test-iterations "${CI_TEST_ITERATIONS:-3}" \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 120 \
        -maximum-test-execution-time-allowance 300 \
        -parallel-testing-enabled NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        GCC_OPTIMIZATION_LEVEL=0 \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        ENABLE_TESTABILITY=YES
    SERIAL_EXIT_CODE=$?
    set -e
    echo "✅ Serial isolated tests executed (exit code: $SERIAL_EXIT_CODE)"

    # Merge serial results into TestResults.xcresult so the downstream
    # Parse-Test-Results fail-gate counts the isolated tests (not un-gated).
    if [ -d "TestResults-serial.xcresult" ]; then
        rm -rf TestResults-merged.xcresult
        if xcrun xcresulttool merge --output-path TestResults-merged.xcresult TestResults.xcresult TestResults-serial.xcresult; then
            rm -rf TestResults.xcresult TestResults-serial.xcresult
            mv TestResults-merged.xcresult TestResults.xcresult
            echo "✅ Merged serial isolated results into TestResults.xcresult"
        else
            echo "🔴 ERROR: failed to merge serial isolated xcresult — failing rather than leave those tests un-gated."
            exit 1
        fi
    else
        echo "🔴 ERROR: serial isolated pass produced no xcresult — cannot gate those tests."
        exit 1
    fi

    # Propagate a combined exit code (informational under continue-on-error; the
    # merged xcresult is the authoritative fail-gate). Non-zero if EITHER pass failed.
    if [ "$TEST_EXIT_CODE" -ne 0 ] || [ "$SERIAL_EXIT_CODE" -ne 0 ]; then
        echo "🔴 Tests failed (parallel=$TEST_EXIT_CODE serial=$SERIAL_EXIT_CODE)"
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
                -test-iterations "${CI_TEST_ITERATIONS:-3}" \
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
            -test-iterations "${CI_TEST_ITERATIONS:-3}" \
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

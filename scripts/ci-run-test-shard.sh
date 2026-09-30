#!/bin/bash
# SUMMARY
#   Run one CI test shard against products built by `build-for-testing`.
#
# USAGE (CI only; the Unit Tests workflow calls this from each matrix job)
#   scripts/ci-run-test-shard.sh <xctestrun> <plan.json> <shard-index> <out-dir>
#
#   Writes <out-dir>/TestResults.xcresult, <out-dir>/tests.json (the xcresult
#   test tree), <out-dir>/shard-report.json (what verify-union reads) and
#   <out-dir>/memory-samples.txt (runner memory every 15 s).
#   Exits non-zero when a test failed after its retries, when a pass produced
#   no result bundle, or when the bundle does not contain exactly the classes
#   the plan assigned to this shard.
#
# The flags follow the CI branch of scripts/xcode-test-optimized.sh, which is
# the single-job path this replaces in CI and is still the local CI-parity
# runner: the same retry scoping (no -test-repetition-relaunch-enabled; see
# scripts/tests/test_xcode_test_retry_scoping.py), a parallel pass followed by
# a serial pass for scripts/ci-isolated-serial-tests.txt, the same os_log
# suppression (PP-5273), and the same per-test allowances. Two things differ:
#
#   * 2 parallel workers per shard, not 4. The 2026-09 hang census traced the
#     allowance kills to memory pressure on the 3-CPU / 7 GB runner (compressor
#     and swap active, 11-35 processes page-faulting in lck_rw_sleep). Each
#     clone is a whole simulated device; a shard runs a third of the suite, so
#     it no longer needs 4 of them. CI_TEST_WORKERS overrides.
#   * One second chance for allowance kills (see second_chance below).
#
# prior-art-checked: xcode-test-optimized.sh builds and tests in one
# `xcodebuild test`; it cannot run against prebuilt products or a class subset.

set -euo pipefail

XCTESTRUN="$1"
PLAN="$2"
SHARD="$3"
OUT="$4"

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARDS_PY="$HERE/ci-test-shards.py"
DIAG_PY="$HERE/ci-runner-diagnostics.py"
mkdir -p "$OUT"
rm -rf "$OUT/parallel.xcresult" "$OUT/serial.xcresult" "$OUT/rerun.xcresult" \
       "$OUT/TestResults.xcresult" "$OUT/merged.xcresult" "$OUT/memory-samples.txt"

SIMULATOR_ID=$(xcrun simctl list devices available \
    | grep "iPhone" \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    | head -1)
if [ -z "$SIMULATOR_ID" ]; then
    echo "🔴 ERROR: no iPhone simulator available"
    xcrun simctl list devices available
    exit 1
fi
WORKERS="${CI_TEST_WORKERS:-2}"
echo "Shard $SHARD on simulator $SIMULATOR_ID, $WORKERS parallel worker(s)"

export SIMCTL_CHILD_GITHUB_ACTIONS="${GITHUB_ACTIONS:-true}"
export SIMCTL_CHILD_CI="${CI:-true}"
export SIMCTL_CHILD_BUILD_CONTEXT="ci"
if [ "${PALACE_CI_APP_LOGS:-0}" != "1" ]; then
    export TEST_RUNNER_OS_ACTIVITY_MODE=disable
fi

RETRY_ITER_ARGS=()
if [ "${CI_TEST_ITERATIONS:-3}" -gt 1 ]; then
    RETRY_ITER_ARGS=(-retry-tests-on-failure -test-iterations "${CI_TEST_ITERATIONS:-3}")
fi

# 120 s default / 300 s maximum, unchanged from the single-job workflow. XCTest
# rounds an allowance UP to whole minutes, so 60 s is the smallest value it
# honours. Measured over 35 runs (318,611 passing executions): p99 is 1.25 s
# and p99.9 is 10 s, but 21 passing executions took 60-151 s — almost all of
# them stalls in tests whose median is under 0.3 s. At 60 s those 21 would
# have been kills, and a kill is not retried, so the lower value would have
# traded one minute per hang for more red runs.
TIMEOUT_ARGS=(
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance 120
    -maximum-test-execution-time-allowance 300
    -collect-test-diagnostics on-failure
)

# Runner memory, sampled for the whole shard; summarized at the end so the
# per-shard peak is in the log next to the verdict.
python3 "$DIAG_PY" sample "$OUT/memory-samples.txt" --interval 15 &
SAMPLER=$!

# Bound the whole shard below the step's timeout-minutes, with SIGINT rather
# than the runner's SIGKILL: xcodebuild finalizes the result bundle on SIGINT,
# so a wedged run still uploads its spindumps and the tests that did finish.
SHARD_BUDGET_SECONDS="${SHARD_BUDGET_SECONDS:-1800}"
( trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
  sleep "$SHARD_BUDGET_SECONDS" & sleeper=$!
  wait "$sleeper"
  echo "🔴 shard $SHARD exceeded ${SHARD_BUDGET_SECONDS}s; interrupting xcodebuild so the result bundle is written"
  pkill -INT -f "xcodebuild test-without-building" || true ) &
WATCHDOG=$!
cleanup() {
    kill "$WATCHDOG" "$SAMPLER" 2>/dev/null || true
    python3 "$DIAG_PY" sample "$OUT/memory-samples.txt" --once >/dev/null 2>&1 || true
    python3 "$DIAG_PY" memory-summary "$OUT/memory-samples.txt" | sed "s/^/Shard $SHARD /" || true
}
trap cleanup EXIT

read_args() {  # $1 = parallel|serial -> one -only-testing arg per line
    python3 "$SHARDS_PY" args --plan "$PLAN" --shard "$SHARD" --kind "$1"
}

PARALLEL_ARGS=()
while IFS= read -r a; do PARALLEL_ARGS+=("$a"); done < <(read_args parallel)
SERIAL_ARGS=()
while IFS= read -r a; do SERIAL_ARGS+=("$a"); done < <(read_args serial)
echo "Shard $SHARD: ${#PARALLEL_ARGS[@]} parallel class(es), ${#SERIAL_ARGS[@]} serial class(es)"
if [ ${#PARALLEL_ARGS[@]} -eq 0 ] && [ ${#SERIAL_ARGS[@]} -eq 0 ]; then
    echo "🔴 ERROR: the plan gives shard $SHARD no classes"
    exit 1
fi

# $1 = bundle path, $2 = retry|once, rest = extra xcodebuild args. Echoes the
# exit code; xcodebuild's own output goes to stderr so it still reaches the log.
run_pass() {
    local bundle="$1" mode="$2"; shift 2
    local retry=()
    if [ "$mode" = "retry" ]; then retry=(${RETRY_ITER_ARGS[@]+"${RETRY_ITER_ARGS[@]}"}); fi
    set +e
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN" \
        -destination "id=$SIMULATOR_ID" \
        -resultBundlePath "$bundle" \
        -enableCodeCoverage YES \
        ${retry[@]+"${retry[@]}"} \
        "${TIMEOUT_ARGS[@]}" \
        "$@" >&2
    local rc=$?
    set -e
    echo "$rc"
}

merge_into_results() {  # bundles... -> $OUT/TestResults.xcresult
    if [ $# -eq 1 ]; then
        mv "$1" "$OUT/TestResults.xcresult"
        return
    fi
    xcrun xcresulttool merge --output-path "$OUT/merged.xcresult" "$@"
    rm -rf "$@"
    mv "$OUT/merged.xcresult" "$OUT/TestResults.xcresult"
}

PARALLEL_EXIT=0
if [ ${#PARALLEL_ARGS[@]} -gt 0 ]; then
    PARALLEL_EXIT=$(run_pass "$OUT/parallel.xcresult" retry \
        -parallel-testing-enabled YES \
        -maximum-parallel-testing-workers "$WORKERS" \
        "${PARALLEL_ARGS[@]}")
    echo "Parallel pass exit code: $PARALLEL_EXIT"
    [ -d "$OUT/parallel.xcresult" ] || { echo "🔴 ERROR: parallel pass wrote no result bundle"; exit 1; }
fi

SERIAL_EXIT=0
if [ ${#SERIAL_ARGS[@]} -gt 0 ]; then
    echo "🧵 Serial isolated pass: ${SERIAL_ARGS[*]}"
    SERIAL_EXIT=$(run_pass "$OUT/serial.xcresult" retry -parallel-testing-enabled NO "${SERIAL_ARGS[@]}")
    echo "Serial pass exit code: $SERIAL_EXIT"
    [ -d "$OUT/serial.xcresult" ] || { echo "🔴 ERROR: serial pass wrote no result bundle"; exit 1; }
fi

BUNDLES=()
for b in "$OUT/parallel.xcresult" "$OUT/serial.xcresult"; do
    if [ -d "$b" ]; then BUNDLES+=("$b"); fi
done
merge_into_results "${BUNDLES[@]}"
xcrun xcresulttool get test-results tests --path "$OUT/TestResults.xcresult" > "$OUT/tests.json"

TEST_EXIT=0
if [ "$PARALLEL_EXIT" -ne 0 ] || [ "$SERIAL_EXIT" -ne 0 ]; then TEST_EXIT=1; fi

# second_chance: `-retry-tests-on-failure` never retries a test XCTest killed at
# its execution-time allowance (0 of 28 in the 2026-09 census), so one runner
# stall fails the shard. When EVERY failure in the shard is such a kill, re-run
# just those tests, once, serially, in a fresh test process. An assertion
# failure anywhere in the shard means no second chance for anything. The
# re-run is in the log as ordinary test lines (ci-test-history.py --scan shows
# "#1 killed, #2 passed") and merged into the result bundle, where the test
# reads "passed after 1 retry" — it is never hidden.
if [ "$TEST_EXIT" -ne 0 ]; then
    KILL_ARGS=()
    KILL_STATUS=0
    KILL_OUT=$(python3 "$SHARDS_PY" kills --tests-json "$OUT/tests.json") || KILL_STATUS=$?
    while IFS= read -r a; do if [ -n "$a" ]; then KILL_ARGS+=("$a"); fi; done <<< "$KILL_OUT"
    case "$KILL_STATUS" in
        0)
            IDS=()
            for a in "${KILL_ARGS[@]}"; do IDS+=("${a#-only-testing:}"); done
            echo "::warning title=Second chance for allowance kills::shard $SHARD: ${#IDS[@]} test(s) were killed at the execution-time allowance, which -retry-tests-on-failure does not retry. Re-running only those, once, in a fresh test process: ${IDS[*]}"
            RERUN_EXIT=$(run_pass "$OUT/rerun.xcresult" once -parallel-testing-enabled NO "${KILL_ARGS[@]}")
            echo "Second-chance pass exit code: $RERUN_EXIT"
            if [ -d "$OUT/rerun.xcresult" ]; then
                xcrun xcresulttool get test-results tests --path "$OUT/rerun.xcresult" > "$OUT/rerun-tests.json"
                if [ "$RERUN_EXIT" -eq 0 ] && python3 "$SHARDS_PY" check-rerun --tests-json "$OUT/rerun-tests.json" "${IDS[@]}"; then
                    TEST_EXIT=0
                    echo "::warning title=Allowance kills passed on the second chance::shard $SHARD: ${IDS[*]} — each was killed once at the allowance and passed when re-run alone. Read the spindump summary below before treating this as the test's defect or as noise."
                else
                    echo "::error title=Allowance kill repeated::shard $SHARD: the second chance did not pass for ${IDS[*]}"
                fi
                merge_into_results "$OUT/TestResults.xcresult" "$OUT/rerun.xcresult"
                xcrun xcresulttool get test-results tests --path "$OUT/TestResults.xcresult" > "$OUT/tests.json"
            else
                echo "::error::the second-chance pass wrote no result bundle"
            fi
            ;;
        3) echo "Not every failure in shard $SHARD was an allowance kill; no second chance." ;;
        *) echo "xcodebuild failed but the bundle names no failed test (a crash or an infrastructure failure); no second chance." ;;
    esac
fi

VERIFY_EXIT=0
python3 "$SHARDS_PY" verify-shard --plan "$PLAN" --shard "$SHARD" \
    --tests-json "$OUT/tests.json" --out "$OUT/shard-report.json" || VERIFY_EXIT=$?

if [ "$TEST_EXIT" -ne 0 ] || [ "$VERIFY_EXIT" -ne 0 ]; then
    echo "🔴 Shard $SHARD failed (parallel=$PARALLEL_EXIT serial=$SERIAL_EXIT verify=$VERIFY_EXIT)"
    exit 1
fi
echo "✅ Shard $SHARD passed"

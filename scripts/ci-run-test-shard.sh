#!/bin/bash
# SUMMARY
#   Run one CI test shard against products built by `build-for-testing`.
#
# USAGE (CI only; the Unit Tests workflow calls this from each matrix job)
#   scripts/ci-run-test-shard.sh <xctestrun> <plan.json> <shard-index> <out-dir>
#
#   Writes <out-dir>/TestResults.xcresult, <out-dir>/tests.json (the xcresult
#   test tree), <out-dir>/shard-report.json (what verify-union reads) and
#   <out-dir>/memory-samples.txt (runner memory every 15 s). After a crashed
#   pass, and whenever the shard fails, the bundles that were never merged and
#   the per-pass xcodebuild logs are kept in <out-dir>/partial/ for upload.
#   Exits non-zero when a test failed after its retries, when a pass produced
#   no result bundle, or when the bundle does not contain exactly the classes
#   the plan assigned to this shard.
#
# The flags follow the CI branch of scripts/xcode-test-optimized.sh, which is
# the single-job path this replaces in CI and is still the local CI-parity
# runner: the same retry scoping (no -test-repetition-relaunch-enabled; see
# scripts/tests/test_xcode_test_retry_scoping.py), a parallel pass followed by
# a serial pass for scripts/ci-isolated-serial-tests.txt, the same os_log
# suppression (PP-5273), and the same per-test allowances. These things differ:
#
#   * 2 parallel workers per shard, not 4. The 2026-09 hang census traced the
#     allowance kills to memory pressure on the 3-CPU / 7 GB runner (compressor
#     and swap active, 11-35 processes page-faulting in lck_rw_sleep). Each
#     clone is a whole simulated device; a shard runs a third of the suite, so
#     it no longer needs 4 of them. CI_TEST_WORKERS overrides.
#   * One second chance for allowance kills (see second_chance below).
#   * One relaunch for classes a test runner never ran (see relaunch below).
#   * One retry of a pass that xcodebuild itself crashed with no test failure
#     recorded (see run_pass below).
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
       "$OUT/relaunch-parallel.xcresult" "$OUT/relaunch-serial.xcresult" \
       "$OUT/TestResults.xcresult" "$OUT/merged.xcresult" "$OUT/memory-samples.txt" \
       "$OUT"/*-crash-retry.xcresult "$OUT"/*.log "$OUT/partial"

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
# A crashed pass leaves a bundle that may not be finalized, and a failing shard
# exits before its bundles are merged into TestResults.xcresult. Either way the
# failure text would otherwise be lost, so the bundle (readable or not) and the
# raw log of each pass are moved to $OUT/partial, which the workflow uploads.
PARTIAL="$OUT/partial"
keep_partial() {  # paths... -> moved (bundles) or copied (logs) into $PARTIAL
    local p
    for p in "$@"; do
        [ -e "$p" ] || continue
        mkdir -p "$PARTIAL"
        rm -rf "${PARTIAL:?}/$(basename "$p")"
        case "$p" in
            *.xcresult) mv "$p" "$PARTIAL/" ;;
            *) cp "$p" "$PARTIAL/" ;;
        esac
    done
}
cleanup() {
    # Only the passing verdict at the end sets SHARD_PASSED. Anything else that
    # ends the script is a failure: /bin/bash 3.2 reports an unbound-variable
    # abort under `set -u` as status 0, even to this trap.
    local rc=$?
    if [ "$rc" -eq 0 ] && [ "${SHARD_PASSED:-0}" != 1 ]; then
        echo "🔴 shard $SHARD: the script stopped before reaching a verdict"
        rc=1
    fi
    kill "$WATCHDOG" "$SAMPLER" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        local b
        for b in "$OUT"/*.xcresult; do
            [ "$b" = "$OUT/TestResults.xcresult" ] || keep_partial "$b"
        done
        keep_partial "$OUT"/*.log
    fi
    python3 "$DIAG_PY" sample "$OUT/memory-samples.txt" --once >/dev/null 2>&1 || true
    python3 "$DIAG_PY" memory-summary "$OUT/memory-samples.txt" | sed "s/^/Shard $SHARD /" || true
    exit "$rc"
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

# $1 = bundle path, $2 = retry|once, rest = extra xcodebuild args. Sets
# PASS_EXIT to xcodebuild's exit code.
#
# One retry for xcodebuild's own crash. On Xcode 26.3, XCTHarness sometimes
# aborts mid-pass with "** INTERNAL ERROR: Uncaught exception **" /
# "Unexpected operation <IDERunOperation ...>" and exit 134 (PRs #1562 and
# #1565), leaving a result bundle with no Info.plist that nothing downstream
# can read. When the log has that marker or exit 134 and no test-failure line,
# the same pass (same classes, same flags) runs once more into a fresh bundle.
# A crash after a test failed is not retried, because a retry could turn that
# failure green; a second crash fails the shard. Only failures logged before the
# first marker count: Xcode 26.6 logs the test in flight as failed after the
# marker when it gives up on it (run 36952741418), and that test must pass on the
# retry anyway. Exit 134 with no marker counts every failure in the log.
XCB_INTERNAL_ERROR_TEXT='** INTERNAL ERROR: Uncaught exception **'
XCB_INTERNAL_ERROR='\*\* INTERNAL ERROR: Uncaught exception \*\*'
XCB_TEST_FAILED="Test [Cc]ase '[^']+' failed"
PASS_EXIT=0
run_xcodebuild() {  # $1 = bundle, $2 = log, rest = xcodebuild args
    local bundle="$1" log="$2"; shift 2
    rm -rf "$bundle"
    set +e
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN" \
        -destination "id=$SIMULATOR_ID" \
        -resultBundlePath "$bundle" \
        -enableCodeCoverage YES \
        "$@" 2>&1 | tee "$log"
    PASS_EXIT=${PIPESTATUS[0]}
    set -e
}
xcodebuild_crashed() {  # $1 = log; exit status of the pass in PASS_EXIT
    [ "$PASS_EXIT" -ne 0 ] || return 1
    [ "$PASS_EXIT" -eq 134 ] || grep -qE "$XCB_INTERNAL_ERROR" "$1"
}
failures_before_crash() {  # $1 = log; failed-test lines before the first marker
    awk -v m="$XCB_INTERNAL_ERROR_TEXT" 'index($0, m) { exit } { print }' "$1" \
        | grep -E "$XCB_TEST_FAILED" || true
}
tests_in_flight_at_crash() {  # $1 = log; names of tests failed after the first marker
    awk -v m="$XCB_INTERNAL_ERROR_TEXT" 'seen { print } index($0, m) { seen = 1 }' "$1" \
        | grep -oE "$XCB_TEST_FAILED" | sed -E "s/^Test [Cc]ase '([^']+)' failed$/\1/" \
        | sort -u | paste -sd, - || true
}
run_pass() {
    local bundle="$1" mode="$2"; shift 2
    local retry=()
    if [ "$mode" = "retry" ]; then retry=(${RETRY_ITER_ARGS[@]+"${RETRY_ITER_ARGS[@]}"}); fi
    local args=(${retry[@]+"${retry[@]}"} "${TIMEOUT_ARGS[@]}" "$@")
    local name; name="$(basename "$bundle" .xcresult)"
    local log="$OUT/$name.log"
    run_xcodebuild "$bundle" "$log" "${args[@]}"
    xcodebuild_crashed "$log" || return 0
    if [ -n "$(failures_before_crash "$log")" ]; then
        echo "::error title=xcodebuild crashed after a test failed::shard $SHARD, $name pass: xcodebuild exited $PASS_EXIT after recording a test failure. Not retrying, because a retry could hide that failure."
        exit 1
    fi
    local in_flight; in_flight="$(tests_in_flight_at_crash "$log")"
    local discounted=""
    if [ -n "$in_flight" ]; then
        discounted=" Discounted the failure of $in_flight, logged after the crash marker: it was the test in flight when xcodebuild crashed, and it must pass on the retry."
    fi
    echo "::warning title=xcodebuild crashed; retrying the pass once::shard $SHARD, $name pass: xcodebuild exited $PASS_EXIT with no test failure recorded before the crash (exit 134 or '** INTERNAL ERROR: Uncaught exception **', an XCTHarness crash). Its result bundle is unreadable, so the same classes run once more into a fresh bundle.$discounted"
    local fresh="$OUT/$name-crash-retry.xcresult"
    keep_partial "$bundle" "$log"
    run_xcodebuild "$fresh" "$OUT/$name-crash-retry.log" "${args[@]}"
    if xcodebuild_crashed "$OUT/$name-crash-retry.log"; then
        echo "::error title=xcodebuild crashed again::shard $SHARD, $name pass: the retry also crashed (exit $PASS_EXIT). Failing the shard."
        exit 1
    fi
    if [ -d "$fresh" ]; then mv "$fresh" "$bundle"; fi
    echo "Shard $SHARD, $name pass: the retry after the crash exited $PASS_EXIT"
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
    run_pass "$OUT/parallel.xcresult" retry \
        -parallel-testing-enabled YES \
        -maximum-parallel-testing-workers "$WORKERS" \
        "${PARALLEL_ARGS[@]}"
    PARALLEL_EXIT=$PASS_EXIT
    echo "Parallel pass exit code: $PARALLEL_EXIT"
    [ -d "$OUT/parallel.xcresult" ] || { echo "🔴 ERROR: parallel pass wrote no result bundle"; exit 1; }
fi

SERIAL_EXIT=0
if [ ${#SERIAL_ARGS[@]} -gt 0 ]; then
    echo "🧵 Serial isolated pass: ${SERIAL_ARGS[*]}"
    run_pass "$OUT/serial.xcresult" retry -parallel-testing-enabled NO "${SERIAL_ARGS[@]}"
    SERIAL_EXIT=$PASS_EXIT
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

# relaunch: a test runner that never connects or dies ("The test runner hung
# before establishing connection", "(ipc/mig) server died") takes the classes it
# was given with it, and xcodebuild does not hand them to another runner (run
# 36799592179: 162 of 516 classes; run 36797084975). Relaunch exactly the
# shard's classes that are absent from the bundle, once, with the pass settings
# they had. It never re-runs a test that ran, so it cannot turn a failure into
# a pass; whether the original non-zero exit is then explained is decided below
# from the merged bundle.
read_lost() {  # $1 = parallel|serial
    python3 "$SHARDS_PY" lost --plan "$PLAN" --shard "$SHARD" --tests-json "$OUT/tests.json" --kind "$1"
}
RUNNER_FAILURES=$(python3 "$SHARDS_PY" runner-failures --tests-json "$OUT/tests.json")
LOST_PARALLEL=()
while IFS= read -r a; do LOST_PARALLEL+=("$a"); done < <(read_lost parallel)
LOST_SERIAL=()
while IFS= read -r a; do LOST_SERIAL+=("$a"); done < <(read_lost serial)
LOST_COUNT=$(( ${#LOST_PARALLEL[@]} + ${#LOST_SERIAL[@]} ))
RUNNER_RECOVERED=0
if [ "$LOST_COUNT" -gt 0 ]; then
    REASON="${RUNNER_FAILURES:-no runner failure is recorded in the result bundle}"
    echo "::warning title=Runner failure: relaunching classes that never ran::shard $SHARD: $LOST_COUNT class(es) never ran, which is a runner failure, not a test failure. Recorded: ${REASON//$'\n'/ | }. Relaunching them once."
    echo "Relaunching:" ${LOST_PARALLEL[@]+"${LOST_PARALLEL[@]}"} ${LOST_SERIAL[@]+"${LOST_SERIAL[@]}"}
    RELAUNCH_EXIT=0
    RELAUNCH_BUNDLES=()
    if [ ${#LOST_PARALLEL[@]} -gt 0 ]; then
        run_pass "$OUT/relaunch-parallel.xcresult" retry \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers "$WORKERS" \
            "${LOST_PARALLEL[@]}"
        e=$PASS_EXIT
        if [ "$e" -ne 0 ]; then RELAUNCH_EXIT=$e; fi
        if [ -d "$OUT/relaunch-parallel.xcresult" ]; then RELAUNCH_BUNDLES+=("$OUT/relaunch-parallel.xcresult"); fi
    fi
    if [ ${#LOST_SERIAL[@]} -gt 0 ]; then
        run_pass "$OUT/relaunch-serial.xcresult" retry -parallel-testing-enabled NO "${LOST_SERIAL[@]}"
        e=$PASS_EXIT
        if [ "$e" -ne 0 ]; then RELAUNCH_EXIT=$e; fi
        if [ -d "$OUT/relaunch-serial.xcresult" ]; then RELAUNCH_BUNDLES+=("$OUT/relaunch-serial.xcresult"); fi
    fi
    echo "Relaunch exit code: $RELAUNCH_EXIT"
    if [ ${#RELAUNCH_BUNDLES[@]} -gt 0 ]; then
        merge_into_results "$OUT/TestResults.xcresult" "${RELAUNCH_BUNDLES[@]}"
        xcrun xcresulttool get test-results tests --path "$OUT/TestResults.xcresult" > "$OUT/tests.json"
    fi
    STILL_LOST=$( { read_lost parallel; read_lost serial; } | wc -l | tr -d ' ')
    if [ "$RELAUNCH_EXIT" -eq 0 ] && [ "$STILL_LOST" -eq 0 ]; then
        RUNNER_RECOVERED=1
        echo "::warning title=Runner failure recovered::shard $SHARD: the $LOST_COUNT class(es) the runner lost ran on relaunch and passed."
    else
        echo "::error title=Runner failure not recovered::shard $SHARD: after one relaunch, $STILL_LOST class(es) still did not run (relaunch exit $RELAUNCH_EXIT)."
    fi
fi

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
            run_pass "$OUT/rerun.xcresult" once -parallel-testing-enabled NO "${KILL_ARGS[@]}"
            RERUN_EXIT=$PASS_EXIT
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
        4)
            if [ "$RUNNER_RECOVERED" -eq 1 ]; then
                TEST_EXIT=0
                echo "Shard $SHARD: the only failure was the runner failure, and every class it lost passed on relaunch."
            elif [ -n "$RUNNER_FAILURES" ] && [ "$LOST_COUNT" -eq 0 ]; then
                echo "::error title=Runner failure::shard $SHARD: ${RUNNER_FAILURES//$'\n'/ | }. It lost no class (every assigned class ran), so nothing was relaunched, but which tests the failure cost cannot be read from the bundle; re-run the shard."
            else
                echo "xcodebuild failed but the bundle names no failed test (a crash or an infrastructure failure); no second chance."
            fi
            ;;
        *) echo "xcodebuild failed but the failed tests could not be read from the bundle; no second chance." ;;
    esac
fi

VERIFY_EXIT=0
python3 "$SHARDS_PY" verify-shard --plan "$PLAN" --shard "$SHARD" \
    --tests-json "$OUT/tests.json" --out "$OUT/shard-report.json" || VERIFY_EXIT=$?

if [ "$TEST_EXIT" -ne 0 ] || [ "$VERIFY_EXIT" -ne 0 ]; then
    echo "🔴 Shard $SHARD failed (parallel=$PARALLEL_EXIT serial=$SERIAL_EXIT verify=$VERIFY_EXIT)"
    exit 1
fi
SHARD_PASSED=1
echo "✅ Shard $SHARD passed"

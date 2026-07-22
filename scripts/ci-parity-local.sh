#!/usr/bin/env bash
#
# ci-parity-local.sh — reproduce GitHub Actions macos-15 CI test conditions
# on a local (many-core) developer Mac, so CI-only flakes/crashes reproduce and
# verify BEFORE a PR/merge instead of costing a ~45-min GitHub cycle each.
#
# WHY THIS EXISTS
# ---------------
# GitHub's macos-15 runners have ~3 vCPUs. A dev Mac has many more (e.g. 24).
# `scripts/xcode-test-optimized.sh` requests `-maximum-parallel-testing-workers 4`;
# on the 3-core runner that OVERSUBSCRIBES the CPU, so a test that waits on
# fire-and-forget async work via a wall-clock/hop deadline STARVES (the async op
# loses the CPU race) and the suite goes red with a shifting victim set. On a
# 24-core Mac the same run has ample CPU → the async work never starves → the
# flake is invisible locally. Likewise an off-main-@MainActor leak only SIGTRAPs
# a clone under the full ~7k-test interleaving.
#
# This harness closes BOTH gaps:
#   1. Runs the EXACT CI script (`scripts/xcode-test-optimized.sh`, full suite,
#      identical flags) — so the interleaving that triggers crashes is present.
#   2. Pins the run to a small number of effective cores via CPU pressure
#      (busy-loop burners occupying `ncpu - CI_PARITY_CORES` cores) — so the
#      starvation that surfaces the deadline-poll flakes is present.
#
# USAGE
#   scripts/ci-parity-local.sh                 # default: simulate 3 cores, 2 workers
#   CI_PARITY_CORES=3 CI_PARITY_WORKERS=2 scripts/ci-parity-local.sh
#   CI_PARITY_NO_PRESSURE=1 scripts/ci-parity-local.sh   # full suite, no CPU pinning
#
# EXIT CODE
#   0  → the run matched CI's fail gate (no test failed all 3 iterations)
#   1  → at least one test failed all retries (a real CI-parity failure) OR build failed
#
# It parses TestResults.xcresult with the SAME parser CI uses
# (scripts/parse-xcresult.py) and applies the SAME gate (summary.failed > 0),
# so a pass here means a pass there.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET_CORES="${CI_PARITY_CORES:-3}"       # emulate a 3-vCPU GitHub runner
WORKERS="${CI_PARITY_WORKERS:-2}"          # macos-15 effectively runs ~2 clones
NCPU="$(sysctl -n hw.ncpu)"

echo "════════════════════════════════════════════════════════════════"
echo " CI-parity local run"
echo "   host cores:        $NCPU"
echo "   simulated cores:   $TARGET_CORES   (GitHub macos-15 ≈ 3 vCPU)"
echo "   parallel workers:  $WORKERS"
echo "   pressure:          ${CI_PARITY_NO_PRESSURE:+DISABLED}${CI_PARITY_NO_PRESSURE:-enabled}"
echo "════════════════════════════════════════════════════════════════"

BURN_PIDS=()
cleanup() {
    if [ "${#BURN_PIDS[@]}" -gt 0 ]; then
        kill "${BURN_PIDS[@]}" 2>/dev/null || true
        wait "${BURN_PIDS[@]}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# --- CPU pressure: occupy (ncpu - TARGET_CORES) cores with tight loops so the
#     test run + sim clones contend for only ~TARGET_CORES, mirroring the runner.
if [ -z "${CI_PARITY_NO_PRESSURE:-}" ]; then
    BURN=$(( NCPU - TARGET_CORES ))
    if [ "$BURN" -gt 0 ]; then
        echo "🔥 Spawning $BURN CPU burners to pin the run to ~$TARGET_CORES effective cores…"
        for _ in $(seq 1 "$BURN"); do
            # `yes` is a tight, single-core busy loop; discard its output.
            yes > /dev/null 2>&1 &
            BURN_PIDS+=($!)
        done
    fi
fi

# --- Run the EXACT CI test script. BUILD_CONTEXT=ci selects the CI code path
#     (picks a sim by UDID, forwards SIMCTL_CHILD CI-detection env, runs the
#     parallel + serial-isolated passes, merges xcresults). CI_TEST_WORKERS
#     drives -maximum-parallel-testing-workers.
export BUILD_CONTEXT=ci
export CI_TEST_WORKERS="$WORKERS"
# Keep the same CI-detection env the in-test isRunningInCI check reads.
export CI="${CI:-true}"
export GITHUB_ACTIONS="${GITHUB_ACTIONS:-true}"

echo "▶️  ./scripts/xcode-test-optimized.sh (full suite, CI flags)…"
set +e
./scripts/xcode-test-optimized.sh 2>&1 | tee ci-parity-output.log
SCRIPT_EXIT=${PIPESTATUS[0]}
set -e 2>/dev/null || true

# --- Apply the SAME gate CI applies: parse the merged xcresult and fail on any
#     test that failed all retries (summary.failed > 0).
RESULT_PATH="TestResults.xcresult"
[ -d TestResults-merged.xcresult ] && RESULT_PATH="TestResults-merged.xcresult"

if [ ! -d "$RESULT_PATH" ]; then
    echo "🔴 CI-PARITY: no xcresult produced (build failure?) — script exit $SCRIPT_EXIT"
    exit 1
fi

python3 scripts/parse-xcresult.py "$RESULT_PATH" --json ci-parity-data.json >/dev/null 2>&1 || true
FAILED=$(python3 -c "import json,sys
try:
    d=json.load(open('ci-parity-data.json')); s=d.get('summary',{})
    print(s.get('failed',0))
except Exception:
    print(-1)" 2>/dev/null)

echo "════════════════════════════════════════════════════════════════"
if [ "$FAILED" = "0" ] && [ "$SCRIPT_EXIT" = "0" ]; then
    # Stamp this exact commit as CI-parity-verified so the pre-push gate
    # (scripts/check-ci-parity-stamp.sh) can require it before a PR/merge.
    GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"
    if [ -n "$GIT_DIR" ]; then
        git rev-parse HEAD > "$GIT_DIR/ci-parity-pass.sha" 2>/dev/null || true
    fi
    echo "✅ CI-PARITY PASS — no test failed all retries. Safe to PR/merge."
    echo "   Stamped $(git rev-parse --short HEAD 2>/dev/null) as CI-parity-verified."
    exit 0
else
    echo "🔴 CI-PARITY FAIL — failed=$FAILED, script exit=$SCRIPT_EXIT"
    echo "   Distinct failing tests (failed all 3 retries):"
    python3 scripts/parse-xcresult.py "$RESULT_PATH" 2>&1 | grep -E "✗" | sed 's/^/     /' | head -40 || true
    echo "   Full log: ci-parity-output.log   |   parsed: ci-parity-data.json"
    exit 1
fi

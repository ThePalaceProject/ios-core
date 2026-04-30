#!/usr/bin/env bash
# test-visual-regression.sh — end-to-end smoke test for the visual-regression
# infrastructure (PR #889 + the chaos-qa scaffolding).
#
# Runs (in order, each gated on the previous):
#   1. chaos-targets.py — verify YAML parser matches changed-file → seed
#   2. marks-diff.py — verify auto-finding generation against today's corpus
#   3. generate-regression-report.py with --fixtures-dir — verify Visual
#      Coverage Matrix renders
#   4. xcodebuild test (Palace scheme) — run AnonymousBorrowBaselineFixtureTests
#
# Each step prints PASS / FAIL with one-line evidence. Exit code is the
# count of failed steps.
#
# Usage:
#   ./scripts/test-visual-regression.sh [--udid <UDID>]
#
# Requires:
#   - Repo deps wired (Carthage, submodules, secrets, adobe-rmsdk)
#   - A booted simulator (use --udid or first booted iPhone is picked)
#   - python3, ruby/xcodeproj (for prior pbxproj wire-in, not this script)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

UDID=""
while (( "$#" )); do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl list devices iPhone | awk '/Booted/ {print $NF; exit}' | tr -d '()')
    [[ -z "$UDID" ]] && { echo "error: no booted iPhone sim and no --udid given" >&2; exit 1; }
fi

PASS=0
FAIL=0
report() {
    local label=$1 status=$2 detail=$3
    if [[ "$status" == "PASS" ]]; then
        PASS=$((PASS + 1))
        printf "  ✓ %-50s %s\n" "$label" "$detail"
    else
        FAIL=$((FAIL + 1))
        printf "  ✗ %-50s %s\n" "$label" "$detail"
    fi
}

echo "=== Visual-regression smoke test ==="
echo "  repo: $REPO_ROOT"
echo "  udid: $UDID"
echo

# 1. chaos-targets.py
echo "[1/4] chaos-targets.py"
out=$(python3 scripts/chaos-targets.py Palace/Accounts/Library/AccountsManager.swift 2>&1)
if echo "$out" | grep -q "anonymous-borrow"; then
    report "AccountsManager → anonymous-borrow seed" PASS "$(echo "$out" | head -1)"
else
    report "AccountsManager → anonymous-borrow seed" FAIL "got: $out"
fi
out=$(python3 scripts/chaos-targets.py Palace/Book/UI/BookDetail/BorrowReducer.swift 2>&1)
if echo "$out" | grep -q "anonymous-borrow"; then
    report "BorrowReducer → anonymous-borrow seed" PASS "$(echo "$out" | head -1)"
else
    report "BorrowReducer → anonymous-borrow seed" FAIL "got: $out"
fi

# 2. marks-diff.py
echo
echo "[2/4] marks-diff.py"
diff_out=$(python3 scripts/marks-diff.py \
    --baseline-dir .specterqa/fixtures/baselines/3.0.0/anonymous-borrow \
    --candidate-dir .specterqa/fixtures/baselines/3.0.1/anonymous-borrow \
    --tolerance 50 2>&1 | head -1)
n=$(echo "$diff_out" | grep -oE '[0-9]+' | head -1 || echo 0)
if (( n > 10 )); then
    report "Diff produces findings against today's corpus" PASS "n=$n"
else
    report "Diff produces findings against today's corpus" FAIL "got: $diff_out"
fi

# 3. generate-regression-report.py with --fixtures-dir
echo
echo "[3/4] generate-regression-report.py --fixtures-dir"
report_out=/tmp/vr-smoke-report.html
findings_csv="${HOME}/Desktop/regression-PP-4164/findings.csv"
[[ ! -f "$findings_csv" ]] && findings_csv=".specterqa/fixtures/README.md"  # fallback dummy
python3 scripts/generate-regression-report.py \
    --csv "$findings_csv" \
    --output "$report_out" \
    --baseline-version 3.0.0 \
    --candidate-version 3.0.1 \
    --fixtures-dir .specterqa/fixtures/baselines \
    --title "VR smoke test" > /tmp/vr-smoke-report.log 2>&1
if grep -q "Visual Coverage Matrix" "$report_out" 2>/dev/null; then
    report "Visual Coverage Matrix renders in HTML" PASS "size=$(stat -f %z "$report_out")B"
else
    report "Visual Coverage Matrix renders in HTML" FAIL "log: $(tail -2 /tmp/vr-smoke-report.log)"
fi

# 4. xcodebuild test
echo
echo "[4/4] xcodebuild test -only-testing:PalaceTests/AnonymousBorrowBaselineFixtureTests"
test_log=/tmp/vr-smoke-test.log
xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:PalaceTests/AnonymousBorrowBaselineFixtureTests \
    test > "$test_log" 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -q "Test Suite 'AnonymousBorrowBaselineFixtureTests' passed" "$test_log"; then
    cases=$(grep -c "Test Case .*passed" "$test_log" || echo 0)
    report "AnonymousBorrowBaselineFixtureTests pass" PASS "$cases case(s)"
else
    failures=$(grep -c "Test Case .*failed" "$test_log" || echo 0)
    report "AnonymousBorrowBaselineFixtureTests pass" FAIL "rc=$rc, $failures failure(s); see $test_log"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
exit $FAIL

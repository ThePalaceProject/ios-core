#!/bin/bash
# verify-pr.sh — Full verification battery before PR creation
# Runs all available testing tools and reports outcomes.
# Exit 0 if all checks pass, 1 if any fail.
#
# Usage:
#   scripts/verify-pr.sh                     # Run all checks
#   scripts/verify-pr.sh --quick             # Skip mutation testing (faster)
#   scripts/verify-pr.sh --report <file>     # Write JSON report to file
#   scripts/verify-pr.sh --simdrive          # Also replay .simdrive/journeys/*.yaml
#                                            # via simdrive (opt-in, requires
#                                            # `pip3 install --pre simdrive` and
#                                            # a paired ~/.simdrive/recordings/<n>/)
#
# Designed to be called by:
#   - Claude Code agents before PR creation
#   - forgeos-session.sh evidence (comprehensive mode)
#   - CI workflows for gating

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

QUICK=false
REPORT_FILE=""
SIMDRIVE=false
SIM_ID="DF4A2A27-9888-429D-A749-2E157A049A37"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --report) REPORT_FILE="$2"; shift 2 ;;
    --simdrive) SIMDRIVE=true; shift ;;
    *) shift ;;
  esac
done

# Detect changed files against base branch
detect_base_branch() {
  for candidate in origin/develop origin/main origin/master; do
    if git rev-parse --verify "$candidate" &>/dev/null; then
      echo "$candidate"
      return
    fi
  done
  echo "HEAD~10"
}

BASE=$(detect_base_branch)
CHANGED_SWIFT=$(git diff --name-only "$BASE"...HEAD -- '*.swift' 2>/dev/null | grep -v 'Tests/' || true)
CHANGED_TEST_SWIFT=$(git diff --name-only "$BASE"...HEAD -- '*.swift' 2>/dev/null | grep 'Tests/' || true)
CHANGED_UI=$(echo "$CHANGED_SWIFT" | grep -E 'UI/|View|Cell|Controller' || true)

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

record() {
  local check="$1" status="$2" detail="$3"
  if [ "$status" = "pass" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [PASS] $check"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  [FAIL] $check — $detail"
  fi
  RESULTS+=("{\"check\":\"$check\",\"status\":\"$status\",\"detail\":\"$(echo "$detail" | sed 's/"/\\"/g')\"}")
}

echo "=== Palace Pre-PR Verification ==="
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
echo "Changed files: $(echo "$CHANGED_SWIFT" | wc -l | tr -d ' ') production, $(echo "$CHANGED_TEST_SWIFT" | wc -l | tr -d ' ') test"
echo ""

# 1. Build check
echo "--- Build ---"
BUILD_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM_ID" build 2>&1)
if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED\|BUILD FAILED"; then
  # `|| true` (not `|| echo "0"`): grep -c already prints "0" on no match, so
  # the fallback was producing "0\n0" and breaking the integer test below.
  SWIFT_ERRORS=$(echo "$BUILD_OUTPUT" | grep -c "error:.*\.swift:" || true)
  if [ "${SWIFT_ERRORS:-0}" -eq 0 ]; then
    record "build" "pass" "No Swift compilation errors"
  else
    record "build" "fail" "$SWIFT_ERRORS Swift compilation errors"
  fi
else
  record "build" "fail" "Build did not complete"
fi

# 2. Unit tests
echo "--- Unit Tests ---"
TEST_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM_ID" test 2>&1 || true)
TEST_PASS=$(echo "$TEST_OUTPUT" | grep -o 'Executed [0-9]* test' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
TEST_FAIL=$(echo "$TEST_OUTPUT" | grep -o 'with [0-9]* failure' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
if [ "$TEST_FAIL" -eq 0 ] && [ "$TEST_PASS" -gt 0 ]; then
  record "unit_tests" "pass" "$TEST_PASS tests, 0 failures"
else
  record "unit_tests" "fail" "$TEST_PASS tests, $TEST_FAIL failures"
fi

# 3. Test quality lint
echo "--- Test Quality Lint ---"
if [ -f scripts/lint-test-quality.py ]; then
  LINT_OUTPUT=$(python3 scripts/lint-test-quality.py 2>&1 || true)
  # Check for violations in changed test files only
  NEW_VIOLATIONS=0
  while IFS= read -r test_file; do
    [ -z "$test_file" ] && continue
    FILE_VIOLATIONS=$(echo "$LINT_OUTPUT" | grep -c "$test_file" || true)
    NEW_VIOLATIONS=$((NEW_VIOLATIONS + FILE_VIOLATIONS))
  done <<< "$CHANGED_TEST_SWIFT"
  if [ "$NEW_VIOLATIONS" -eq 0 ]; then
    record "test_quality" "pass" "0 violations in changed test files"
  else
    record "test_quality" "fail" "$NEW_VIOLATIONS violations in changed test files"
  fi
else
  record "test_quality" "pass" "Lint script not found (skipped)"
fi

# 4. Coverage floors
echo "--- Coverage Floors ---"
if [ -f scripts/enforce_coverage_floors.py ] && [ -f scripts/coverage-floors.json ]; then
  # Extract coverage from test results
  XCRESULT=$(find ~/Library/Developer/Xcode/DerivedData -name "*.xcresult" -newer /tmp/.verify-pr-start 2>/dev/null | head -1)
  if [ -n "$XCRESULT" ]; then
    COV_OUTPUT=$(python3 scripts/enforce_coverage_floors.py --baseline-only 2>&1 || true)
    if echo "$COV_OUTPUT" | grep -q "VIOLATED"; then
      record "coverage_floors" "fail" "Coverage below module thresholds"
    else
      record "coverage_floors" "pass" "All module floors met"
    fi
  else
    record "coverage_floors" "pass" "No xcresult found (skipped)"
  fi
else
  record "coverage_floors" "pass" "Coverage enforcement not configured (skipped)"
fi

# 5. Mutation testing (skip in --quick mode)
echo "--- Mutation Testing ---"
if [ "$QUICK" = "true" ]; then
  record "mutation" "pass" "Skipped (--quick mode)"
elif [ -f scripts/palace_mutate.py ] && [ -n "$CHANGED_SWIFT" ]; then
  TOTAL_KILLED=0
  TOTAL_MUTATIONS=0
  MUTATION_FAIL=false

  while IFS= read -r swift_file; do
    [ -z "$swift_file" ] && continue
    # Skip non-production files
    echo "$swift_file" | grep -qE 'Tests/|Mocks/|Config/' && continue

    # Find corresponding test directory
    MODULE=$(echo "$swift_file" | sed 's|Palace/||' | cut -d/ -f1)
    TEST_DIR="PalaceTests/$MODULE"
    [ ! -d "$TEST_DIR" ] && TEST_DIR="PalaceTests/"

    MUT_OUTPUT=$(python3 scripts/palace_mutate.py \
      --file "$swift_file" --tests "$TEST_DIR" \
      --max-mutations 10 2>&1 || true)

    KILLED=$(echo "$MUT_OUTPUT" | grep -o 'killed: [0-9]*' | grep -o '[0-9]*' || echo "0")
    TOTAL=$(echo "$MUT_OUTPUT" | grep -o 'total: [0-9]*' | grep -o '[0-9]*' || echo "0")
    TOTAL_KILLED=$((TOTAL_KILLED + KILLED))
    TOTAL_MUTATIONS=$((TOTAL_MUTATIONS + TOTAL))
  done <<< "$CHANGED_SWIFT"

  if [ "$TOTAL_MUTATIONS" -gt 0 ]; then
    KILL_RATE=$((TOTAL_KILLED * 100 / TOTAL_MUTATIONS))
    if [ "$KILL_RATE" -ge 50 ]; then
      record "mutation" "pass" "$TOTAL_KILLED/$TOTAL_MUTATIONS killed (${KILL_RATE}%)"
    else
      record "mutation" "fail" "$TOTAL_KILLED/$TOTAL_MUTATIONS killed (${KILL_RATE}%) — below 50% threshold"
      MUTATION_FAIL=true
    fi
  else
    record "mutation" "pass" "No mutations generated for changed files"
  fi
else
  record "mutation" "pass" "No production Swift files changed (skipped)"
fi

# 6. Accessibility audit (if UI files changed)
echo "--- Accessibility ---"
if [ -n "$CHANGED_UI" ]; then
  # Check for missing accessibility identifiers in changed UI files
  A11Y_ISSUES=0
  while IFS= read -r ui_file; do
    [ -z "$ui_file" ] && continue
    [ ! -f "$ui_file" ] && continue
    # Check for Button/Image without accessibilityIdentifier or accessibilityLabel
    HAS_BUTTON=$(grep -c 'UIButton\|Button(' "$ui_file" 2>/dev/null || true)
    HAS_A11Y=$(grep -c 'accessibilityIdentifier\|accessibilityLabel\|isAccessibilityElement' "$ui_file" 2>/dev/null || true)
    if [ "${HAS_BUTTON:-0}" -gt 0 ] && [ "${HAS_A11Y:-0}" -eq 0 ]; then
      A11Y_ISSUES=$((A11Y_ISSUES + 1))
    fi
  done <<< "$CHANGED_UI"
  if [ "$A11Y_ISSUES" -eq 0 ]; then
    record "accessibility" "pass" "UI files have accessibility annotations"
  else
    record "accessibility" "fail" "$A11Y_ISSUES UI files missing accessibility annotations"
  fi
else
  record "accessibility" "pass" "No UI files changed (skipped)"
fi

# 7. simdrive replay (opt-in via --simdrive). Delegates to scripts/simdrive-regress.sh
#    which enforces the two-tier gate (stateless = blocking on drift, stateful = smoke).
echo "--- simdrive Replay ---"
if [ "$SIMDRIVE" != "true" ]; then
  record "simdrive" "pass" "Skipped (pass --simdrive to enable)"
elif [ ! -x scripts/simdrive-regress.sh ]; then
  record "simdrive" "fail" "scripts/simdrive-regress.sh missing or not executable"
elif ! python3 -c 'import simdrive' >/dev/null 2>&1; then
  record "simdrive" "fail" "simdrive package not installed (pip3 install --pre simdrive)"
else
  SIMDRIVE_REPORT=$(mktemp)
  if SIMDRIVE_SIM_ID="$SIM_ID" scripts/simdrive-regress.sh --tier stateless --report "$SIMDRIVE_REPORT" >/dev/null 2>&1; then
    SD_PASS=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('pass_count', 0))" 2>/dev/null || echo 0)
    record "simdrive" "pass" "${SD_PASS} stateless journey(s) clean"
  else
    SD_FAIL=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('fail_count', 0))" 2>/dev/null || echo "?")
    SD_PASS=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('pass_count', 0))" 2>/dev/null || echo 0)
    record "simdrive" "fail" "${SD_FAIL} stateless journey(s) drifted (${SD_PASS} clean) — see ${SIMDRIVE_REPORT}"
  fi
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"

# Write JSON report if requested
if [ -n "$REPORT_FILE" ]; then
  RESULTS_JSON=$(printf '%s,' "${RESULTS[@]}" | sed 's/,$//')
  cat > "$REPORT_FILE" <<JSONEOF
{
  "branch": "$(git rev-parse --abbrev-ref HEAD)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pass_count": $PASS_COUNT,
  "fail_count": $FAIL_COUNT,
  "unit_tests": {"pass": $TEST_PASS, "fail": $TEST_FAIL},
  "checks": [$RESULTS_JSON]
}
JSONEOF
  echo "  Report written to: $REPORT_FILE"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "BLOCKED: $FAIL_COUNT check(s) failed. Fix before creating PR."
  exit 1
fi

echo ""
echo "CLEAR: All checks passed."
exit 0

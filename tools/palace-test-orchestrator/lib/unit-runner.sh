#!/bin/bash
#
# unit-runner.sh - Unit test execution for Palace iOS
#

# This library is `source`d by bin/palace-test, which sets `set -euo pipefail`.
# It must not DEPEND on inheriting that: sourced from anywhere else, an
# unprotected pipeline would report `tee`'s status and a failed test run would
# read as a pass. Setting it here makes the file self-sufficient, which was the
# real (latent) defect — the `|| exit_code=$?` capture below was already correct
# under the actual entry point.
#
# The capture must stay `|| ...` rather than a bare pipeline plus PIPESTATUS:
# `run_unit_tests` is called BARE on the `unit` path, so errexit is live inside
# the function and a bare failing pipeline kills the script AT the pipeline —
# skipping parse_xcresult and the failure report, exactly when they are needed.
set -o pipefail

run_unit_tests() {
  echo "========================================"
  echo "  Palace Unit Tests"
  echo "========================================"
  echo ""
  echo "Project:   $PROJECT_ROOT/Palace.xcodeproj"
  echo "Simulator: $SIMULATOR_ID"
  echo ""

  local result_path="$RESULTS_DIR/UnitTestResults.xcresult"
  local log_path="$RESULTS_DIR/unit-tests.log"

  # Clean previous results
  rm -rf "$result_path"

  echo "Building and running unit tests..."
  local exit_code=0

  xcodebuild test \
    -project "$PROJECT_ROOT/Palace.xcodeproj" \
    -scheme Palace \
    -destination "id=$SIMULATOR_ID" \
    -resultBundlePath "$result_path" \
    -enableCodeCoverage YES \
    -parallel-testing-enabled YES \
    -quiet \
    2>&1 | tee "$log_path" || exit_code=$?

  echo ""

  # Parse results
  if [ -d "$result_path" ]; then
    parse_xcresult "$result_path" "unit"
  else
    echo "WARNING: No xcresult bundle produced"
  fi

  if [ $exit_code -ne 0 ]; then
    echo "Unit tests FAILED (exit code: $exit_code)"
    echo "Log: $log_path"
  else
    echo "Unit tests PASSED"
  fi

  return $exit_code
}

parse_xcresult() {
  local result_path="$1"
  local test_type="$2"
  local summary_file="$RESULTS_DIR/${test_type}-summary.txt"

  echo "--- Parsing results from: $result_path ---"

  # Try xcresulttool for summary
  local summary
  summary=$(xcrun xcresulttool get test-results summary --path "$result_path" 2>/dev/null || echo "")

  if [ -n "$summary" ]; then
    echo "$summary" > "$summary_file"

    # Extract counts using python for reliable JSON parsing
    python3 -c "
import json, sys
try:
    data = json.loads('''$summary''')
    passed = data.get('passedTests', 0)
    failed = data.get('failedTests', 0)
    skipped = data.get('skippedTests', 0)
    total = passed + failed + skipped
    print(f'  Total:   {total}')
    print(f'  Passed:  {passed}')
    print(f'  Failed:  {failed}')
    print(f'  Skipped: {skipped}')
except:
    print('  (Could not parse summary JSON)')
" 2>/dev/null || echo "  (Summary parsing unavailable)"
  else
    echo "  (No summary data available)"
  fi

  echo ""
}

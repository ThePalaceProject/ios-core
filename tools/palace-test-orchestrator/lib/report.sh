#!/bin/bash
#
# report.sh - Test result formatting for Palace iOS
#

generate_report() {
  echo "========================================"
  echo "  Palace Test Report"
  echo "========================================"
  echo ""

  local has_results=false

  # Unit test results
  if [ -d "$RESULTS_DIR/UnitTestResults.xcresult" ]; then
    has_results=true
    echo "--- Unit Test Results ---"
    format_xcresult "$RESULTS_DIR/UnitTestResults.xcresult"
    echo ""
  fi

  # UI test results
  if [ -d "$RESULTS_DIR/UITestResults.xcresult" ]; then
    has_results=true
    echo "--- UI Test Results ---"
    format_xcresult "$RESULTS_DIR/UITestResults.xcresult"
    echo ""
  fi

  if [ "$has_results" = false ]; then
    echo "No test results found in: $RESULTS_DIR"
    echo ""
    echo "Run tests first:"
    echo "  palace-test unit"
    echo "  palace-test ui --plan smoke"
    echo "  palace-test all"
    return 1
  fi

  # Generate combined summary
  echo "--- Combined Summary ---"
  generate_combined_summary
  echo ""
  echo "Results stored in: $RESULTS_DIR"
}

format_xcresult() {
  local result_path="$1"

  # Try the modern xcresulttool
  local summary
  summary=$(xcrun xcresulttool get test-results summary --path "$result_path" 2>/dev/null || echo "")

  if [ -n "$summary" ]; then
    python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    passed = data.get('passedTests', 0)
    failed = data.get('failedTests', 0)
    skipped = data.get('skippedTests', 0)
    total = passed + failed + skipped
    duration = data.get('totalDuration', 0)

    status = 'PASSED' if failed == 0 else 'FAILED'
    print(f'  Status:   {status}')
    print(f'  Total:    {total}')
    print(f'  Passed:   {passed}')
    print(f'  Failed:   {failed}')
    print(f'  Skipped:  {skipped}')
    if duration:
        mins = int(duration) // 60
        secs = int(duration) % 60
        print(f'  Duration: {mins}m {secs}s')

    if failed > 0:
        print('')
        print('  Failed tests:')
        for test in data.get('failedTestSummaries', []):
            name = test.get('testName', test.get('identifier', 'unknown'))
            print(f'    - {name}')
except Exception as e:
    print(f'  (Could not parse results: {e})')
" <<< "$summary" 2>/dev/null || echo "  (Result parsing unavailable)"
  else
    echo "  (No summary available - results may be in legacy format)"
    echo "  Open in Xcode: open $result_path"
  fi
}

generate_combined_summary() {
  local total_passed=0
  local total_failed=0
  local total_skipped=0

  for result in "$RESULTS_DIR"/*.xcresult; do
    [ -d "$result" ] || continue
    local summary
    summary=$(xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null || echo "")
    if [ -n "$summary" ]; then
      local counts
      counts=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(f\"{data.get('passedTests', 0)} {data.get('failedTests', 0)} {data.get('skippedTests', 0)}\")
except:
    print('0 0 0')
" <<< "$summary" 2>/dev/null || echo "0 0 0")
      read -r p f s <<< "$counts"
      total_passed=$((total_passed + p))
      total_failed=$((total_failed + f))
      total_skipped=$((total_skipped + s))
    fi
  done

  local total=$((total_passed + total_failed + total_skipped))

  if [ $total -eq 0 ]; then
    echo "  No parseable results found"
    return
  fi

  local pass_rate=0
  if [ $total -gt 0 ]; then
    pass_rate=$(python3 -c "print(f'{$total_passed/$total*100:.1f}%')" 2>/dev/null || echo "N/A")
  fi

  echo "  Total:     $total"
  echo "  Passed:    $total_passed"
  echo "  Failed:    $total_failed"
  echo "  Skipped:   $total_skipped"
  echo "  Pass rate: $pass_rate"

  if [ $total_failed -gt 0 ]; then
    echo ""
    echo "  Overall: FAILED"
  else
    echo ""
    echo "  Overall: PASSED"
  fi
}

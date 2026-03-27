#!/bin/bash
#
# ui-runner.sh - UI test execution for Palace iOS
#

run_ui_tests() {
  local plan="${1:-smoke}"

  echo "========================================"
  echo "  Palace UI Tests (plan: $plan)"
  echo "========================================"
  echo ""
  echo "Project:   $PROJECT_ROOT/Palace.xcodeproj"
  echo "Simulator: $SIMULATOR_ID"
  echo ""

  local result_path="$RESULTS_DIR/UITestResults.xcresult"
  local log_path="$RESULTS_DIR/ui-tests.log"

  # Clean previous results
  rm -rf "$result_path"

  # Resolve test targets from plan
  local test_args=""
  test_args=$(resolve_test_plan "$plan")

  # Boot simulator if needed
  echo "Ensuring simulator is booted..."
  xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true

  # Build for testing first
  echo "Building for testing..."
  local exit_code=0

  xcodebuild build-for-testing \
    -project "$PROJECT_ROOT/Palace.xcodeproj" \
    -scheme Palace \
    -destination "id=$SIMULATOR_ID" \
    -quiet \
    2>&1 | tee "$RESULTS_DIR/ui-build.log" || {
      echo "BUILD FAILED - cannot run UI tests"
      return 1
    }

  echo "Running UI tests..."

  # shellcheck disable=SC2086
  xcodebuild test-without-building \
    -project "$PROJECT_ROOT/Palace.xcodeproj" \
    -scheme Palace \
    -destination "id=$SIMULATOR_ID" \
    -resultBundlePath "$result_path" \
    $test_args \
    2>&1 | tee "$log_path" || exit_code=$?

  echo ""

  # Parse results
  if [ -d "$result_path" ]; then
    parse_xcresult "$result_path" "ui"
  else
    echo "WARNING: No xcresult bundle produced"
  fi

  if [ $exit_code -ne 0 ]; then
    echo "UI tests FAILED (exit code: $exit_code)"
    echo "Log: $log_path"
  else
    echo "UI tests PASSED"
  fi

  return $exit_code
}

resolve_test_plan() {
  local plan="$1"

  # Read from config if available, otherwise use defaults
  case "$plan" in
    smoke)
      echo "-only-testing:PalaceUITests/SmokeTests"
      ;;
    tier1)
      echo "-only-testing:PalaceUITests/SmokeTests -only-testing:PalaceUITests/NavigationTests -only-testing:PalaceUITests/BookDetailTests"
      ;;
    full)
      # No filter = run everything
      echo ""
      ;;
    *)
      echo "Unknown test plan: $plan" >&2
      echo ""
      ;;
  esac
}

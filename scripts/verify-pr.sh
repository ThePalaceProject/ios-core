#!/bin/bash
# verify-pr.sh — Pre-PR verification: build, test, lint, coverage, governance
# Run this before creating a PR to catch issues locally.
#
# Usage:
#   scripts/verify-pr.sh              # Full check
#   scripts/verify-pr.sh --quick      # Build + lint only (no test run)
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DESTINATION='platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37'
SCHEME="Palace"
QUICK=false
FAILED=0

if [[ "${1:-}" == "--quick" ]]; then
  QUICK=true
fi

red()   { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }

check() {
  local label="$1"
  shift
  bold "[$label] Running..."
  if "$@"; then
    green "[$label] PASSED"
  else
    red "[$label] FAILED"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

cd "$REPO_ROOT"

# 1. Build
check "Build" xcodebuild -project Palace.xcodeproj -scheme "$SCHEME" \
  -destination "$DESTINATION" build -quiet

# 2. Test quality lint (new files must have 0 violations)
check "Test lint" python3 scripts/lint-test-quality.py --new-only

if [ "$QUICK" = true ]; then
  if [ "$FAILED" -gt 0 ]; then
    red "Quick check: $FAILED check(s) failed."
    exit 1
  fi
  green "Quick check passed."
  exit 0
fi

# 3. Tests
check "Unit tests" xcodebuild -project Palace.xcodeproj -scheme "$SCHEME" \
  -destination "$DESTINATION" test -quiet

# 4. Coverage floors
XCRESULT=$(find ~/Library/Developer/Xcode/DerivedData/Palace-*/Logs/Test/ \
  -name "*.xcresult" -maxdepth 1 2>/dev/null | sort -r | head -1)
if [ -n "$XCRESULT" ]; then
  check "Coverage floors" python3 scripts/enforce_coverage_floors.py "$XCRESULT"
else
  red "[Coverage floors] No xcresult found — skipping"
  FAILED=$((FAILED + 1))
fi

# 5. ForgeOS governance (non-blocking warning if no API key)
if [ -f "$SCRIPT_DIR/forgeos-gate-hook.sh" ]; then
  bold "[Governance] Checking ForgeOS gates..."
  if bash "$SCRIPT_DIR/forgeos-gate-hook.sh"; then
    green "[Governance] PASSED"
  else
    red "[Governance] FAILED (gates not promoted)"
    FAILED=$((FAILED + 1))
  fi
  echo ""
fi

# Summary
echo "================================"
if [ "$FAILED" -gt 0 ]; then
  red "$FAILED check(s) failed. Fix before creating PR."
  exit 1
fi
green "All checks passed. Ready for PR."
exit 0

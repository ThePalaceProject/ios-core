#!/usr/bin/env bash
#
# find-test-polluter.sh — diagnose test-pollution flakes by bisection.
#
# Flaky CI failures in this repo are almost always test pollution: a test that
# passes in isolation but fails in the full suite because an earlier test left
# shared mutable state dirty (`.shared` singletons, AccountsManager() background
# loadCatalogs outliving the test, layout-engine-off-main, keychain/UserDefaults
# bleed). Retry (-retry-tests-on-failure) masks these on the board; this tool
# finds the ACTUAL polluter so it can be fixed at the root.
#
# Strategy:
#   1. Run the VICTIM class alone. If it fails alone, it's a real bug, not
#      pollution — stop and say so.
#   2. If it passes alone, run each SUSPECT class immediately before the victim
#      (`-only-testing:SUSPECT -only-testing:VICTIM`, in that order). The first
#      suspect that makes the victim fail is a polluter — report it.
#
# Usage:
#   scripts/find-test-polluter.sh --victim AudiobookBookmarkBusinessLogicTests \
#       [--suspects "ClassA ClassB ClassC"] \
#       [--sim <UDID>]
#
#   --victim    Required. The XCTest class that flakes in the full suite.
#   --suspects  Space-separated candidate polluter classes. If omitted, supply
#               the classes that ran BEFORE the victim in the failing run
#               (xcodebuild runs classes alphabetically by default, so the
#               polluter is usually alphabetically-earlier and shares a
#               subsystem — auth, audiobook, registry, account).
#   --sim       Simulator UDID. Defaults to first booted, else first available
#               iPhone 16 Pro.
#
# Output: the first suspect that reproduces the victim's failure, or "no
# polluter found among suspects" (widen the suspect list).

set -uo pipefail

PROJECT="Palace.xcodeproj"
SCHEME="Palace"
VICTIM=""
SUSPECTS=""
SIM_UDID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --victim)   VICTIM="$2"; shift 2 ;;
    --suspects) SUSPECTS="$2"; shift 2 ;;
    --sim)      SIM_UDID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VICTIM" ]; then
  echo "ERROR: --victim <TestClass> is required." >&2
  exit 2
fi

if [ -z "$SIM_UDID" ]; then
  SIM_UDID=$(xcrun simctl list devices iPhone | awk '/Booted/ {print $NF; exit}' | tr -d '()')
  if [ -z "$SIM_UDID" ]; then
    SIM_UDID=$(xcrun simctl list devices available \
      | grep "iPhone 16 Pro (" | grep -oE '[0-9A-Fa-f-]{36}' | head -1)
  fi
fi
if [ -z "$SIM_UDID" ]; then
  echo "ERROR: no simulator found; pass --sim <UDID>." >&2
  exit 2
fi
echo "Simulator: $SIM_UDID"

DD=$(mktemp -d -t polluter-dd.XXXX)
trap 'rm -rf "$DD"' EXIT

# Returns 0 if the given -only-testing selectors all pass, non-zero otherwise.
run_tests() {
  local label="$1"; shift
  local args=()
  local sel
  for sel in "$@"; do args+=(-only-testing:"PalaceTests/$sel"); done
  echo "  → $label: ${args[*]}"
  xcodebuild test \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DD" \
    "${args[@]}" >/tmp/polluter-run.log 2>&1
  return $?
}

echo ""
echo "=== Step 1: does $VICTIM pass in isolation? ==="
if run_tests "isolation" "$VICTIM"; then
  echo "  PASS alone → $VICTIM is a pollution VICTIM (real bug ruled out)."
else
  echo ""
  echo "RESULT: $VICTIM FAILS in isolation — this is a REAL bug, not pollution."
  echo "        Fix the test/production code; pollution bisection does not apply."
  echo "        (tail of run log:)"
  tail -15 /tmp/polluter-run.log | sed 's/^/    /'
  exit 1
fi

if [ -z "$SUSPECTS" ]; then
  echo ""
  echo "No --suspects given. Re-run with the classes that executed BEFORE"
  echo "$VICTIM in the failing run, e.g.:"
  echo "  scripts/find-test-polluter.sh --victim $VICTIM \\"
  echo "      --suspects \"TokenRefreshAndRetryQueueTests AccountsManagerStateMachineWiringTests ...\""
  exit 0
fi

echo ""
echo "=== Step 2: bisect suspects (each run: SUSPECT then $VICTIM) ==="
FOUND=""
for s in $SUSPECTS; do
  if run_tests "pair" "$s" "$VICTIM"; then
    echo "    $s → victim still passes (not the polluter)"
  else
    echo "    $s → victim FAILS after this class ran first ***"
    FOUND="$s"
    break
  fi
done

echo ""
if [ -n "$FOUND" ]; then
  echo "RESULT: polluter is '$FOUND'."
  echo "  '$FOUND' leaves shared state dirty that breaks '$VICTIM'."
  echo "  Fix at the root: tear down the singleton / await the background task /"
  echo "  reset UserDefaults+keychain in '$FOUND' tearDown (or the SUT it drives)."
  exit 1
else
  echo "RESULT: no polluter found among the given suspects."
  echo "  Widen --suspects (the polluter may be a class you didn't list), or the"
  echo "  failure may need ≥2 classes in combination. Tail of last run:"
  tail -10 /tmp/polluter-run.log | sed 's/^/    /'
  exit 0
fi

#!/usr/bin/env bash
# test_verify_pr_baseline_compare.sh — covers `compare_against_baseline` in
# scripts/verify-pr.sh.
#
# Why this exists: "fails in isolation" is NOT evidence that a branch caused a
# failure — a deterministic pre-existing failure fails in isolation too.
# verify-pr called exactly that a "real regression" on three separate branches
# when two lint baselines went missing from develop. The fix is a merge-base
# re-run, and this test pins its three verdicts.
#
# The function shells out through "$XCODEBUILD_BIN", which is why that binary is
# a variable: here it is replaced with a stub emitting canned suite lines, so
# the verdict logic is exercised without a 15-minute build.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   — $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $label"
    echo "         expected: $expected"
    echo "         actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Source only the function under test. Running verify-pr.sh top-to-bottom would
# start a real build, so the definition is extracted instead.
FN_SRC=$(awk '/^compare_against_baseline\(\) \{/,/^\}/' "$REPO_ROOT/scripts/verify-pr.sh")
if [ -z "$FN_SRC" ]; then
  echo "FAIL — could not find compare_against_baseline() in scripts/verify-pr.sh"
  exit 1
fi
eval "$FN_SRC"

BASE="HEAD"
SIM_ID="stub-sim"
export BASE SIM_ID

make_stub() {
  # $1 = file to write, remaining args = lines the fake builder should print.
  local path="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    local line
    for line in "$@"; do
      printf 'echo "%s"\n' "$line"
    done
  } > "$path"
  chmod +x "$path"
}

STUB_DIR=$(mktemp -d -t verify-pr-baseline-test)
trap 'rm -rf "$STUB_DIR"' EXIT

echo "compare_against_baseline:"

# 1. Every named class fails at the base too → the branch is innocent.
make_stub "$STUB_DIR/all_fail" \
  "Test Suite 'AppContainerIsolationLintTests' failed" \
  "Test Suite 'TearDownRequiredLintTests' failed"
expect_eq "both classes fail at the base → all-preexisting" \
  "all-preexisting" \
  "$(XCODEBUILD_BIN="$STUB_DIR/all_fail" compare_against_baseline "AppContainerIsolationLintTests TearDownRequiredLintTests")"

# 2. A class that PASSES at the base but failed on the branch IS the branch's.
make_stub "$STUB_DIR/one_passes" \
  "Test Suite 'AppContainerIsolationLintTests' passed" \
  "Test Suite 'TearDownRequiredLintTests' failed"
expect_eq "one class passes at the base → named as new" \
  "some-new: AppContainerIsolationLintTests" \
  "$(XCODEBUILD_BIN="$STUB_DIR/one_passes" compare_against_baseline "AppContainerIsolationLintTests TearDownRequiredLintTests")"

# 3. No suite lines at all means the base build or the simulator failed. Scoring
#    off that would report an infrastructure problem as a code verdict, so the
#    function must refuse to answer rather than guess.
make_stub "$STUB_DIR/no_suites" \
  "xcodebuild: error: Could not resolve package dependencies"
expect_eq "base run produced no suites → undetermined, not a verdict" \
  "undetermined" \
  "$(XCODEBUILD_BIN="$STUB_DIR/no_suites" compare_against_baseline "AppContainerIsolationLintTests")"

# 4. A build that emits suite lines for OTHER classes but never mentions ours
#    means ours did not run; absence of a "passed" line must not read as a pass.
make_stub "$STUB_DIR/other_suites" \
  "Test Suite 'SomeUnrelatedTests' passed"
expect_eq "our class absent from the base run → not called new" \
  "all-preexisting" \
  "$(XCODEBUILD_BIN="$STUB_DIR/other_suites" compare_against_baseline "AppContainerIsolationLintTests")"

echo
echo "verdict wiring in verify-pr.sh:"

# The three verdicts must each be handled by the caller. A verdict the case
# statement does not name would silently fall through to the default branch and
# report the wrong thing.
for verdict in "all-preexisting" "some-new:\*" "undetermined"; do
  if grep -q "$verdict)" "$REPO_ROOT/scripts/verify-pr.sh"; then
    echo "  ok   — caller handles '$verdict'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — caller does not handle '$verdict'"
    FAIL=$((FAIL + 1))
  fi
done

# The default arm must no longer assert a regression it has not established.
if grep -q "NOT established as this branch" "$REPO_ROOT/scripts/verify-pr.sh"; then
  echo "  ok   — default arm reports isolation failure without claiming it is the branch's"
  PASS=$((PASS + 1))
else
  echo "  FAIL — default arm still over-claims attribution"
  FAIL=$((FAIL + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

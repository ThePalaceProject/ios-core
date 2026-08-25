#!/usr/bin/env bash
# test_verify_pr_baseline_compare.sh — covers the merge-base verdict in
# scripts/verify-pr.sh.
#
# Why this exists: "fails in isolation" is NOT evidence that a branch caused a
# failure — a deterministic pre-existing failure fails in isolation too.
# verify-pr called exactly that a "real regression" on three separate branches
# when two lint baselines went missing from develop. The fix re-runs the failing
# classes at the merge-base; this test pins the verdict it draws from that run.
#
# `baseline_verdict_from_output` is deliberately separate from the function that
# builds the base tree, so the decision can be tested with no git, no simulator
# and no build. That also keeps this runnable on the ubuntu tooling runner,
# where the macOS-only half could never execute.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_PR="$REPO_ROOT/scripts/verify-pr.sh"
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

expect_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  ok   — $label"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL — $label"
      echo "         expected to contain: $needle"
      echo "         actual:              $haystack"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

# Source only the pure verdict function. Running verify-pr.sh top-to-bottom
# would start a real build.
FN_SRC=$(awk '/^baseline_verdict_from_output\(\) \{/,/^\}/' "$VERIFY_PR")
if [ -z "$FN_SRC" ]; then
  echo "FAIL — could not find baseline_verdict_from_output() in scripts/verify-pr.sh"
  exit 1
fi
eval "$FN_SRC"

echo "baseline_verdict_from_output:"

# 1. Every named class fails at the base too → the branch is innocent, and the
#    gate must PASS rather than blame it.
expect_eq "both classes fail at the base → all-preexisting" \
  "all-preexisting" \
  "$(baseline_verdict_from_output \
      "Test Suite 'AppContainerIsolationLintTests' failed
Test Suite 'TearDownRequiredLintTests' failed" \
      "AppContainerIsolationLintTests TearDownRequiredLintTests")"

# 2. A class that PASSES at the base but failed on the branch IS the branch's,
#    and must be named so the reader knows which one to open.
expect_eq "one class passes at the base → named as new" \
  "some-new: AppContainerIsolationLintTests" \
  "$(baseline_verdict_from_output \
      "Test Suite 'AppContainerIsolationLintTests' passed
Test Suite 'TearDownRequiredLintTests' failed" \
      "AppContainerIsolationLintTests TearDownRequiredLintTests")"

# 3. No suite lines at all means the base build or the simulator failed. Scoring
#    off that would report an infrastructure problem as a code verdict, so the
#    function must refuse to answer rather than guess. This is the arm that
#    keeps the fix from replacing one over-claim with another.
expect_eq "base run produced no suites → undetermined, not a verdict" \
  "undetermined" \
  "$(baseline_verdict_from_output \
      "xcodebuild: error: Could not resolve package dependencies" \
      "AppContainerIsolationLintTests")"

# 4. A base run that emits suite lines for OTHER classes but never mentions ours
#    means ours did not run there. Absence of a "passed" line must not be read
#    as a pass, which would mislabel a pre-existing failure as newly introduced.
expect_eq "our class absent from the base run → not called new" \
  "all-preexisting" \
  "$(baseline_verdict_from_output \
      "Test Suite 'SomeUnrelatedTests' passed" \
      "AppContainerIsolationLintTests")"

# 5. Several new classes are all named, not just the first.
expect_eq "every newly-broken class is named" \
  "some-new: AlphaTests BetaTests" \
  "$(baseline_verdict_from_output \
      "Test Suite 'AlphaTests' passed
Test Suite 'BetaTests' passed
Test Suite 'GammaTests' failed" \
      "AlphaTests BetaTests GammaTests")"

echo
echo "orchestration:"

# The expensive half must exist and must delegate to the pure half, or the two
# could drift apart and this file would be testing something the gate no longer
# runs.
ORCH_SRC=$(awk '/^compare_against_baseline\(\) \{/,/^\}/' "$VERIFY_PR")
expect_contains "compare_against_baseline delegates to the tested verdict" \
  "baseline_verdict_from_output" \
  "$ORCH_SRC"

# mktemp's `-t <prefix>` form is BSD-only; GNU rejects it and returns nothing,
# which would leave the worktree path as "/src". An explicit template works on
# both. This bit the tooling runner once already.
expect_contains "temp dir uses a portable explicit template" \
  "XXXXXX" \
  "$ORCH_SRC"

if echo "$ORCH_SRC" | grep -q 'mktemp -d -t '; then
  echo "  FAIL — compare_against_baseline still uses the BSD-only 'mktemp -d -t <prefix>' form"
  FAIL=$((FAIL + 1))
else
  echo "  ok   — no BSD-only mktemp form"
  PASS=$((PASS + 1))
fi

echo
echo "verdict wiring in verify-pr.sh:"

# Each verdict must be handled by the caller. One the case statement does not
# name would fall through to the default arm and report the wrong thing.
for verdict in "all-preexisting" "some-new:\*" "undetermined"; do
  if grep -q "$verdict)" "$VERIFY_PR"; then
    echo "  ok   — caller handles '$verdict'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — caller does not handle '$verdict'"
    FAIL=$((FAIL + 1))
  fi
done

# The default arm must no longer assert a regression it has not established.
if grep -q "NOT established as this branch" "$VERIFY_PR"; then
  echo "  ok   — default arm reports isolation failure without claiming it is the branch's"
  PASS=$((PASS + 1))
else
  echo "  FAIL — default arm still over-claims attribution"
  FAIL=$((FAIL + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

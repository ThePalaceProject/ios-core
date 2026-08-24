#!/usr/bin/env bash
# test_ratchet_aggregation_behaviour.sh
#
# Drives verify-pr.sh's decomposition-ratchet aggregation BEHAVIOURALLY and
# asserts the outcome it records.
#
# WHY THIS REPLACES A GREP. The previous version of this check asserted the
# aggregation by grepping its source text. A reviewer walked through it FOUR
# ways, each leaving every asserted string intact while making the branch
# unreachable:
#   A  pipe the ratchet through `head`, so RATCHET_RC reads head's status
#   B  rename the flag at the test site  ($RATCHET_FAILED -> $RATCHET_FAILED_X)
#   C  reset the flag after the loop
#   D  rename the missing-list at the test site
# A is this repo's own `never-read-exit-code-after-pipe`; D reinstates exactly
# the defect the commit fixed. A grep over source cannot see any of them,
# because the strings are all still there.
#
# So: lift the block, stub `record` and the ratchet scripts, run it, and assert
# what it RECORDS. Costs ~30 lines and no extraction of production code.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VPR="${VPR_OVERRIDE:-$REPO/scripts/verify-pr.sh}"
RATCHETS="check-appcontainer-locator-count.sh check-godclass-loc-freeze.sh check-shared-read-count.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

# The lifted range stops on the `pass` record, which is inside the final else,
# so close the if the extraction cut in half. Asserted below rather than assumed:
# a block that fails to parse would record nothing and every case would fail with
# "<nothing>", which is a legible failure rather than a silent pass.
BLOCK="$(sed -n '/^  RATCHET_FAILED=""/,/decomposition_ratchets" "pass"/p' "$VPR")
  fi"
# NOT `[ -n "$BLOCK" ]`: the closing `fi` is appended unconditionally, so BLOCK
# is never empty and that check could never fire. Assert the thing that actually
# distinguishes a successful lift — the loop the block is named for.
echo "$BLOCK" | grep -q 'for ratchet in check-appcontainer' \
  || fail "lifted block does not contain the ratchet loop — the extraction range has drifted"
echo "$BLOCK" | bash -n - 2>/dev/null || fail "lifted block does not parse — the extraction range has drifted"

# Runs the lifted block against stubbed ratchets and echoes the recorded outcome.
# $1 = exit code for each ratchet, space separated; "-" means the script is ABSENT.
run_case() {
  local spec="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts"
  local i=0
  for r in $RATCHETS; do
    i=$((i + 1))
    local code
    code="$(echo "$spec" | cut -d' ' -f$i)"
    [ "$code" = "-" ] && continue
    printf '#!/bin/sh\necho "%s output"\nexit %s\n' "$r" "$code" > "$tmp/scripts/$r"
    chmod +x "$tmp/scripts/$r"
  done
  {
    echo 'record() { echo "RECORD|$1|$2|$3"; }'
    echo "$BLOCK"
  } > "$tmp/run.sh"
  ( cd "$tmp" && bash run.sh 2>/dev/null | grep '^RECORD|' | head -1 )
  rm -rf "$tmp"
}

outcome() { echo "$1" | cut -d'|' -f3; }

echo "== ratchet aggregation: behaviour, not source text =="

R="$(run_case "0 0 0")"
[ "$(outcome "$R")" = "pass" ] || fail "all ratchets clean should record pass, got: ${R:-<nothing>}"
pass "three clean ratchets -> pass"

R="$(run_case "0 1 0")"
[ "$(outcome "$R")" = "fail" ] \
  || fail "a FAILING ratchet must record fail, got: ${R:-<nothing>} (attacks A/B/C turn this into pass)"
pass "a failing ratchet -> fail"

R="$(run_case "1 1 1")"
[ "$(outcome "$R")" = "fail" ] || fail "all ratchets failing should record fail, got: ${R:-<nothing>}"
pass "all failing -> fail"

R="$(run_case "0 - 0")"
[ "$(outcome "$R")" = "skip" ] \
  || fail "a MISSING ratchet must record skip, not pass, got: ${R:-<nothing>} (attack D turns this into pass)"
pass "a missing ratchet -> skip, never pass"

R="$(run_case "- - -")"
[ "$(outcome "$R")" = "skip" ] || fail "all ratchets missing should record skip, got: ${R:-<nothing>}"
pass "all missing -> skip"

R="$(run_case "1 - 0")"
[ "$(outcome "$R")" = "fail" ] \
  || fail "a real failure must outrank a missing script, got: ${R:-<nothing>}"
pass "failure outranks missing"

echo "== ratchet aggregation behaves =="

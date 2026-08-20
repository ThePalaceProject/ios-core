#!/usr/bin/env bash
# test_run_chaos_pass_cause_wiring.sh — prove run-chaos-pass.sh actually CALLS
# the cause-discipline gate, and that it calls it with an interface the gate
# accepts.
#
# Per CLAUDE.md gate rule #4, a detector's wiring gets its own end-to-end test,
# including a CLEAN-DIFF PASS assertion. A gate invoked with a path that does
# not exist, or with a flag it rejects, is silently inert — indistinguishable
# from passing. This caught a real one: the guard was first wired as
# "$SCRIPT_DIR/check-..." in a script that never defines SCRIPT_DIR, so it
# expanded to "/check-..." , failed the -f test, and no-op'd.
#
# We do not boot a simulator. We exercise the gate invocation the runner
# performs, against the same REPO_ROOT resolution the runner uses.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-chaos-pass.sh"
GATE="$REPO_ROOT/scripts/check-chaos-cause-discipline.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok — $*"; }

HEADER='ID,Title,Area,Test ID,Classification,Severity,Verified,Baseline Behavior,Candidate Behavior,Suspected Cause,Cause Status,Steps,Screenshot Baseline,Screenshot Candidate,Notes,PR,Jira Ticket'

# --- 1. the runner references the gate, via a variable it actually defines ---
grep -q 'check-chaos-cause-discipline.py' "$RUNNER" \
  || fail "run-chaos-pass.sh does not reference the cause gate at all"

CAUSE_LINE="$(grep -n 'CAUSE_CHECK=' "$RUNNER" | head -1)"
[[ -n "$CAUSE_LINE" ]] || fail "no CAUSE_CHECK assignment in the runner"

# Extract the variable the path is built from and assert the runner defines it.
VAR="$(sed -n 's/.*CAUSE_CHECK="\$\([A-Z_]*\).*/\1/p' <<<"$CAUSE_LINE")"
[[ -n "$VAR" ]] || fail "could not parse the base variable out of: $CAUSE_LINE"
grep -qE "^${VAR}=" "$RUNNER" \
  || fail "CAUSE_CHECK is built from \$${VAR}, which run-chaos-pass.sh never defines — the gate would silently no-op"
pass "runner builds the gate path from \$${VAR}, which it defines"

# --- 2. CLEAN PASS: valid findings must be accepted (the wiring assertion) ---
CLEAN="$TMP/clean.csv"
{
  echo "$HEADER"
  echo 'F-001,Reader stays blank after a tap burst,chaos-rapid-tap,cold-launch,chaos,minor,true,,,"possibly a cancelled in-flight load",unverified,,,,,,'
} > "$CLEAN"
if ! python3 "$GATE" --strict "$CLEAN" >/dev/null 2>&1; then
  python3 "$GATE" --strict "$CLEAN"
  fail "gate REJECTED valid findings — the runner would fail every clean chaos pass"
fi
pass "clean findings pass --strict (gate is not inert-by-rejection)"

# --- 3. REAL violation is caught with the runner's exact invocation ----------
DIRTY="$TMP/dirty.csv"
{
  echo "$HEADER"
  echo 'F-001,Rapid-tap Borrow issues duplicate fulfillment,chaos-rapid-tap,cold-launch,chaos,minor,true,,,"two tasks in flight",,,,,,,'
} > "$DIRTY"
python3 "$GATE" --strict "$DIRTY" >/dev/null 2>&1
[[ $? -eq 1 ]] || fail "gate did NOT flag a finding whose cause has no status"
pass "unstated cause status is caught (exit 1)"

# --- 4. legacy header is rejected under --strict (new runs must emit cols) ---
LEGACY="$TMP/legacy.csv"
{
  echo 'ID,Title,Area,Test ID,Classification,Severity,Verified,Baseline Behavior,Candidate Behavior,Steps,Screenshot Baseline,Screenshot Candidate,Notes,PR,Jira Ticket'
  echo 'F-001,something happened,chaos-rapid-tap,cold-launch,chaos,minor,true,,,,,,,,'
} > "$LEGACY"
python3 "$GATE" --strict "$LEGACY" >/dev/null 2>&1
[[ $? -eq 1 ]] || fail "--strict accepted a legacy header; new runs could drop the columns"
python3 "$GATE" "$LEGACY" >/dev/null 2>&1
[[ $? -eq 0 ]] || fail "non-strict rejected a legacy header; historical corpora would hard-fail"
pass "legacy header: fails --strict, passes without it"

# --- 5. the runner uses --strict and a distinct exit code -------------------
grep -q -- '--strict "\$FINDINGS_CSV"' "$RUNNER" \
  || fail "runner does not pass --strict with the findings CSV"
grep -q 'exit 5' "$RUNNER" \
  || fail "runner has no distinct exit code for a cause-discipline failure"
pass "runner invokes --strict on \$FINDINGS_CSV and exits 5 on failure"

# --- 6. AN ABSENT GATE MUST SHOUT, NOT SKIP --------------------------------
#
# A gate guarded by a file-existence test makes itself optional in exactly the
# case where you most need it: when the file is missing or non-executable, the
# campaign proceeds and prints "run complete". That is indistinguishable from
# passing, and it is how a gate propagates to nothing. Review of #1401 showed
# all three of this repo's new gates had the shape; these assertions pin the
# fix so it cannot regress.
for pair in \
  "$RUNNER|CHAOS_SKIP_CAUSE_CHECK" \
  "$REPO_ROOT/scripts/regression-area-worker.sh|REGRESSION_SKIP_PREFLIGHT" \
  "$REPO_ROOT/scripts/regression-chaos-fan.sh|REGRESSION_SKIP_PREFLIGHT"
do
  f="${pair%%|*}"; bypass="${pair##*|}"
  [[ -f "$f" ]] || continue
  # The gate's own guard must not be a bare file/exec test that skips silently.
  if grep -qE 'if \[\[ +-f +"\$CAUSE_CHECK" +\]\]' "$f"; then
    fail "$(basename "$f"): gate guarded by a bare -f test — absent file skips it silently"
  fi
  if grep -qE '&& +-x +"\$PREFLIGHT" +\]\]' "$f"; then
    fail "$(basename "$f"): gate guarded by -x — a non-executable or missing preflight skips it silently"
  fi
  # And the ONLY way past a missing gate must be the named bypass.
  grep -q "$bypass" "$f" \
    || fail "$(basename "$f"): no named bypass ($bypass); absence must be either a hard failure or an explicit opt-out"
done
pass "an absent or non-executable gate fails hard; the named bypass is the only way past"

echo "ALL WIRING CHECKS PASSED"

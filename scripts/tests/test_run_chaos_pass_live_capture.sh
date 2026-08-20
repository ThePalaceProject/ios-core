#!/usr/bin/env bash
# test_run_chaos_pass_live_capture.sh — a chaos pass must capture its own log
# stream LIVE, for the duration of the run.
#
# WHY THIS EXISTS (rc-3.3.0-20260820). Findings quoted log lines at INFO level.
# Info records are almost never written to the simulator's on-disk store — a
# measured 78 persisted against 4,472 live in one window, ~98% absent — and the
# buffer holding them does not survive shutdown. The campaign took no live
# capture, so hours later the cited evidence could not be checked at all. Three
# people then spent an hour disagreeing about what a zero meant, and one
# (me) broadcast a corpus-integrity finding that was purely an artifact of
# reading a store that never had the data.
#
# The evidence was not lost. It was never captured. That is a missing STEP in
# the run, not a limitation of any analysis tool, which is why the fix lands
# here and not in the log-recovery script.
#
# A pass that produced findings it cannot evidence is the same class as a pass
# that never drove the simulator: it reports a result it did not earn. Both
# refuse, with distinct exit codes.
#
# Seam: CHAOS_LOG_BIN stands in for `xcrun` so this runs with no simulator.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-chaos-pass.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok — $*"; }

FAKE_UDID="DEADBEEF-0000-0000-0000-00000000FEED"

# A stub agent that "drives the sim" by creating a session dir, so the NO-DRIVE
# guard is satisfied and we are testing the capture guard in isolation.
mk_agent() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
mkdir -p "$2/session-\$\$"
echo 'stub agent summary'
EOF
  chmod +x "$1"
}

# A stub for \`xcrun\`. Emits lines for "simctl spawn ... log stream" so the
# capture file fills; passes everything else through harmlessly.
mk_log_bin() {   # $1=path  $2=emit? (yes|no)
  cat > "$1" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "stream" ] && IS_STREAM=1; done
if [ "\${IS_STREAM:-0}" = "1" ]; then
  echo "\$@" > "$TMP/log_invocation.txt"
  if [ "$2" = "yes" ]; then
    while true; do
      echo "2026-08-20 11:11:11.000 I  Palace[1] [com.apple.network] sample info line"
      sleep 0.05
    done
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

run_pass() {   # $1=rundir $2=agent $3=logbin
  env CHAOS_RUNS_ROOT="$1" \
      CHAOS_SESSIONS_DIR="$4" \
      CHAOS_CLAUDE_BIN="$2" \
      CHAOS_LOG_BIN="$3" \
      bash "$RUNNER" --udid "$FAKE_UDID" --seed cold-launch \
        --max-paths 3 --max-minutes 2 2>&1
}

# --- 1. the runner must reference a live capture at all --------------------
grep -q "log stream" "$RUNNER" \
  || fail "run-chaos-pass.sh never starts a live log stream — an info-level quote in any finding it produces is unverifiable the moment the run ends"
pass "runner starts a live log stream"

# --- 2. the capture must request info level -------------------------------
# `log stream --level debug` includes info; without a level flag the stream is
# default-level only and the exact records this fix exists for are excluded.
# Match the EXECUTED command, not prose. The NO CAPTURE banner also prints a
# suggested `log stream --level debug` for the operator, so a loose grep passes
# even when the real invocation has lost its level flag — that mutant survived
# once here and this is the fix.
grep -qE '"\$CHAOS_LOG_BIN" simctl spawn "\$UDID" log stream --level (debug|info)' "$RUNNER" \
  || fail "the live-capture INVOCATION does not request info/debug level — it would miss exactly the records this guard exists to preserve (note: the banner's example does not count)"
pass "the capture invocation requests info/debug level"

# --- 3. CLEAN PATH: capture produces output -> pass ------------------------
S1="$TMP/s1"; mkdir -p "$S1"
A1="$TMP/agent1.sh"; mk_agent "$A1" "$S1"
L1="$TMP/logbin-yes.sh"; mk_log_bin "$L1" yes
R1="$TMP/runs1"
OUT1="$(run_pass "$R1" "$A1" "$L1" "$S1")"; RC1=$?
[[ $RC1 -eq 0 ]] || fail "a pass WITH a live capture must succeed, got $RC1:
$OUT1"
CAP="$(find "$R1" -name 'live.log' | head -1)"
[[ -n "$CAP" ]] || fail "no live.log written into the run dir"
[[ -s "$CAP" ]] || fail "live.log is empty on the clean path"
pass "clean path: live.log written and non-empty, pass exits 0"

# --- 4. the capture lands in the RUN DIR, next to the findings -------------
[[ "$(dirname "$CAP")" == "$(dirname "$(find "$R1" -name 'findings.csv' | head -1)")" ]] \
  || fail "live.log is not co-located with findings.csv; evidence must travel with the run"
pass "capture is co-located with the findings it evidences"

# --- 5. REAL VIOLATION: capture produced nothing -> refuse -----------------
S2="$TMP/s2"; mkdir -p "$S2"
A2="$TMP/agent2.sh"; mk_agent "$A2" "$S2"
L2="$TMP/logbin-no.sh"; mk_log_bin "$L2" no
R2="$TMP/runs2"
OUT2="$(run_pass "$R2" "$A2" "$L2" "$S2")"; RC2=$?
[[ $RC2 -ne 0 ]] || fail "a pass whose live capture produced NOTHING exited 0 — it would report findings nobody can ever evidence:
$OUT2"
grep -qi "NO CAPTURE" <<<"$OUT2" \
  || fail "refusal does not name the cause (expected a NO CAPTURE banner):
$OUT2"
pass "empty capture is refused, with a named cause"

# --- 6. distinct exit code from the NO-DRIVE guard ------------------------
grep -q "exit 6" "$RUNNER" \
  || fail "no distinct exit code for a capture failure; it would be indistinguishable from NO DRIVE (4) or cause-discipline (5)"
pass "capture failure has its own exit code"

echo "ALL LIVE-CAPTURE CHECKS PASSED"

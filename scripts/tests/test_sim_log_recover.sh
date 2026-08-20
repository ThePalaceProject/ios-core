#!/usr/bin/env bash
# test_sim_log_recover.sh
#
# Fixture test for scripts/sim-log-recover.sh.
#
# Pins the guard that distinguishes the two ways the script produces no output.
# Before the guard, both looked identical to the caller — and worse, `set -e`
# plus a non-matching `grep` turned a legitimate "0 matches" into a non-zero
# exit, so a REAL NEGATIVE was indistinguishable from a broken invocation.
#
# That distinction is the whole value of the tool: it exists to settle "did the
# app actually issue that request", and an operator error that silently reads as
# "no, it didn't" would retract true findings. An untested guard is
# indistinguishable from no guard, so all three branches are pinned here.
set -eu

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/sim-log-recover.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

UDID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
DEV="$TMP/devices/$UDID/data/var/db"
mkdir -p "$DEV/diagnostics/Persist" "$DEV/uuidtext"
: > "$DEV/diagnostics/Persist/0000000000000001.tracev3"

# Stub `log`: ignores its arguments and prints whatever fixture it is pointed at.
# The real binary is never invoked, so the test needs no simulator.
cat > "$TMP/log-stub" <<'STUB'
#!/usr/bin/env bash
cat "$SIM_TEST_FIXTURE"
STUB
chmod +x "$TMP/log-stub"

# A window WITH data: the column header `log show` always emits, plus two lines.
cat > "$TMP/with-data.txt" <<'DATA'
Timestamp               Ty Process[PID:TID]
2026-08-20 11:11:21.135 Df Palace[1:2] [com.apple.CFNetwork:Default] Task <AAAA>.<1> is for <org.thepalaceproject.palace>.<dl>
2026-08-20 11:11:24.415 Df Palace[1:2] [com.apple.CFNetwork:Default] Task <BBBB>.<2> is for <org.thepalaceproject.palace>.<dl>
DATA

# A window with NO data: the header alone, which is what an uncovered window
# actually produces. If the script counted raw lines it would see 1 and call
# this "covered" — that is the bug this fixture guards.
cat > "$TMP/header-only.txt" <<'DATA'
Timestamp               Ty Process[PID:TID]
DATA

export SIM_DEVICES_ROOT="$TMP/devices"
export SIM_LOG_BIN="$TMP/log-stub"

run() { set +e; OUT=$("$SCRIPT" "$@" 2>"$TMP/err"); RC=$?; set -e; }
fail() { echo "FAIL: $1"; echo "--- stdout ---"; echo "${OUT:-}"; echo "--- stderr ---"; cat "$TMP/err"; exit 1; }

# 1. Covered window, pattern matches -> hits on stdout, exit 0.
export SIM_TEST_FIXTURE="$TMP/with-data.txt"
run "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00' 'is for <org.thepalaceproject.palace>'
[ "$RC" -eq 0 ] || fail "matching pattern should exit 0, got $RC"
[ "$(printf '%s\n' "$OUT" | grep -c 'is for')" -eq 2 ] || fail "expected 2 matching lines"

# 2. Covered window, pattern matches nothing -> REAL NEGATIVE. Exit 0, empty
#    stdout, and stderr must say the window had data. This is the case that
#    `set -e` + grep used to turn into a spurious failure.
run "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00' 'downloadTaskWithRequest'
[ "$RC" -eq 0 ] || fail "real negative must exit 0, got $RC"
[ -z "$OUT" ] || fail "real negative must print nothing on stdout"
grep -q '0 matches' "$TMP/err" || fail "stderr must report 0 matches"
grep -q 'real negative' "$TMP/err" || fail "stderr must name this a real negative"

# 3. Window with no data at all -> NOT COVERED. Must NOT read as a real
#    negative; distinct exit code so a caller can branch on it.
export SIM_TEST_FIXTURE="$TMP/header-only.txt"
run "$UDID" '2026-08-20 15:11:00' '2026-08-20 15:12:00' 'is for <org.thepalaceproject.palace>'
[ "$RC" -eq 3 ] || fail "uncovered window must exit 3, got $RC"
grep -q 'WINDOW NOT COVERED' "$TMP/err" || fail "stderr must say WINDOW NOT COVERED"
grep -q 'LOCAL' "$TMP/err" || fail "stderr must warn about LOCAL vs UTC"
grep -q 'says NOTHING' "$TMP/err" || fail "stderr must refuse to imply a negative result"

# 4. The two empty cases must be distinguishable, which is the entire point.
[ "$RC" -ne 0 ] || fail "uncovered and real-negative must not share an exit code"

# 5. Missing store -> exit 1, distinct from both empty cases.
run "DEADBEEF-0000-0000-0000-000000000000" '2026-08-20 11:11:00' '2026-08-20 11:12:00'
[ "$RC" -eq 1 ] || fail "missing store must exit 1, got $RC"

# 6. No pattern -> stream the window, header stripped.
export SIM_TEST_FIXTURE="$TMP/with-data.txt"
run "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00'
[ "$RC" -eq 0 ] || fail "unfiltered read should exit 0, got $RC"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 2 ] || fail "expected 2 data lines, header stripped"

echo "PASS: test_sim_log_recover.sh (6 cases)"

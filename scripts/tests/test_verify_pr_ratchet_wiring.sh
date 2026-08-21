#!/usr/bin/env bash
# test_verify_pr_ratchet_wiring.sh
#
# Pins the WIRING of four detectors into scripts/verify-pr.sh:
#
#   check-appcontainer-locator-count.sh   (whole-tree, baseline)
#   check-godclass-loc-freeze.sh          (whole-tree, baseline)
#   check-shared-read-count.sh            (whole-tree, baseline)
#   check-completion-isolation.py         (diff-scoped, file paths)
#
# WHY THIS TEST EXISTS. All four shipped with baselines and pytests and were
# invoked by NOTHING — a 2026-08-20 audit found them reachable from no hook, no
# workflow, and no script. Their pytests passed the whole time, because a
# detector's own unit tests say nothing about whether anything calls it. This
# test asserts the call site, not the detector.
#
# It also pins the INTERFACE each one is called with, which is the failure mode
# CLAUDE.md rule 4 names: a scan-only detector invoked with `--diff` is invisible
# to a fixture that only ever stages a violation. So every case below asserts the
# CLEAN path exits 0 as well as the violating path exiting non-zero.

set -eu

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX GIT_EXEC_PATH || true

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
VERIFY="$REPO_ROOT/scripts/verify-pr.sh"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "  ok — $*"; }

[ -f "$VERIFY" ] || fail "verify-pr.sh not at $VERIFY"

# ---------------------------------------------------------------------------
# 1. The wiring exists at all.
# ---------------------------------------------------------------------------
echo "1. detectors referenced by verify-pr.sh"
for d in check-appcontainer-locator-count.sh \
         check-godclass-loc-freeze.sh \
         check-shared-read-count.sh \
         check-completion-isolation.py; do
  grep -qF "$d" "$VERIFY" || fail "$d is not referenced by verify-pr.sh (orphaned again)"
  pass "$d is wired"
done

# The record() keys must exist too — a detector can be mentioned in a comment
# while its block is unreachable. Ratchet detectors trip on comment mentions
# (memory `ratchet-detectors-count-comment-mentions`), so assert the real keys.
for key in '"decomposition_ratchets"' '"completion_isolation"'; do
  grep -qF "record $key" "$VERIFY" || fail "no record() call for $key in verify-pr.sh"
  pass "record() key $key present"
done

# ---------------------------------------------------------------------------
# 2. CLEAN PATH — the three whole-tree ratchets must pass on the real tree with
#    the exact interface verify-pr.sh uses (no arguments). If one of these ever
#    needs a flag, this catches the mismatch before it lands as a false block.
# ---------------------------------------------------------------------------
echo "2. clean path — whole-tree ratchets, invoked with no arguments"
for r in check-appcontainer-locator-count.sh \
         check-godclass-loc-freeze.sh \
         check-shared-read-count.sh; do
  [ -f "$REPO_ROOT/scripts/$r" ] || fail "$r missing"
  if ( cd "$REPO_ROOT" && bash "scripts/$r" >/dev/null 2>&1 ); then
    pass "$r exits 0 at baseline"
  else
    fail "$r exits non-zero on the current tree — verify-pr.sh would block every PR. Either the tree regressed past its baseline or the baseline needs re-committing."
  fi
done

# ---------------------------------------------------------------------------
# 3. completion-isolation is DIFF-SCOPED. Two assertions, and the clean one
#    matters more: verify-pr.sh passes file paths, so a build that only ever
#    checked the violating case would not notice the detector rejecting the
#    argument form entirely.
# ---------------------------------------------------------------------------
echo "3. completion-isolation — file-path interface, both directions"
CI="$REPO_ROOT/scripts/check-completion-isolation.py"
[ -f "$CI" ] || fail "check-completion-isolation.py missing"

TMPDIR=$(mktemp -d -t ci-wiring.XXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# 3a. CLEAN — a bare Task inside a @MainActor type inherits main isolation, so
#     calling the completion from it is correct and must NOT be flagged.
cat > "$TMPDIR/Clean.swift" <<'EOF'
import Foundation

@MainActor
final class CleanExample {
    func load(completion: @escaping (String?) -> Void) {
        Task {
            let value = await fetch()
            completion(value)
        }
    }

    private func fetch() async -> String? { nil }
}
EOF

if python3 "$CI" "$TMPDIR/Clean.swift" >/dev/null 2>&1; then
  pass "clean file (Task inside @MainActor type) exits 0"
else
  fail "clean file was flagged — false positive; verify-pr.sh would block correct code"
fi

# 3b. VIOLATION — the same shape in a plain class inherits nothing, lands on the
#     cooperative executor, and traps a @MainActor caller's closure (PP-4955).
cat > "$TMPDIR/Violation.swift" <<'EOF'
import Foundation

final class ViolationExample {
    func load(completion: @escaping (String?) -> Void) {
        Task {
            let value = await fetch()
            completion(value)
        }
    }

    private func fetch() async -> String? { nil }
}
EOF

if python3 "$CI" "$TMPDIR/Violation.swift" >/dev/null 2>&1; then
  fail "off-main completion in a plain class was NOT flagged — the detector is wired but toothless"
else
  pass "off-main completion in a plain class exits non-zero"
fi

# 3c. Mixed batch — verify-pr.sh passes ALL changed Swift files at once. One bad
#     file among good ones must still fail the batch.
if python3 "$CI" "$TMPDIR/Clean.swift" "$TMPDIR/Violation.swift" >/dev/null 2>&1; then
  fail "mixed batch passed — a violation is masked when batched with clean files"
else
  pass "mixed batch exits non-zero"
fi

# ---------------------------------------------------------------------------
# 4. verify-pr.sh still parses.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# The aggregation must ACT on the ratchets' exit codes.
#
# A reviewer changed the comparison to `-eq 999` — making it impossible for any
# ratchet failure to be recorded — and every assertion above still passed. They
# all grep the call site or run the detectors standalone, which proves the
# detectors work and says nothing about whether verify-pr.sh believes them. That
# is the same "the tests pass" != "the gate runs" split this file exists to
# close, one level up.
#
# HONESTY ABOUT WHAT THIS IS: a STRUCTURAL assertion, not a behavioural one. It
# kills the demonstrated mutant but cannot prove the recorded outcome end to end,
# because the ratchet block is inline in a script whose other legs build the app.
# Making it genuinely behavioural means extracting the loop into its own script
# a stub ratchet can be pointed at; that is deferred, and named here so the limit
# is visible rather than assumed away.
echo "5. ratchet failures are acted on, not just collected"

AGG="$(sed -n '/for ratchet in check-appcontainer/,/decomposition_ratchets" "pass"/p' "$REPO_ROOT/scripts/verify-pr.sh")"
[ -n "$AGG" ] || fail "could not locate the ratchet aggregation block"

echo "$AGG" | grep -qE 'RATCHET_RC" -ne 0' \
  || fail "aggregation does not compare the ratchet exit code against 0 — a failing ratchet may be unrecordable"
pass "compares each ratchet's exit code against 0"

echo "$AGG" | grep -q 'RATCHET_FAILED="yes"' \
  || fail "a non-zero ratchet does not set the failure flag"
pass "a non-zero ratchet sets the failure flag"

echo "$AGG" | grep -q 'record "decomposition_ratchets" "fail"' \
  || fail "the failure flag is never recorded as a fail"
pass "the failure flag is recorded as a fail"

# Assert the ASSIGNMENT, not a mention. Grepping for the bare variable name
# passes on a block that merely reads it — the same defect as a detector that
# counts a comment mentioning the thing it is supposed to find.
echo "$AGG" | grep -qE 'RATCHET_MISSING="\$RATCHET_MISSING' \
  || fail "a missing ratchet is never accumulated — deleting a ratchet would read as green"
pass "a missing ratchet is accumulated"

echo "$AGG" | grep -qE 'record "decomposition_ratchets" "skip"' \
  || fail "missing ratchets are not surfaced as a skip — the report would claim they passed"
pass "missing ratchets are reported as skip, not pass"

echo "4. verify-pr.sh syntax"
bash -n "$VERIFY" || fail "verify-pr.sh does not parse"
pass "bash -n clean"

echo
echo "PASS: all four detectors are wired, and both the clean and violating paths behave."

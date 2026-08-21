#!/usr/bin/env bash
# test_doc_reference_gate_wiring.sh
#
# Pins the WIRING of check-doc-references-resolve.py into CI.
#
# WHY THIS EXISTS. Three decomposition ratchets in this repo shipped with a
# baseline and a passing pytest while being invoked by NOTHING — a detector's own
# unit tests are completely silent about whether anything calls it, so "the tests
# pass" and "the gate runs" are independent facts. A detector nobody invokes is
# indistinguishable from a detector that always passes.
#
# It also pins the INTERFACE, which is the other half of CLAUDE.md rule 4: a
# scan-only detector invoked with `--diff` exits non-zero on argument parsing and
# a fixture that only ever stages a violation never notices, because it is
# looking for a non-zero exit and it gets one. So this asserts the CLEAN path
# passes as well as the violation path failing.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/tooling-checks.yml"
DETECTOR="$REPO/scripts/check-doc-references-resolve.py"
BASELINE="$REPO/scripts/doc-references-baseline.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

echo "== doc-reference gate wiring =="

[ -f "$DETECTOR" ] || fail "detector missing: $DETECTOR"
pass "detector exists"

[ -f "$BASELINE" ] || fail "baseline missing: $BASELINE — the gate cannot distinguish new from pre-existing"
pass "baseline exists"

# 1. CI actually invokes it.
grep -q 'check-doc-references-resolve.py' "$WORKFLOW" \
  || fail "tooling-checks.yml never invokes the detector — it would be inert in CI"
pass "invoked by tooling-checks.yml"

# 2. Invoked with an interface it ACCEPTS. The detector is whole-tree; being
#    handed --diff or a file list would make it exit on argparse, which reads as
#    a blocking failure for the wrong reason.
INVOCATION="$(grep -o 'python3 scripts/check-doc-references-resolve\.py[^|&;]*' "$WORKFLOW" | head -1)"
[ -n "$INVOCATION" ] || fail "could not locate the invocation line"
case "$INVOCATION" in
  *--diff*|*--files*|*--staged*) fail "invoked with a diff-scoped flag it does not accept: $INVOCATION" ;;
esac
pass "invoked whole-tree (no diff-scoped flags)"

# 3. THE CLEAN PATH PASSES. This is the assertion the ratchet fixtures omitted.
if ! python3 "$DETECTOR" --root "$REPO" >/dev/null 2>&1; then
  python3 "$DETECTOR" --root "$REPO" || true
  fail "detector does not pass on the current tree — a gate that blocks a clean repo gets disabled"
fi
pass "clean tree passes (exit 0)"

# 4. A NEW dangling reference blocks. Uses a temp doc so the repo is untouched;
#    the detector enumerates via `git ls-files`, so it must be staged to be seen.
TMPDOC="docs/__wiring_probe__.md"
cleanup() { git -C "$REPO" rm -q --cached "$TMPDOC" >/dev/null 2>&1 || true; rm -f "$REPO/$TMPDOC"; }
trap cleanup EXIT
printf 'Probe: `scripts/__no_such_script_wiring_probe__.py`\n' > "$REPO/$TMPDOC"
git -C "$REPO" add -N "$TMPDOC" >/dev/null 2>&1 || fail "could not stage probe doc"

if python3 "$DETECTOR" --root "$REPO" >/dev/null 2>&1; then
  fail "a new dangling reference did NOT block — the gate is decorative"
fi
pass "new dangling reference blocks (exit 1)"

cleanup
trap - EXIT

# 5. And the tree is clean again afterwards.
python3 "$DETECTOR" --root "$REPO" >/dev/null 2>&1 \
  || fail "detector still failing after probe cleanup — the probe leaked"
pass "clean again after cleanup"

echo "== all doc-reference gate wiring assertions passed =="

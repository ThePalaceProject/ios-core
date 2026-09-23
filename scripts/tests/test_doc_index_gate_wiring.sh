#!/usr/bin/env bash
# test_doc_index_gate_wiring.sh
#
# Pins the WIRING of check-doc-index-complete.py into CI.
#
# WHY THIS EXISTS. Same reason as its sibling for the reference gate: a
# detector's own unit tests say nothing about whether anything calls it, and
# three ratchets in this repo shipped with green pytests while being invoked by
# nothing. That failure is especially apt here — this gate's whole subject is
# artifacts that exist but are unreachable, so an unwired copy of it would be
# the very defect it detects.
#
# Asserts the clean path as well as the blocking path, because a scan-only
# detector handed a diff-scoped flag exits non-zero on argparse and a fixture
# looking only for "non-zero" cannot tell that apart from working.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/tooling-checks.yml"
DETECTOR="$REPO/scripts/check-doc-index-complete.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

BEFORE="$(git -C "$REPO" status --porcelain)"

echo "== doc-index gate wiring =="

[ -f "$DETECTOR" ] || fail "detector missing: $DETECTOR"
pass "detector exists"

# 1. CI actually invokes it.
grep -q 'check-doc-index-complete.py' "$WORKFLOW" \
  || fail "tooling-checks.yml never invokes the detector — it would be inert in CI"
pass "invoked by tooling-checks.yml"

# 2. Invoked with an interface it accepts (whole-tree, no diff-scoped flags).
INVOCATION="$(grep -o 'python3 scripts/check-doc-index-complete\.py[^|&;]*' "$WORKFLOW" | head -1)"
[ -n "$INVOCATION" ] || fail "could not locate the invocation line"
case "$INVOCATION" in
  *--diff*|*--files*|*--staged*) fail "invoked with a diff-scoped flag it does not accept: $INVOCATION" ;;
esac
pass "invoked whole-tree (no diff-scoped flags)"

# 3. THE CLEAN PATH PASSES on the real tree.
if ! python3 "$DETECTOR" --root "$REPO" >/dev/null 2>&1; then
  python3 "$DETECTOR" --root "$REPO" || true
  fail "detector does not pass on the current tree — a gate that blocks a clean repo gets disabled"
fi
pass "clean tree passes (exit 0)"

# 4. An unlisted doc blocks — in a SCRATCH repo. Never stage a probe into the
#    author's real tree: a hard kill between the stage and the trap leaks it
#    into someone's commit.
SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

mkdir -p "$SCRATCH/docs/architecture"
printf '# Index\n- [a](./a.md)\n' > "$SCRATCH/docs/architecture/README.md"
printf '# A\n' > "$SCRATCH/docs/architecture/a.md"
git -C "$SCRATCH" init -q
git -C "$SCRATCH" add -A >/dev/null 2>&1

python3 "$DETECTOR" --root "$SCRATCH" >/dev/null 2>&1 \
  || fail "a complete scratch index did not pass — the fixture is wrong, not the tree"
pass "scratch fixture: complete index passes"

printf '# Orphan\n' > "$SCRATCH/docs/architecture/orphan.md"
git -C "$SCRATCH" add -A >/dev/null 2>&1
if python3 "$DETECTOR" --root "$SCRATCH" >/dev/null 2>&1; then
  fail "an unlisted doc did NOT block — the gate is decorative"
fi
pass "scratch fixture: unlisted doc blocks (exit 1)"

# 5. And this repository was never touched. Compare against the start snapshot,
#    not against "clean" — the author's tree is legitimately dirty mid-work.
AFTER="$(git -C "$REPO" status --porcelain)"
[ "$AFTER" = "$BEFORE" ] \
  || fail "the wiring test changed the real worktree — that is the defect it exists to avoid"
pass "real worktree unchanged by this test"

cleanup
trap - EXIT

echo "== all doc-index gate wiring assertions passed =="

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

# Snapshot before anything runs, so assertion 5 measures THIS test's effect
# rather than whatever the author happened to have in flight.
BEFORE="$(git -C "$REPO" status --porcelain)"

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

# 4. A NEW dangling reference blocks — in a SCRATCH repo, never this one.
#
#    The previous version staged a probe file into the author's real working
#    tree and index and removed it with a trap. That is the
#    reviewer-mutation-corrupts-the-authors-worktree shape, and it is worse
#    coming from a test whose whole subject is gates that damage things
#    silently: a hard kill between the stage and the trap leaks a staged file
#    into someone's commit. The detector already takes --root, so the fixture is
#    a throwaway `git init` with two files and nothing of this repo is touched.
SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

mkdir -p "$SCRATCH/scripts" "$SCRATCH/docs"
printf '{"known_dangling": []}\n' > "$SCRATCH/scripts/doc-references-baseline.json"
printf 'Run `scripts/real.sh`.\n' > "$SCRATCH/docs/clean.md"
printf '#!/bin/sh\n' > "$SCRATCH/scripts/real.sh"
git -C "$SCRATCH" init -q
git -C "$SCRATCH" add -A >/dev/null 2>&1

python3 "$DETECTOR" --root "$SCRATCH" >/dev/null 2>&1 \
  || fail "a clean scratch repo did not pass — the fixture is wrong, not the tree"
pass "scratch fixture: clean repo passes"

printf 'Probe: `scripts/__no_such_script__.py`\n' > "$SCRATCH/docs/probe.md"
git -C "$SCRATCH" add -A >/dev/null 2>&1
if python3 "$DETECTOR" --root "$SCRATCH" >/dev/null 2>&1; then
  fail "a new dangling reference did NOT block — the gate is decorative"
fi
pass "scratch fixture: new dangling reference blocks (exit 1)"

# 5. And this repository was never touched by any of the above.
#
#    Compare against a snapshot taken at start-up, NOT against "clean". The
#    author's tree is legitimately dirty while they are working, and a test that
#    demands a pristine checkout fails for the wrong reason and gets disabled —
#    which is how a gate stops gating. What matters is the DELTA.
AFTER="$(git -C "$REPO" status --porcelain)"
[ "$AFTER" = "$BEFORE" ] \
  || fail "the wiring test changed the real worktree — that is the defect it exists to avoid"
pass "real worktree unchanged by this test"

cleanup
trap - EXIT

echo "== all doc-reference gate wiring assertions passed =="

#!/bin/bash
# test_chaos_replay.sh — verify scripts/chaos-replay.sh corpus validation (--check).
#
# --check stages + validates the curated chaos corpus without booting a sim or
# importing simdrive, so it runs on a bare CI runner. These cases pin the
# contract the chaos-replay-on-pr.yml gate depends on:
#   - a well-formed entry (top-level <name>.yaml + <name>/recording.yaml) passes
#   - an entry missing its recording.yaml payload BLOCKS (exit 1) — the exact
#     half-corpus shape that would otherwise silently replay nothing
#   - an empty corpus is a clean no-op (exit 0)
#   - a missing corpus dir is a config error (exit 2)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$DIR/../chaos-replay.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Isolate staging so the test never touches the real ~/.simdrive/recordings.
export SIMDRIVE_HOME="$TMP/simdrive-home"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# 1 — well-formed entry: top-level spec + recording payload -> exit 0
GOOD="$TMP/good"; mkdir -p "$GOOD/flow-a/snapshots"
echo "scenario: {id: flow-a}" > "$GOOD/flow-a.yaml"
echo "steps: []" > "$GOOD/flow-a/recording.yaml"
"$SUT" --check --corpus "$GOOD" >/dev/null 2>&1
[ $? -eq 0 ] && ok "well-formed corpus passes --check" || bad "well-formed corpus should pass"

# 2 — half-corpus: spec present but NO recording.yaml payload -> BLOCK (exit 1)
BAD="$TMP/bad"; mkdir -p "$BAD"
echo "scenario: {id: flow-b}" > "$BAD/flow-b.yaml"
"$SUT" --check --corpus "$BAD" >/dev/null 2>&1
[ $? -eq 1 ] && ok "entry missing recording.yaml blocks" || bad "missing payload not blocked"

# 3 — empty corpus dir -> clean no-op (exit 0)
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
"$SUT" --check --corpus "$EMPTY" >/dev/null 2>&1
[ $? -eq 0 ] && ok "empty corpus is a clean no-op" || bad "empty corpus should be clean"

# 4 — missing corpus dir -> config error (exit 2)
"$SUT" --check --corpus "$TMP/does-not-exist" >/dev/null 2>&1
[ $? -eq 2 ] && ok "missing corpus dir is a config error" || bad "missing dir should exit 2"

# 5 — real repo corpus is well-formed (guards the committed .simdrive/replays/chaos)
REPO_CORPUS="$DIR/../../.simdrive/replays/chaos"
if [ -d "$REPO_CORPUS" ]; then
  "$SUT" --check --corpus "$REPO_CORPUS" >/dev/null 2>&1
  [ $? -eq 0 ] && ok "committed chaos corpus is well-formed" || bad "committed corpus failed --check"
fi

echo "chaos-replay --check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

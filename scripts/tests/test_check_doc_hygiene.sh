#!/bin/bash
# test_check_doc_hygiene.sh — verify the doc-hygiene gate.
# Asserts BOTH directions: process/generated docs block, legit docs pass (a gate
# that only ever sees a violation can hide a wiring bug that blocks everything).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DET="$DIR/../check-doc-hygiene.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
blocks(){ "$DET" --files "$1" >/dev/null 2>&1; [ $? -eq 1 ]; }
passes(){ "$DET" --files "$1" >/dev/null 2>&1; [ $? -eq 0 ]; }

# --- DENIED: process / generated doc artifacts -> BLOCK ---
for f in \
  ".forgeos/swarms/s1/transcripts/A.md" \
  ".forgeos/swarms/s1/HANDOFF.md" \
  ".forgeos/swarms/s1/plan.md" \
  ".forgeos/swarms/s1/manifest.yaml" \
  ".forgeos/swarms/s1/architect-review.md" \
  ".forgeos/swarms/s1/contracts/E-Thing.md" \
  "docs/architecture/.arch/facts.json" \
  "docs/architecture/architecture.html" ; do
  blocks "$f" && ok "blocked: $f" || bad "NOT blocked: $f"
done

# --- LEGIT: docs that explain the code's what/why -> PASS ---
for f in \
  "docs/architecture/state-management-doctrine.md" \
  "docs/architecture/release-merge-policy.md" \
  "CLAUDE.md" \
  "README.md" \
  "Palace/MyBooks/README.md" \
  "Palace/MyBooks/BorrowReducerCore.swift" \
  ".forgeos/reviewer-refs/architect-swift-canon.md" \
  ".forgeos/committed-signing-allowlist.txt" ; do
  passes "$f" && ok "passed: $f" || bad "FALSE-POSITIVE (blocked): $f"
done

# --- allowlist override: a denied path listed in the allowlist -> PASS ---
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
echo ".forgeos/swarms/keepme/contracts/X.md  # intentionally kept" > "$TMP"
if DOC_HYGIENE_ALLOWLIST="$TMP" "$DET" --files ".forgeos/swarms/keepme/contracts/X.md" >/dev/null 2>&1; then
  ok "allowlist override honored"
else
  bad "allowlist override NOT honored"
fi

# --- clean multi-file diff (all legit) -> PASS (wiring can't be block-everything) ---
if "$DET" --files "docs/architecture/state-management-doctrine.md" "Palace/x/README.md" "CLAUDE.md" >/dev/null 2>&1; then
  ok "clean multi-file diff passes"
else
  bad "clean multi-file diff wrongly blocked"
fi

echo ""
echo "doc-hygiene gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

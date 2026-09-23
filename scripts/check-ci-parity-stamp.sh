#!/usr/bin/env bash
#
# check-ci-parity-stamp.sh — systemic gate: a push/PR that changes production
# code must first pass the local CI-parity run (scripts/ci-parity-local.sh) on
# THIS EXACT commit. Because GitHub's macos-15 runner (~3 vCPU) surfaces
# starvation/off-main flakes that a fast dev Mac hides, "green on my machine"
# via a plain subset run is NOT enough — the parity run is the honest gate.
#
# Contract:
#   - ci-parity-local.sh writes `.git/ci-parity-pass.sha` = the HEAD it verified.
#   - This script blocks (exit 1) when the push range touches production Swift
#     (Palace/**/*.swift, excluding tests) AND that stamp does not match HEAD.
#   - Test-only / docs / scripts / config changes do not require a parity run
#     (they cannot introduce the runtime flake class this gate protects).
#
# Bypass (logged): SKIP_CI_PARITY=1 git push ...
#   Legitimate uses: a docs/test-only follow-up on top of an already-verified
#   commit, or an emergency hotfix you will parity-verify out-of-band. Overuse
#   defeats the gate — the whole point is a trustworthy board (CLAUDE.md
#   "green-board contract").
#
# Base ref for the diff: origin/develop (the PR merge target) by default;
# override with CI_PARITY_BASE.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ "${SKIP_CI_PARITY:-0}" = "1" ]; then
    echo "[ci-parity-gate] SKIP_CI_PARITY=1 — bypassing (logged). Re-enable by unsetting it." >&2
    exit 0
fi

BASE="${CI_PARITY_BASE:-origin/develop}"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"

# Determine the changed files vs the merge base. Fall back to the last commit
# if the base ref is unavailable (e.g. detached/no remote).
if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
    RANGE="$MERGE_BASE..HEAD"
else
    RANGE="HEAD~1..HEAD"
fi

# Production Swift = Palace/**/*.swift, excluding the test target.
PROD_CHANGED="$(git diff --name-only "$RANGE" 2>/dev/null \
    | grep -E '^Palace/.*\.swift$' \
    | grep -vE '^PalaceTests/|Tests?\.swift$' \
    || true)"

if [ -z "$PROD_CHANGED" ]; then
    echo "[ci-parity-gate] No production Swift changed vs $BASE — parity run not required." >&2
    exit 0
fi

STAMP_FILE="$(git rev-parse --git-dir)/ci-parity-pass.sha"
STAMP="$(cat "$STAMP_FILE" 2>/dev/null || echo "")"

if [ "$STAMP" = "$HEAD_SHA" ]; then
    echo "[ci-parity-gate] ✅ CI-parity verified for $(git rev-parse --short HEAD)." >&2
    exit 0
fi

cat >&2 <<EOF
[ci-parity-gate] 🔴 BLOCKED — production code changed but this commit has not
                 passed the local CI-parity run.

  HEAD:            $HEAD_SHA
  parity-verified: ${STAMP:-<none>}

  GitHub's 3-vCPU runner surfaces starvation/off-main flakes a fast dev Mac
  hides. Run the full-suite parity check on THIS commit, then push:

      scripts/ci-parity-local.sh

  It stamps the commit on pass; this gate then lets the push through.

  Bypass (only for docs/test-only follow-ups or an out-of-band-verified
  hotfix):  SKIP_CI_PARITY=1 git push ...
EOF
exit 1

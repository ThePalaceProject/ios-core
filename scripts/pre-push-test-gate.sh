#!/usr/bin/env bash
# pre-push-test-gate.sh — git pre-push hook enforcing "attested done" on push.
#
# PHASE 4 (attested-done enforcement flip). This hook USED to derive the
# targeted XCTest classes for the changed Swift files and run a `-only-testing:`
# xcodebuild spot-check inline. That spot-check is now REPLACED by a ledger read:
# a push that changes ANY `.swift` file must carry a green, tip-bound
# `verify:T1` (or higher: T2/T3) attestation in `.heka/telemetry.jsonl`,
# produced by `harness verify --tier T1` (Phase 3). The signed attestation IS
# the proof the full tier ran — reading it is faster and more honest than a
# partial re-run, and it composes with the same trust root as the review gate.
#
# WHY the swap: a `-only-testing:<DerivedClass>` spot-check is exactly the scoped
# subset CLAUDE.md forbids reporting as a pass (incident PP-4542) — it silently
# skips the MetaTests isolation-lint classes and runs a sliver of CI. A green
# `verify:T1` means the whole Phase-1 tier ran green at THIS tip. This mirrors
# how `pre-push-critical-path-review.sh` reads green `review:*` verdicts at the
# tip rather than trusting prose.
#
# BEHAVIOUR
#   · Zero `.swift` in the diff  → tooling-only exemption (unchanged): the iOS
#     verify requirement does NOT apply; run scripts/tests/ pytest if present.
#   · >=1 `.swift` in the diff   → require a green non-dirty `verify:T{1,2,3}`
#     bound to the pushed tip. ABSENT / STALE (not at tip) / DIRTY-attestation
#     ⇒ BLOCK (exit 2) with the exact remedy command.
#
# ENFORCEMENT MODE — `HEKA_ATTESTED_DONE` (off | warn | block); default `warn`.
#   warn  : missing/stale/dirty attestation prints the remedy but ALLOWS the
#           push (exit 0). This is the default so the un-reviewed hook does not
#           instantly hard-block every push on the machine it lands on.
#   block : the enforcement flip — missing/stale/dirty ⇒ exit 2 (push blocked).
#           Set `export HEKA_ATTESTED_DONE=block` to go live (Maurice's call
#           after review).
#   off   : the verify requirement is disabled entirely (LFS + exemptions only).
#
# Bypass (emergency, leaves the same audit trail as before):
#   SKIP_PRE_PUSH_TESTS=1 git push ...
#
# The harness's STANZA_THRESHOLD_LOC bypass for commit-msg is independent.

set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Chain to git-lfs pre-push (the stock hook this one replaces).
# ---------------------------------------------------------------------------
# `git push` calls .git/hooks/pre-push with the stock LFS handler in the
# default install. Installing this gate WITHOUT chaining would silently
# stop LFS object verification. We invoke `git lfs pre-push` first with
# the same args + stdin git passed us; if LFS rejects (missing objects),
# the push is correctly blocked before we even spend time on the gate.
#
# `git lfs pre-push` reads from stdin (ref list). We capture stdin into a
# temp file so we can replay it both to LFS and to ourselves.
STDIN_CAPTURE="$(mktemp -t pre-push-stdin.XXXXXX)"
trap 'rm -f "$STDIN_CAPTURE"' EXIT
cat > "$STDIN_CAPTURE"

if command -v git-lfs >/dev/null 2>&1; then
  if ! git lfs pre-push "$@" < "$STDIN_CAPTURE"; then
    echo "[pre-push-test-gate] git-lfs pre-push failed — push blocked by LFS layer (before verify gate)." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Emergency bypass for the verify-gate layer (LFS already ran above)
# ---------------------------------------------------------------------------
if [[ "${SKIP_PRE_PUSH_TESTS:-0}" == "1" ]]; then
  echo "[pre-push-test-gate] SKIP_PRE_PUSH_TESTS=1 — bypassing the attested-done gate." >&2
  echo "[pre-push-test-gate] (Push proceeds. Re-enable by unsetting the env var.)" >&2
  exit 0
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_DIR" || exit 0

# ---------------------------------------------------------------------------
# 1a. Compute the push range (for the .swift exemption decision only)
# ---------------------------------------------------------------------------
# Prefer `@{u}..HEAD` (commits ahead of upstream). Fall back to the merge-base
# with the integration branch on a first push / detached HEAD.
RANGE=""
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  RANGE='@{u}..HEAD'
else
  # No upstream tracking yet (first push of a branch). Diff against the
  # merge-base with the integration branch the branch was actually cut from.
  # Campaign/tooling branches are cut from `develop`, not `main`; diffing a
  # fresh develop-cut branch against origin/main surfaces develop's ENTIRE
  # delta-from-main (hundreds of Palace/*.swift it never touched) — a false
  # "changed Swift" set. Prefer origin/develop, then origin/main, using the
  # merge-base so only commits unique to this branch count.
  if git rev-parse --verify origin/develop >/dev/null 2>&1; then
    _BASE="$(git merge-base origin/develop HEAD 2>/dev/null || echo origin/develop)"
    RANGE="${_BASE}..HEAD"
  elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    _BASE="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
    RANGE="${_BASE}..HEAD"
  else
    RANGE='HEAD~1..HEAD'
  fi
fi

# ---------------------------------------------------------------------------
# 1b. Zero-.swift exemption — scripts/.simdrive/docs-only tooling pushes.
# ---------------------------------------------------------------------------
# A push whose diff contains ZERO files ending in `.swift` cannot affect the
# iOS build/test outcome, so the verify:T* requirement does NOT apply — running
# (or requiring) an iOS tier for it is pure drag and a structural false-positive
# (a tooling worktree that was never `carthage bootstrap`-ed cannot even build
# a tier). For these diffs we SKIP the verify requirement and instead run the
# repo's scripts/tests/ python suite (the relevant gate for scripts/.simdrive
# changes) when present.
#
# HARD CONSTRAINT: any diff with >=1 `.swift` file falls through to the verify
# requirement below, unchanged. The `.swift` detection is robust — ANY path
# ending in `.swift` (anywhere in the tree) counts as not-exempt.
ALL_CHANGED="$(git diff --name-only "$RANGE" 2>/dev/null || true)"
SWIFT_CHANGED="$(printf '%s\n' "$ALL_CHANGED" | grep -E '\.swift$' || true)"

if [[ -z "$SWIFT_CHANGED" ]]; then
  echo "[pre-push-test-gate] Zero .swift files in $RANGE — tooling-only push (scripts/.simdrive/docs)." >&2
  echo "[pre-push-test-gate] attested-done verify:T* requirement N/A (a non-Swift diff cannot affect the iOS tier)." >&2

  # Run the scripts/tests/ python suite instead, if present. Failure here DOES
  # block the push — it's the correct gate for tooling changes.
  if [[ -d "$REPO_DIR/scripts/tests" ]] && command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import pytest' >/dev/null 2>&1; then
    echo "[pre-push-test-gate] Running scripts/tests/ suite (python -m pytest)…" >&2
    # Scrub the git hook env (GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/…) before pytest —
    # inherited, it makes the tests' throwaway-repo git commands operate on the real
    # repo being pushed and corrupt the branch.
    if (cd "$REPO_DIR" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_EXEC_PATH python3 -m pytest scripts/tests -q) >/tmp/pre-push-scripts-tests.log 2>&1; then
      echo "[pre-push-test-gate] scripts/tests PASS — tooling suite green." >&2
      exit 0
    else
      rc=$?
      echo "" >&2
      echo "[pre-push-test-gate] scripts/tests FAIL (exit $rc) — push blocked." >&2
      echo "[pre-push-test-gate] Last 40 lines of /tmp/pre-push-scripts-tests.log:" >&2
      tail -n 40 /tmp/pre-push-scripts-tests.log >&2 || true
      echo "[pre-push-test-gate] To bypass: SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
      exit 1
    fi
  fi

  echo "[pre-push-test-gate] No runnable scripts/tests/ suite (pytest absent or dir missing) — allowing push." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. >=1 .swift changed → require a green tip-bound verify:T{1,2,3} attestation.
# ---------------------------------------------------------------------------
MODE="${HEKA_ATTESTED_DONE:-warn}"
case "$MODE" in
  off)
    echo "[pre-push-test-gate] HEKA_ATTESTED_DONE=off — verify requirement disabled; allowing push." >&2
    exit 0 ;;
  warn|block) ;;
  *) echo "[pre-push-test-gate] HEKA_ATTESTED_DONE='$MODE' unrecognised — treating as warn." >&2; MODE="warn" ;;
esac

LEDGER="$REPO_DIR/.heka/telemetry.jsonl"
if [[ ! -f "$LEDGER" ]]; then
  echo "[pre-push-test-gate] No .heka/telemetry.jsonl — repo is not heka-governed; verify requirement N/A. Allowing push." >&2
  exit 0
fi

# The tip whose attestation we require. Mirror pre-push-critical-path-review.sh:
# evaluate HEAD (the ref a plain `git push` advances). The ledger records the
# SHORT sha, so compare robustly (full == short, prefix either way).
TIP="$(git rev-parse HEAD 2>/dev/null)"
TIP_SHORT="$(git rev-parse --short HEAD 2>/dev/null)"

# Ledger read: latest verify:* event per gate, keyed to the tip. Emits one of:
#   ok:<gate>            a green, non-dirty verify:T* bound to the tip
#   stale:<gate>@<sha>   a green verify exists but at a DIFFERENT sha (tip moved)
#   dirty:<gate>         a verify at the tip but recorded on a DIRTY tree (unbound)
#   none                 no verify:* attestation at all
VERIFY_STATUS="$(python3 - "$LEDGER" "$TIP" "$TIP_SHORT" <<'PY' 2>/dev/null || echo none
import json, sys
path, tip, tip_short = sys.argv[1], sys.argv[2], sys.argv[3]

def at_tip(sha):
    return bool(sha) and (sha == tip or sha == tip_short
                          or tip.startswith(sha) or sha.startswith(tip_short))

# Track the LATEST event per verify:* gate (append-only ledger, in order).
latest = {}
for line in open(path):
    try:
        e = json.loads(line)
    except Exception:
        continue
    g = str(e.get("gate", ""))
    if not g.startswith("verify:"):
        continue
    latest[g] = e

ok = stale = dirty = None
for g, e in latest.items():
    if not e.get("passed"):
        continue
    sha = str(e.get("sha", ""))
    if at_tip(sha):
        if e.get("dirty"):
            dirty = dirty or g
        else:
            ok = ok or g
    else:
        stale = stale or (g, sha)

if ok:
    print("ok:" + ok)
elif dirty:
    print("dirty:" + dirty)
elif stale:
    print("stale:" + stale[0] + "@" + stale[1])
else:
    print("none")
PY
)"

if [[ "$VERIFY_STATUS" == ok:* ]]; then
  echo "[pre-push-test-gate] PASS — green ${VERIFY_STATUS#ok:} attestation bound to ${TIP_SHORT}. Allowing push." >&2
  exit 0
fi

# Not satisfied — build an actionable remedy keyed to WHY.
case "$VERIFY_STATUS" in
  stale:*) _why="a verify attestation exists but at a DIFFERENT commit (${VERIFY_STATUS#stale:}); the tip moved since you verified, so it no longer binds ${TIP_SHORT}." ;;
  dirty:*) _why="the ${VERIFY_STATUS#dirty:} attestation was recorded on a DIRTY tree, so it does not bind the committed tip." ;;
  *)       _why="no verify:T* attestation is recorded for ${TIP_SHORT}." ;;
esac

_msg=$(cat <<EOF

[pre-push-test-gate] attested-done gate: this push changes .swift file(s), but
  ${_why}
  Remedy: run \`harness verify --tier T1\` (or --tier T2), then push.
  (\`harness verify\` runs the Phase-1 tier and records a signed, tip-bound
   verify:T1 that this gate reads. Commit first — an attestation binds the
   committed HEAD.)
  Emergency bypass (leaves an audit trail): SKIP_PRE_PUSH_TESTS=1 git push ...
EOF
)

if [[ "$MODE" == "block" ]]; then
  echo "$_msg" >&2
  echo "[pre-push-test-gate] BLOCK (HEKA_ATTESTED_DONE=block) — push refused." >&2
  exit 2
fi

echo "$_msg" >&2
echo "[pre-push-test-gate] WARN (HEKA_ATTESTED_DONE=warn) — allowing push; set HEKA_ATTESTED_DONE=block to enforce." >&2
exit 0

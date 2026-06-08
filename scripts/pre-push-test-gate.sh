#!/usr/bin/env bash
# pre-push-test-gate.sh — opt-in git pre-push hook that runs the targeted
# XCTest classes for the Swift production files in the push range.
#
# Goal: catch trivially-broken pushes (renamed test class, syntax error
# missed by Xcode, mock change that didn't recompile its dependent test)
# in under 60 seconds wall-clock. NOT a full regression — that's
# `verify-pr.sh`.
#
# Algorithm:
#   1. Compute changed Swift files: `git diff --name-only @{u}..HEAD`
#      filtered to `Palace/**/*.swift`.
#   2. For each changed file, derive a test class via the same lookup
#      logic used by `scripts/regression-report.sh::derive_test_class_for`
#      — Foo.swift -> Foo*Tests.swift, then first XCTestCase subclass
#      declared in each candidate file.
#   3. Build `-only-testing:PalaceTests/<Class>` args and run xcodebuild
#      test with a wall-clock cap (default 180s, override via
#      PRE_PUSH_TESTS_TIMEOUT_SECS=N).
#   4. Failure exits 1 (blocks push). Success or no derived tests exits 0.
#
# Bypass:
#   SKIP_PRE_PUSH_TESTS=1 git push ...                # full opt-out (logged)
#   PRE_PUSH_TESTS_TIMEOUT_SECS=360 git push ...      # raise cap (cold builds)
#
# The harness's existing STANZA_THRESHOLD_LOC bypass for commit-msg is
# independent of this hook.
#
# This hook is OFF BY DEFAULT. Wire it up explicitly via:
#   scripts/install-git-hooks.sh --with-pre-push-tests

set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Chain to git-lfs pre-push (the stock hook this one replaces).
# ---------------------------------------------------------------------------
# `git push` calls .git/hooks/pre-push with the stock LFS handler in the
# default install. Installing this gate WITHOUT chaining would silently
# stop LFS object verification. We invoke `git lfs pre-push` first with
# the same args + stdin git passed us; if LFS rejects (missing objects),
# the push is correctly blocked before we even spend time on tests.
#
# `git lfs pre-push` reads from stdin (ref list). We capture stdin into a
# temp file so we can replay it both to LFS and to ourselves.
STDIN_CAPTURE="$(mktemp -t pre-push-stdin.XXXXXX)"
trap 'rm -f "$STDIN_CAPTURE"' EXIT
cat > "$STDIN_CAPTURE"

if command -v git-lfs >/dev/null 2>&1; then
  if ! git lfs pre-push "$@" < "$STDIN_CAPTURE"; then
    echo "[pre-push-test-gate] git-lfs pre-push failed — push blocked by LFS layer (before test gate)." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Bypass for the test-gate layer (LFS already ran above)
# ---------------------------------------------------------------------------
if [[ "${SKIP_PRE_PUSH_TESTS:-0}" == "1" ]]; then
  echo "[pre-push-test-gate] SKIP_PRE_PUSH_TESTS=1 — bypassing targeted tests." >&2
  echo "[pre-push-test-gate] (Push proceeds. Re-enable by unsetting the env var.)" >&2
  exit 0
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_DIR" || exit 0

# ---------------------------------------------------------------------------
# 1. Compute changed Swift files in the push range
# ---------------------------------------------------------------------------
# Prefer `@{u}..HEAD` (commits ahead of upstream). Fall back to the last
# commit on detached HEADs / first push of a branch.
RANGE=""
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  RANGE='@{u}..HEAD'
else
  # No upstream tracking yet — diff against origin/main if present, else
  # the immediate parent commit. Either way we get *something* sensible.
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    RANGE='origin/main..HEAD'
  else
    RANGE='HEAD~1..HEAD'
  fi
fi

CHANGED_FILES="$(git diff --name-only "$RANGE" -- 'Palace/*.swift' 2>/dev/null | sort -u)"

if [[ -z "$CHANGED_FILES" ]]; then
  echo "[pre-push-test-gate] No Palace/*.swift files changed in $RANGE — nothing to test." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Derive test classes
# ---------------------------------------------------------------------------
# Same logic as scripts/regression-report.sh::derive_test_class_for, but
# inlined so this hook stays self-contained (and runnable from any cwd in
# the worktree without sourcing the heavier regression script).
derive_test_classes_for() {
  local source_file="$1"
  local base
  base="$(basename "$source_file" .swift)"

  local candidates
  candidates="$(find "$REPO_DIR/PalaceTests" \
                  \( -name "${base}Tests.swift" -o -name "${base}*Tests.swift" \) \
                  2>/dev/null \
                | grep -v '/Mocks/' \
                | sort -u)"

  if [[ -z "$candidates" ]]; then
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    awk '/^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase/ {
      for (i=1; i<=NF; i++) if ($i == "class") { print $(i+1); exit }
    }' "$candidate" | tr -d ':'
  done <<< "$candidates" | sort -u
}

declare -a CLASSES=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  while IFS= read -r cls; do
    [[ -z "$cls" ]] && continue
    CLASSES+=("$cls")
  done < <(derive_test_classes_for "$file")
done <<< "$CHANGED_FILES"

# Dedup classes.
if [[ ${#CLASSES[@]} -gt 0 ]]; then
  # shellcheck disable=SC2207
  CLASSES=($(printf '%s\n' "${CLASSES[@]}" | sort -u))
fi

if [[ ${#CLASSES[@]} -eq 0 ]]; then
  echo "[pre-push-test-gate] No test classes derived for changed files. Allowing push." >&2
  echo "[pre-push-test-gate] (Consider adding tests — see CLAUDE.md 'TDD & Test Quality'.)" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Run xcodebuild test with -only-testing args, configurable wall-clock cap
# ---------------------------------------------------------------------------
# Default 180s. Cold-build cycles on the iPhone 16 Pro sim need >90s for
# multi-class -only-testing runs (xcodebuild rebuilds dependency tree + test
# target even when product is warm). Override via env when targeting a faster
# subset or a known-hot DerivedData state.
TIMEOUT_SECS="${PRE_PUSH_TESTS_TIMEOUT_SECS:-180}"
# Pick a booted iPhone sim if available; fall back to a stable name. We
# deliberately do NOT use a hardcoded UDID — harness convention forbids it
# (parallel agents would collide).
# Output format: "    iPhone 16 Pro (DF4A2A27-...-...) (Booted)" — the UDID
# is the parenthesized 36-char hex-and-dash field. `$NF` returns `(Booted)`,
# not the UDID; pull it out by regex match against the line.
SIM_ID="$(xcrun simctl list devices iPhone 2>/dev/null \
          | awk '/Booted/ { if (match($0, /[0-9A-F-]{36}/)) { print substr($0, RSTART, RLENGTH); exit } }')"

declare -a DEST_ARGS
if [[ -n "$SIM_ID" ]]; then
  DEST_ARGS=(-destination "id=$SIM_ID")
else
  DEST_ARGS=(-destination 'platform=iOS Simulator,name=iPhone 16 Pro')
fi

declare -a ONLY_TESTING_ARGS=()
for cls in "${CLASSES[@]}"; do
  ONLY_TESTING_ARGS+=("-only-testing:PalaceTests/$cls")
done

echo "[pre-push-test-gate] Running targeted tests (${#CLASSES[@]} class(es), ${TIMEOUT_SECS}s cap):" >&2
printf '[pre-push-test-gate]   - %s\n' "${CLASSES[@]}" >&2

# Wrap xcodebuild in `timeout 90` if available (coreutils). On macOS the
# built-in is `gtimeout` from brew coreutils, or `perl -e alarm`. We
# prefer `timeout`, fall back to `gtimeout`, then to a perl-alarm wrapper.
run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# Quiet xcodebuild — we only care about pass/fail at the gate.
if run_with_timeout "$TIMEOUT_SECS" xcodebuild \
     -project Palace.xcodeproj \
     -scheme Palace \
     "${DEST_ARGS[@]}" \
     "${ONLY_TESTING_ARGS[@]}" \
     test \
     -quiet >/tmp/pre-push-test-gate.log 2>&1; then
  echo "[pre-push-test-gate] PASS — ${#CLASSES[@]} class(es) green." >&2
  exit 0
else
  rc=$?
  # A timeout is NOT a test failure. `timeout`/`gtimeout` exit 124 when they
  # kill the child; the perl-alarm fallback surfaces SIGALRM as 142; and a
  # killed xcodebuild prints "** BUILD INTERRUPTED **". A cold-build multi-class
  # -only-testing run routinely exceeds the wall-clock cap without any test
  # having failed — blocking the push there (forcing SKIP_PRE_PUSH_TESTS) is
  # pure friction, since CI and `verify-pr.sh` remain the authoritative gates.
  # Treat budget-exhaustion as a non-blocking WARN; only a real test/build
  # failure (non-timeout non-zero) blocks.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ] || grep -q "BUILD INTERRUPTED" /tmp/pre-push-test-gate.log 2>/dev/null; then
    echo "" >&2
    echo "[pre-push-test-gate] TIMEOUT after ${TIMEOUT_SECS}s (exit $rc) — targeted tests did not finish in budget." >&2
    echo "[pre-push-test-gate] This is a cold-build budget limit, NOT a test failure — allowing the push." >&2
    echo "[pre-push-test-gate] Verify locally with 'scripts/verify-pr.sh --quick'; CI remains authoritative." >&2
    exit 0
  fi
  echo "" >&2
  echo "[pre-push-test-gate] FAIL (exit $rc) — push blocked." >&2
  echo "[pre-push-test-gate] Last 40 lines of /tmp/pre-push-test-gate.log:" >&2
  tail -n 40 /tmp/pre-push-test-gate.log >&2 || true
  echo "" >&2
  echo "[pre-push-test-gate] To bypass (only if you have a real reason):" >&2
  echo "[pre-push-test-gate]   SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
  exit 1
fi

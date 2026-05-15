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
#      test with a hard 90s wall-clock cap.
#   4. Failure exits 1 (blocks push). Success or no derived tests exits 0.
#
# Bypass:
#   SKIP_PRE_PUSH_TESTS=1 git push ...     # explicit opt-out (logged)
#
# The harness's existing STANZA_THRESHOLD_LOC bypass for commit-msg is
# independent of this hook.
#
# This hook is OFF BY DEFAULT. Wire it up explicitly via:
#   scripts/install-git-hooks.sh --with-pre-push-tests

set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Bypass
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
# 3. Run xcodebuild test with -only-testing args, hard 90s cap
# ---------------------------------------------------------------------------
# Pick a booted iPhone sim if available; fall back to a stable name. We
# deliberately do NOT use a hardcoded UDID — harness convention forbids it
# (parallel agents would collide).
SIM_ID="$(xcrun simctl list devices iPhone 2>/dev/null \
          | awk '/Booted/ {print $NF; exit}' | tr -d '()')"

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

echo "[pre-push-test-gate] Running targeted tests (${#CLASSES[@]} class(es), 90s cap):" >&2
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
if run_with_timeout 90 xcodebuild \
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
  echo "" >&2
  echo "[pre-push-test-gate] FAIL (exit $rc) — push blocked." >&2
  echo "[pre-push-test-gate] Last 40 lines of /tmp/pre-push-test-gate.log:" >&2
  tail -n 40 /tmp/pre-push-test-gate.log >&2 || true
  echo "" >&2
  echo "[pre-push-test-gate] To bypass (only if you have a real reason):" >&2
  echo "[pre-push-test-gate]   SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
  exit 1
fi

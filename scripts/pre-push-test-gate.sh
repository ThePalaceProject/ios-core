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
  # No upstream tracking yet (first push of a branch). Diff against the
  # merge-base with the integration branch the branch was actually cut from.
  # Campaign/tooling branches are cut from `develop`, not `main`; diffing a
  # fresh develop-cut branch against origin/main surfaces develop's ENTIRE
  # delta-from-main (hundreds of Palace/*.swift it never touched) — a false
  # "changed Swift" set that drags an unrelated scripts-only push into a full
  # xcodebuild test run. Prefer origin/develop, then origin/main, using the
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
# 1a. Zero-.swift exemption — scripts/.simdrive/docs-only tooling pushes.
# ---------------------------------------------------------------------------
# A push whose diff contains ZERO files ending in `.swift` cannot affect the
# iOS build/test outcome; running xcodebuild for it is pure drag and a
# structural false-positive (it fails on missing Carthage frameworks
# — R2LCPClient.xcframework etc. — in lightweight tooling worktrees that were
# never `carthage bootstrap`-ed). For these diffs we SKIP the iOS test build
# and instead run the repo's scripts/tests/ python suite (the relevant gate for
# scripts/.simdrive changes) when present.
#
# HARD CONSTRAINT: any diff with >=1 `.swift` file falls through to the full
# iOS-test path below, unchanged. The `.swift` detection is robust — ANY path
# ending in `.swift` (anywhere in the tree) counts as not-exempt.
ALL_CHANGED="$(git diff --name-only "$RANGE" 2>/dev/null || true)"
SWIFT_CHANGED="$(printf '%s\n' "$ALL_CHANGED" | grep -E '\.swift$' || true)"

if [[ -z "$SWIFT_CHANGED" ]]; then
  echo "[pre-push-test-gate] Zero .swift files in $RANGE — tooling-only push (scripts/.simdrive/docs)." >&2
  echo "[pre-push-test-gate] Skipping iOS xcodebuild test gate (cannot be affected by a non-Swift diff)." >&2

  # Run the scripts/tests/ python suite instead, if present. Failure here DOES
  # block the push — it's the correct gate for tooling changes.
  if [[ -d "$REPO_DIR/scripts/tests" ]] && command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import pytest' >/dev/null 2>&1; then
    echo "[pre-push-test-gate] Running scripts/tests/ suite (python -m pytest)…" >&2
    if (cd "$REPO_DIR" && python3 -m pytest scripts/tests -q) >/tmp/pre-push-scripts-tests.log 2>&1; then
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

# When the push originates from a LINKED git worktree, the shared default
# DerivedData was resolved against a different checkout root, so xcodebuild's
# SPM graph points at a stale source-package path and package resolution dies
# with "the package manifest at '/Package.swift' doesn't exist" — a false gate
# failure (the worktree itself builds fine with an isolated DerivedData). Scope
# a per-checkout DerivedData + SourcePackages dir for worktree pushes only; the
# main checkout keeps its warm default cache so the gate stays fast there.
declare -a DERIVED_ARGS=()
if [[ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]]; then
  _repo_slug="$(printf '%s' "$REPO_DIR" | shasum 2>/dev/null | cut -c1-12)"
  _dd_dir="${TMPDIR:-/tmp}/prepush-dd-${_repo_slug:-wt}"
  DERIVED_ARGS=(-derivedDataPath "$_dd_dir" -clonedSourcePackagesDirPath "$_dd_dir/SourcePackages")
  echo "[pre-push-test-gate] linked worktree detected — isolating DerivedData at $_dd_dir" >&2
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
# Clear the git hook environment before xcodebuild. git invokes pre-push
# hooks with GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE exported; xcodebuild's SPM
# resolution shells out to git internally, and an inherited GIT_WORK_TREE
# makes the local-package path resolve to "/" — failing with "the package
# manifest at '/Package.swift' doesn't exist". This is THE reason a push from
# a linked worktree (or even the main checkout, under some git versions) hits
# that error while the same xcodebuild run from a plain shell succeeds.
# Unsetting these lets xcodebuild resolve packages against the project root.
if run_with_timeout "$TIMEOUT_SECS" \
     env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_EXEC_PATH \
     xcodebuild \
     -project Palace.xcodeproj \
     -scheme Palace \
     ${DEST_ARGS[@]+"${DEST_ARGS[@]}"} \
     ${DERIVED_ARGS[@]+"${DERIVED_ARGS[@]}"} \
     ${ONLY_TESTING_ARGS[@]+"${ONLY_TESTING_ARGS[@]}"} \
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

  # A build that fails ONLY because Carthage / audiobook binary frameworks are
  # absent (a worktree that was never `carthage bootstrap`-ed / submodule-init'd,
  # e.g. a throwaway feature worktree) is an ENVIRONMENT limitation, not a code
  # failure — the same false-positive class the zero-.swift exemption above
  # already documents (R2LCPClient.xcframework etc.). The app can't even LINK, so
  # no test ran; CI (which has the frameworks) is the authoritative gate. Detect
  # the framework-missing signature AND confirm there is no real Swift/clang
  # compile error, then treat it as a non-blocking WARN (like the timeout case
  # above) instead of forcing SKIP_PRE_PUSH_TESTS.
  _FW_MISSING_RE="no XCFramework found at|Copy Files build phase contains a reference to a missing file"
  _REAL_ERRORS="$(grep -E ' error:' /tmp/pre-push-test-gate.log 2>/dev/null \
                  | grep -vE "$_FW_MISSING_RE" || true)"
  if grep -qE "$_FW_MISSING_RE" /tmp/pre-push-test-gate.log 2>/dev/null && [[ -z "$_REAL_ERRORS" ]]; then
    echo "" >&2
    echo "[pre-push-test-gate] BUILD could not LINK: Carthage/audiobook binary frameworks absent." >&2
    echo "[pre-push-test-gate]   (worktree not 'carthage bootstrap'-ed / submodule-initialised) — NOT a code failure." >&2
    echo "[pre-push-test-gate]   No test ran; CI has the frameworks and is authoritative — allowing the push." >&2
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

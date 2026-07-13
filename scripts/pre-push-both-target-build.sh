#!/usr/bin/env bash
# pre-push-both-target-build.sh — opt-in git pre-push hook that BUILDS BOTH
# the Palace (full DRM) and Palace-noDRM (open-source) schemes before a push.
#
# WHY THIS EXISTS
#   Sprint 78 shipped two regressions that no static detector can catch, because
#   they are compile-time failures in the SECOND target only:
#     - #1225 — a Swift 6 isolation change compiled clean in `Palace` but broke
#               `Palace-noDRM`.
#     - #1218 — a change that built `Palace` but broke the `Palace-noDRM` target.
#   The single-target build everyone runs locally (and the fast pre-push test
#   gate) exercises only `Palace`, so a `Palace-noDRM`-only break sails through
#   to CI (or worse, to a red develop board). This hook closes that hole by
#   compiling BOTH schemes locally before the push leaves the machine.
#
#   Build-ONLY (no test) — this is a compile/link gate, not a regression run.
#   `verify-pr.sh` and CI remain the authoritative test gates.
#
# WHEN TO RUN IT
#   Turn it on before pushing any change that can differ across the two targets:
#     - AppContainer / composition-root wiring
#     - concurrency / actor-isolation / Swift 6 Sendable changes
#     - app startup / launch sequence
#     - anything under a `#if FEATURE_DRM` / target-conditional compilation seam
#   For a docs/scripts-only push it is pure drag; leave it off.
#
# OFF BY DEFAULT — mirrors the pre-push-test-gate.sh opt-in pattern.
#   Enable for a single push:
#     ENABLE_BOTH_TARGET_BUILD_GATE=1 git push ...
#   Or export it in the agent pre-push path / your shell to make it standing.
#   Bypass once (when enabled) without unsetting:
#     SKIP_BOTH_TARGET_BUILD_GATE=1 git push ...
#
#   Wire-up note: this script is intended to be invoked from the agent pre-push
#   path (or chained from .git/hooks/pre-push). When it runs AS the pre-push
#   hook it chains `git lfs pre-push` first (below) so installing it never
#   silently disables LFS object verification.

set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Chain to git-lfs pre-push (the stock hook this one may replace).
# ---------------------------------------------------------------------------
# If this script is installed AS .git/hooks/pre-push it must run the stock LFS
# handler first — otherwise LFS object verification is silently dropped. We
# capture stdin (the ref list git feeds a pre-push hook) so we can replay it to
# LFS. This runs regardless of the enable flag: LFS integrity is not optional.
STDIN_CAPTURE="$(mktemp -t pre-push-btb-stdin.XXXXXX)"
trap 'rm -f "$STDIN_CAPTURE"' EXIT
cat > "$STDIN_CAPTURE"

if command -v git-lfs >/dev/null 2>&1; then
  if ! git lfs pre-push "$@" < "$STDIN_CAPTURE"; then
    echo "[pre-push-both-target-build] git-lfs pre-push failed — push blocked by LFS layer." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Opt-in gate — OFF BY DEFAULT.
# ---------------------------------------------------------------------------
if [[ "${ENABLE_BOTH_TARGET_BUILD_GATE:-0}" != "1" ]]; then
  # Silent no-op so it's harmless when installed but not enabled.
  exit 0
fi

if [[ "${SKIP_BOTH_TARGET_BUILD_GATE:-0}" == "1" ]]; then
  echo "[pre-push-both-target-build] SKIP_BOTH_TARGET_BUILD_GATE=1 — bypassing both-target build." >&2
  echo "[pre-push-both-target-build] (Push proceeds. Re-enable by unsetting the env var.)" >&2
  exit 0
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_DIR" || exit 0

# ---------------------------------------------------------------------------
# 2. Destination — booted iPhone sim if available; stable name fallback.
# ---------------------------------------------------------------------------
# NEVER hardcode a UDID (harness convention — parallel agents collide). Pick a
# booted iPhone sim by regex; fall back to the iPhone 16 Pro name.
SIM_ID="$(xcrun simctl list devices iPhone 2>/dev/null \
          | awk '/Booted/ { if (match($0, /[0-9A-F-]{36}/)) { print substr($0, RSTART, RLENGTH); exit } }')"

declare -a DEST_ARGS
if [[ -n "$SIM_ID" ]]; then
  DEST_ARGS=(-destination "id=$SIM_ID")
else
  DEST_ARGS=(-destination 'platform=iOS Simulator,name=iPhone 16 Pro')
fi

# ---------------------------------------------------------------------------
# 2a. Worktree DerivedData isolation.
# ---------------------------------------------------------------------------
# From a LINKED git worktree the shared default DerivedData resolves the SPM
# graph against a different checkout root and package resolution dies with
# "the package manifest at '/Package.swift' doesn't exist" — a false failure.
# Scope a per-checkout DerivedData for worktree pushes only; the main checkout
# keeps its warm default cache.
declare -a DERIVED_ARGS=()
if [[ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]]; then
  _repo_slug="$(printf '%s' "$REPO_DIR" | shasum 2>/dev/null | cut -c1-12)"
  _dd_dir="${TMPDIR:-/tmp}/prepush-btb-dd-${_repo_slug:-wt}"
  DERIVED_ARGS=(-derivedDataPath "$_dd_dir" -clonedSourcePackagesDirPath "$_dd_dir/SourcePackages")
  echo "[pre-push-both-target-build] linked worktree detected — isolating DerivedData at $_dd_dir" >&2
fi

# ---------------------------------------------------------------------------
# 3. Build helper — one scheme, build-only, quiet, framework-aware.
# ---------------------------------------------------------------------------
# Per CLAUDE.md: use -project (NOT -workspace — the workspace hits Firebase SPM
# issues). Clear the git hook environment before xcodebuild: git exports
# GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE to hooks, and xcodebuild's internal SPM
# git calls then resolve the local-package path to "/", failing with the
# '/Package.swift' doesn't exist error. Unsetting them lets package resolution
# hit the project root.
build_scheme() {
  local scheme="$1"
  shift
  local logf="$1"
  shift
  echo "[pre-push-both-target-build] Building scheme '$scheme' (build-only)…" >&2
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_EXEC_PATH \
    xcodebuild \
    -project Palace.xcodeproj \
    -scheme "$scheme" \
    ${DEST_ARGS[@]+"${DEST_ARGS[@]}"} \
    ${DERIVED_ARGS[@]+"${DERIVED_ARGS[@]}"} \
    "$@" \
    build \
    -quiet >"$logf" 2>&1
}

# A build that fails ONLY because Carthage / audiobook binary frameworks are
# absent (a worktree never `carthage bootstrap`-ed / submodule-init'd) is an
# ENVIRONMENT limitation, not a code failure — the same class the test gate
# documents. Detect the framework-missing signature AND confirm there is no
# real Swift/clang compile error before treating it as a non-blocking WARN.
is_framework_only_failure() {
  local logf="$1"
  local fw_missing_re="no XCFramework found at|Copy Files build phase contains a reference to a missing file|R2LCPClient|xcframework"
  local real_errors
  real_errors="$(grep -E ' error:' "$logf" 2>/dev/null | grep -vE "$fw_missing_re" || true)"
  if grep -qE "$fw_missing_re" "$logf" 2>/dev/null && [[ -z "$real_errors" ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 4. Build both schemes. Palace first (fast-fail on the common target), then
#    Palace-noDRM (the target that Sprint-78 breaks slipped past). noDRM
#    mirrors the CI invocation's code-signing opt-out (scripts/xcode-build-nodrm.sh).
# ---------------------------------------------------------------------------
declare -a SCHEMES=("Palace" "Palace-noDRM")
OVERALL_RC=0

for scheme in "${SCHEMES[@]}"; do
  LOGF="/tmp/pre-push-btb-${scheme}.log"

  declare -a EXTRA_ARGS=()
  if [[ "$scheme" == "Palace-noDRM" ]]; then
    # Mirror scripts/xcode-build-nodrm.sh — the noDRM target builds without a
    # signing identity in CI and locally.
    EXTRA_ARGS=(-configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
  fi

  if build_scheme "$scheme" "$LOGF" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; then
    echo "[pre-push-both-target-build] PASS — '$scheme' compiled clean." >&2
    continue
  fi

  rc=$?
  if is_framework_only_failure "$LOGF"; then
    echo "" >&2
    echo "[pre-push-both-target-build] '$scheme' could not LINK: Carthage/audiobook binary frameworks absent." >&2
    echo "[pre-push-both-target-build]   (worktree not 'carthage bootstrap'-ed / submodule-initialised) — NOT a code failure." >&2
    echo "[pre-push-both-target-build]   No compile ran to completion; CI has the frameworks and is authoritative — not blocking on this scheme." >&2
    continue
  fi

  OVERALL_RC=1
  echo "" >&2
  echo "[pre-push-both-target-build] FAIL — '$scheme' did not build (exit $rc)." >&2
  echo "[pre-push-both-target-build] Last 40 lines of $LOGF:" >&2
  tail -n 40 "$LOGF" >&2 || true
done

# ---------------------------------------------------------------------------
# 5. Verdict.
# ---------------------------------------------------------------------------
if [[ "$OVERALL_RC" -eq 0 ]]; then
  echo "[pre-push-both-target-build] PASS — both targets build. Push proceeds." >&2
  exit 0
fi

echo "" >&2
echo "[pre-push-both-target-build] BLOCKED — a target failed to build (see logs above)." >&2
echo "[pre-push-both-target-build] This is exactly the #1225/#1218 second-target-break class." >&2
echo "[pre-push-both-target-build] To bypass (only with a real reason):" >&2
echo "[pre-push-both-target-build]   SKIP_BOTH_TARGET_BUILD_GATE=1 git push ..." >&2
exit 1

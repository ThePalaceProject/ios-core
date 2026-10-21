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
#   1. Compute changed Swift files: `git diff --name-only <merge-base>..HEAD`,
#      the merge-base with the integration branch (origin/develop or
#      origin/main), filtered to `Palace/**/*.swift`. If any changed, run
#      `scripts/check-file-size-ceiling.sh`; a non-zero exit blocks the push.
#   2. For each changed file, derive its test classes: Foo.swift ->
#      Foo*Tests.swift, then every class in each candidate file that
#      declares a `func test` and whose superclass chain reaches
#      XCTestCase (directly or through a PalaceTests base such as
#      PalaceTestCase). Candidate files that the PalaceTests target does not
#      compile (per check-swift-sources-compiled.py --list-compiled) are
#      skipped: selecting them runs zero tests.
#   3. Build `-only-testing:PalaceTests/<Class>` args and run xcodebuild
#      test with a wall-clock cap (default 180s, override via
#      PRE_PUSH_TESTS_TIMEOUT_SECS=N).
#   4. Read each selected class's "Executed N tests" line from the log.
#      xcodebuild exits 0 when a selector matches nothing, so a class with 0
#      executed tests fails the gate. A run killed at the cap passes only if
#      every selected class already ran and no test failed.
#   5. Failure exits 1 (blocks push). Success or no derived tests exits 0.
#      The xcodebuild log goes to PRE_PUSH_TESTS_LOG
#      (default /tmp/pre-push-test-gate.log).
#
# Bypass:
#   SKIP_PRE_PUSH_TESTS=1 git push ...                # full opt-out (logged)
#   PRE_PUSH_TESTS_TIMEOUT_SECS=360 git push ...      # raise cap (cold builds)
#   PRE_PUSH_TESTS_ALLOW_TIMEOUT=1 git push ...       # allow a capped run in
#                                                     # which tests did not run
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
GATE_LOG="${PRE_PUSH_TESTS_LOG:-/tmp/pre-push-test-gate.log}"

# ---------------------------------------------------------------------------
# 1. Compute changed Swift files in the push range
# ---------------------------------------------------------------------------
# Diff from the merge-base with the integration branch, whether or not the
# branch has an upstream. `@{u}..HEAD` is wrong after a rebase and force-push:
# @{u} is still the pre-rebase tip, so the branch's own changes sit on both
# sides and cancel out, and the range holds only the commits it was rebased
# onto (another branch's files are tested, its own are not).
#
# The integration branch is the upstream when that is origin/develop or
# origin/main (pushing develop or main itself), otherwise origin/develop, then
# origin/main. Campaign/tooling branches are cut from `develop`; diffing a
# develop-cut branch against origin/main would surface develop's whole delta
# from main. With neither ref, fall back to the upstream, then the last commit.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
INTEGRATION_REFS=()
case "$UPSTREAM" in
  origin/develop|origin/main) INTEGRATION_REFS+=("$UPSTREAM") ;;
esac
INTEGRATION_REFS+=(origin/develop origin/main)
RANGE=""
for _ref in "${INTEGRATION_REFS[@]}"; do
  if git rev-parse --verify -q "$_ref" >/dev/null 2>&1 \
     && _BASE="$(git merge-base "$_ref" HEAD 2>/dev/null)"; then
    RANGE="${_BASE}..HEAD"
    break
  fi
done
if [[ -z "$RANGE" ]]; then
  if [[ -n "$UPSTREAM" ]]; then
    RANGE='@{u}..HEAD'
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

SCRIPTS_CHANGED="$(printf '%s\n' "$ALL_CHANGED" | grep -E '^scripts/' || true)"

# run_scripts_tests_suite — the scripts/tests/ pytest suite, or 2 when it cannot
# run here. Separated from its first caller because it is the ONLY place several
# of those tests execute: test_lint_corpus_scan.py drives
# scripts/lint-corpus-scan.swift as a real process and skips without a Swift
# toolchain, which CI deliberately does not install. While this ran only on the
# zero-.swift branch below, a push that touched that Swift tool skipped the
# suite here (Swift files present) AND skipped the behavioural tests in CI (no
# toolchain) — so the one diff most able to break it was the one nothing ran.
run_scripts_tests_suite() {
  [[ -d "$REPO_DIR/scripts/tests" ]] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  python3 -c 'import pytest' >/dev/null 2>&1 || return 2

  echo "[pre-push-test-gate] Running scripts/tests/ suite (python -m pytest)…" >&2
  # Scrub the git hook env (GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/…) before pytest —
  # inherited, it makes the tests' throwaway-repo git commands operate on the real
  # repo being pushed and corrupt the branch (same cause as the xcodebuild scrub below).
  local rc=0
  (cd "$REPO_DIR" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_EXEC_PATH python3 -m pytest scripts/tests -q) >/tmp/pre-push-scripts-tests.log 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "[pre-push-test-gate] scripts/tests PASS — tooling suite green." >&2
    return 0
  fi
  echo "" >&2
  echo "[pre-push-test-gate] scripts/tests FAIL (exit $rc) — push blocked." >&2
  echo "[pre-push-test-gate] Last 40 lines of /tmp/pre-push-scripts-tests.log:" >&2
  tail -n 40 /tmp/pre-push-scripts-tests.log >&2 || true
  echo "[pre-push-test-gate] To bypass: SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
  return 1
}

if [[ -z "$SWIFT_CHANGED" ]]; then
  echo "[pre-push-test-gate] Zero .swift files in $RANGE — tooling-only push (scripts/.simdrive/docs)." >&2
  echo "[pre-push-test-gate] Skipping iOS xcodebuild test gate (cannot be affected by a non-Swift diff)." >&2

  # Failure here DOES block the push — it's the correct gate for tooling changes.
  suite_rc=0
  run_scripts_tests_suite || suite_rc=$?
  case $suite_rc in
    0) exit 0 ;;
    1) exit 1 ;;
  esac

  echo "[pre-push-test-gate] No runnable scripts/tests/ suite (pytest absent or dir missing) — allowing push." >&2
  exit 0
fi

# A mixed push — Swift files AND scripts/ — runs the tooling suite too, then
# falls through to the iOS path. Without this the suite is unreachable for every
# diff that happens to carry a .swift file alongside the tooling it tests.
if [[ -n "$SCRIPTS_CHANGED" ]]; then
  echo "[pre-push-test-gate] scripts/ changed alongside Swift — running the tooling suite first." >&2
  suite_rc=0
  run_scripts_tests_suite || suite_rc=$?
  [[ $suite_rc -eq 1 ]] && exit 1
fi

CHANGED_FILES="$(git diff --name-only "$RANGE" -- 'Palace/*.swift' 2>/dev/null | sort -u)"

if [[ -z "$CHANGED_FILES" ]]; then
  echo "[pre-push-test-gate] No Palace/*.swift files changed in $RANGE — nothing to test." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 1b. File-size ceiling — before the targeted tests, so it runs even when no
#     test class can be derived. A few seconds, and it is the same check CI runs.
# ---------------------------------------------------------------------------
# Pushes that change no Palace/*.swift returned above, so they skip this.
CEILING_SCRIPT="$REPO_DIR/scripts/check-file-size-ceiling.sh"
if [[ -f "$CEILING_SCRIPT" ]]; then
  echo "[pre-push-test-gate] Palace/*.swift changed — checking the file-size ceiling…" >&2
  if bash "$CEILING_SCRIPT" "$REPO_DIR" >&2; then
    :
  else
    rc=$?
    echo "" >&2
    echo "[pre-push-test-gate] file-size ceiling FAILED (exit $rc) — push blocked." >&2
    echo "[pre-push-test-gate] A Swift file under Palace/ is over the ceiling or over its allowlisted cap" >&2
    echo "[pre-push-test-gate] (details above). Bring it back under by extracting code; the allowlist" >&2
    echo "[pre-push-test-gate] only ratchets down. Re-check with: bash scripts/check-file-size-ceiling.sh" >&2
    echo "[pre-push-test-gate] To bypass: SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
    exit 1
  fi
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
    if [[ -n "$COMPILED_TESTS" ]] \
       && ! grep -qxF "${candidate#"$REPO_DIR"/}" <<< "$COMPILED_TESTS"; then
      echo "[pre-push-test-gate] skipping ${candidate#"$REPO_DIR"/}: not in the PalaceTests target's Sources phase, so it runs no tests." >&2
      continue
    fi
    awk -v bases="$TEST_BASES" "$SWIFT_CLASS_AWK"'
      BEGIN { n = split(bases, b, " "); for (i = 1; i <= n; i++) ok[b[i]] = 1 }
      class_decl($0) { cur = (SUPER in ok) ? NAME : ""; if (cur != "") here[cur] = 1; next }
      { line = $0; sub(ATTRS, "", line) }
      # An extension counts only for a test class declared in this file, so
      # `extension XCTestCase` or a base from elsewhere is never selected.
      line ~ /^extension[[:space:]]/ { split(line, w, /[[:space:]:{<]+/); cur = (w[2] in here) ? w[2] : ""; next }
      line ~ /^(struct|enum|actor|protocol|class|final|open|public|internal|private|fileprivate|func|let|var)[[:space:]]/ { cur = ""; next }
      # Every test class in the file, once each: a file such as
      # MyBooksViewModelTests.swift declares many.
      cur != "" && /func[[:space:]]+test[A-Z0-9_]/ && !(cur in printed) { printed[cur] = 1; print cur }
    ' "$candidate"
  done <<< "$candidates" | sort -u
}

# Parses a top-level class declaration into NAME and SUPER. Only column-0
# declarations count: test classes are top level, and the indented ones in
# PalaceTests are nested fixtures or synthetic sources inside string literals.
SWIFT_CLASS_AWK='
  BEGIN { ATTRS = "^(@[A-Za-z]+(\\([^)]*\\))?[[:space:]]+)*" }
  function class_decl(line,   s) {
    if (line !~ /^(@[A-Za-z]+(\([^)]*\))?[[:space:]]+)*((final|open|public|internal|private|fileprivate)[[:space:]]+)*class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+/) return 0
    match(line, /class[[:space:]]+/)
    s = substr(line, RSTART + RLENGTH)
    match(s, /^[A-Za-z0-9_]+/); NAME = substr(s, 1, RLENGTH)
    s = substr(s, RLENGTH + 1); sub(/^[[:space:]]*:[[:space:]]*/, "", s)
    match(s, /^[A-Za-z0-9_]+/); SUPER = substr(s, 1, RLENGTH)
    return 1
  }
'

# XCTestCase plus every PalaceTests class whose superclass chain reaches it
# (PalaceTestCase, PalaceWiringTestCase, fixture bases). Computed from the
# tree so a new base class needs no edit here.
TEST_BASES="XCTestCase"
if [[ -d "$REPO_DIR/PalaceTests" ]]; then
  # find may split the file list across several awk runs, so the first awk
  # only emits "class superclass" pairs and the second computes the closure.
  TEST_BASES="$(find "$REPO_DIR/PalaceTests" -name '*.swift' \
                  -exec awk "$SWIFT_CLASS_AWK"'class_decl($0) { print NAME, SUPER }' {} + 2>/dev/null \
                | awk '{ sup[$1] = $2 }
                       END {
                         ok["XCTestCase"] = 1
                         do { grew = 0
                              for (c in sup) if (!(c in ok) && (sup[c] in ok)) { ok[c] = 1; grew = 1 }
                         } while (grew)
                         for (c in ok) printf "%s ", c
                       }')"
  TEST_BASES="${TEST_BASES:-XCTestCase}"
fi

# Test files the PalaceTests target compiles. A file outside every Sources
# phase still matches the filename lookup, and selecting its class runs zero
# tests while xcodebuild exits 0. If the list cannot be read, nothing is
# filtered and the executed-count check after the run still catches it.
COMPILED_TESTS=""
if [[ -d "$REPO_DIR/PalaceTests" ]]; then
  if ! COMPILED_TESTS="$(python3 "$REPO_DIR/scripts/check-swift-sources-compiled.py" \
                           --root "$REPO_DIR" --list-compiled PalaceTests 2>&1)"; then
    echo "[pre-push-test-gate] WARN: could not list the PalaceTests target's sources; not filtering test files:" >&2
    printf '[pre-push-test-gate]   %s\n' "$COMPILED_TESTS" >&2
    COMPILED_TESTS=""
  fi
fi

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
# A booted iPhone sim if there is one, else any AVAILABLE one, newest runtime
# first. Always by UDID resolved at run time -- never a UDID written down
# (parallel agents collide) and never a device NAME: a bare `name=` destination
# inherits `OS:latest`, so a runtime installed with no devices on it makes every
# such destination unresolvable. iOS 26.4 arrived that way on 2026-10-20 and
# this gate could not run, while `xcrun simctl list` showed 51 usable sims.
# `simctl list devices` prints runtimes in ascending order, so the last
# available line is the newest one that actually has a device.
# scripts/pre-push-both-target-build.sh carries the same block; keep them in step.
_sim_udid() {  # $1 = state to match, or empty for any available
  xcrun simctl list devices iPhone available 2>/dev/null | awk -v want="$1" '
    /^--/ { next }
    want != "" && index($0, "(" want ")") == 0 { next }
    { if (match($0, /[0-9A-F-]{36}/)) last = substr($0, RSTART, RLENGTH) }
    END { print last }'
}
SIM_ID="$(_sim_udid Booted)"
[[ -n "$SIM_ID" ]] || SIM_ID="$(_sim_udid "")"

if [[ -z "$SIM_ID" ]]; then
  echo "[pre-push-test-gate] no available iPhone simulator — cannot pick a destination." >&2
  echo "[pre-push-test-gate] create one: xcrun simctl create 'iPhone 16 Pro' \\" >&2
  echo "[pre-push-test-gate]   com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro <runtime id>" >&2
  echo "[pre-push-test-gate] runtimes: xcrun simctl list runtimes available" >&2
  exit 1
fi
declare -a DEST_ARGS
DEST_ARGS=(-destination "id=$SIM_ID")

# When the push originates from a LINKED git worktree, the shared default
# DerivedData was resolved against a different checkout root, so xcodebuild's
# SPM graph points at a stale source-package path and package resolution dies
# with "the package manifest at '/Package.swift' doesn't exist" — a false gate
# failure (the worktree itself builds fine with an isolated DerivedData). Scope
# a per-checkout DerivedData + SourcePackages dir for worktree pushes only; the
# main checkout keeps its warm default cache so the gate stays fast there.
# The dir lives inside the worktree (gitignored) so removing the worktree
# removes it. In $TMPDIR nothing deleted it: 46 copies held 221 GB.
declare -a DERIVED_ARGS=()
if [[ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]]; then
  _dd_dir="$REPO_DIR/.dd-prepush"
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

# Sum the "Executed N tests" line that follows each "Test Suite '<name>'
# passed|failed at" line; prints "<name> <N>" per suite. Repeated suites
# (test iterations, retries) add up.
executed_counts() {
  awk -v q="'" '
    index($0, "Test Suite " q) == 1 && $0 ~ (q " (passed|failed) at ") {
      s = substr($0, length("Test Suite " q) + 1)
      sub(q " (passed|failed) at .*", "", s)
      pending = s
      next
    }
    pending != "" && match($0, /Executed [0-9]+ tests?,/) {
      n = substr($0, RSTART + 9)
      sub(/ .*/, "", n)
      count[pending] += n
      pending = ""
    }
    END { for (k in count) print k, count[k] }
  ' "$1"
}

# Sets EMPTY to the selected classes with 0 executed tests in the log, and
# TOTAL to the tests executed across the selected classes.
count_selected_classes() {
  local counts n cls
  counts="$(executed_counts "$GATE_LOG")"
  EMPTY=()
  TOTAL=0
  for cls in "${CLASSES[@]}"; do
    n="$(awk -v c="$cls" '$1 == c { print $2; exit }' <<< "$counts")"
    n="${n:-0}"
    TOTAL=$((TOTAL + n))
    [[ "$n" -eq 0 ]] && EMPTY+=("$cls")
  done
}

# xcodebuild without -quiet: -quiet drops the per-suite "Executed N tests"
# lines that the executed-count check below reads. Parallel testing is off so
# those lines use the serial format (the scheme's default is already serial).
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
     -parallel-testing-enabled NO \
     test >"$GATE_LOG" 2>&1; then
  # Exit 0 also covers a selector that matched no test, so require every
  # selected class to have executed at least one test.
  count_selected_classes
  if [[ ${#EMPTY[@]} -gt 0 ]]; then
    echo "" >&2
    echo "[pre-push-test-gate] FAIL — xcodebuild exited 0 but ${#EMPTY[@]} selected class(es) executed 0 tests:" >&2
    printf '[pre-push-test-gate]   - %s\n' "${EMPTY[@]}" >&2
    echo "[pre-push-test-gate] ($TOTAL test(s) executed in total.) A class runs no tests when its file is not" >&2
    echo "[pre-push-test-gate] compiled into PalaceTests, it has no test methods, or the name does not match." >&2
    echo "[pre-push-test-gate] Check with: python3 scripts/check-swift-sources-compiled.py. Log: $GATE_LOG" >&2
    echo "[pre-push-test-gate] To bypass: SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
    exit 1
  fi
  echo "[pre-push-test-gate] PASS — ${#CLASSES[@]} class(es) green, $TOTAL test(s) executed." >&2
  exit 0
else
  rc=$?
  # `timeout`/`gtimeout` exit 124 when they kill the child; the perl-alarm
  # fallback surfaces SIGALRM as 142; a killed xcodebuild prints
  # "** BUILD INTERRUPTED **". A cold build can use the whole cap, and then no
  # selected test ran, so the push is allowed only when the partial log shows
  # every selected class finished with no failed test. Otherwise it blocks,
  # with two escape hatches: a larger cap, or PRE_PUSH_TESTS_ALLOW_TIMEOUT=1,
  # which still blocks a test failure seen before the cap.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ] || grep -q "BUILD INTERRUPTED" "$GATE_LOG" 2>/dev/null; then
    echo "" >&2
    echo "[pre-push-test-gate] TIMEOUT after ${TIMEOUT_SECS}s (exit $rc) — xcodebuild was stopped at the cap." >&2
    FAILED_CASES="$(grep -E "^Test Case '.*' failed \(" "$GATE_LOG" 2>/dev/null || true)"
    if [[ -n "$FAILED_CASES" ]]; then
      echo "[pre-push-test-gate] FAIL — tests failed before the cap — push blocked:" >&2
      printf '[pre-push-test-gate]   %s\n' "$FAILED_CASES" >&2
      echo "[pre-push-test-gate] Log: $GATE_LOG. To bypass: SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
      exit 1
    fi
    count_selected_classes
    if [[ ${#EMPTY[@]} -eq 0 ]]; then
      echo "[pre-push-test-gate] every selected class ran ($TOTAL test(s)) before the cap and none failed — allowing the push." >&2
      exit 0
    fi
    echo "[pre-push-test-gate] ${#EMPTY[@]} of ${#CLASSES[@]} selected class(es) did not finish before the cap:" >&2
    printf '[pre-push-test-gate]   - %s\n' "${EMPTY[@]}" >&2
    if [[ "${PRE_PUSH_TESTS_ALLOW_TIMEOUT:-0}" == "1" ]]; then
      echo "[pre-push-test-gate] PRE_PUSH_TESTS_ALLOW_TIMEOUT=1 — allowing the push without these tests." >&2
      echo "[pre-push-test-gate] Verify locally with 'scripts/verify-pr.sh --quick'; CI remains authoritative." >&2
      exit 0
    fi
    echo "[pre-push-test-gate] Push blocked: these tests have not run. Either raise the cap" >&2
    echo "[pre-push-test-gate]   PRE_PUSH_TESTS_TIMEOUT_SECS=600 git push ..." >&2
    echo "[pre-push-test-gate] or, on a machine too slow to finish in any reasonable cap, allow it" >&2
    echo "[pre-push-test-gate]   PRE_PUSH_TESTS_ALLOW_TIMEOUT=1 git push ..." >&2
    echo "[pre-push-test-gate] Log: $GATE_LOG" >&2
    exit 1
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
  _REAL_ERRORS="$(grep -E ' error:' "$GATE_LOG" 2>/dev/null \
                  | grep -vE "$_FW_MISSING_RE" || true)"
  if grep -qE "$_FW_MISSING_RE" "$GATE_LOG" 2>/dev/null && [[ -z "$_REAL_ERRORS" ]]; then
    echo "" >&2
    echo "[pre-push-test-gate] BUILD could not LINK: Carthage/audiobook binary frameworks absent." >&2
    echo "[pre-push-test-gate]   (worktree not 'carthage bootstrap'-ed / submodule-initialised) — NOT a code failure." >&2
    echo "[pre-push-test-gate]   No test ran; CI has the frameworks and is authoritative — allowing the push." >&2
    exit 0
  fi

  echo "" >&2
  echo "[pre-push-test-gate] FAIL (exit $rc) — push blocked." >&2
  echo "[pre-push-test-gate] Last 40 lines of $GATE_LOG:" >&2
  tail -n 40 "$GATE_LOG" >&2 || true
  echo "" >&2
  echo "[pre-push-test-gate] To bypass (only if you have a real reason):" >&2
  echo "[pre-push-test-gate]   SKIP_PRE_PUSH_TESTS=1 git push ..." >&2
  exit 1
fi

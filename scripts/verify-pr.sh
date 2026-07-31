#!/bin/bash
# verify-pr.sh — Full verification battery before PR creation
# Runs all available testing tools and reports outcomes.
# Exit 0 if all checks pass, 1 if any fail.
#
# Usage:
#   scripts/verify-pr.sh                       # Run all checks
#   scripts/verify-pr.sh --quick               # Skip mutation testing (faster)
#   scripts/verify-pr.sh --report <file>       # Write JSON report to file
#   scripts/verify-pr.sh --diff-baseline       # On test failures, re-run failing
#                                              #   classes in isolation to distinguish
#                                              #   pre-existing test-isolation flakes
#                                              #   from branch-introduced regressions.
#                                              #   Per .forgeos/wall-failures/ —
#                                              #   PR #1018 lessons.
#   scripts/verify-pr.sh --mutation-only       # Run ONLY the mutation step (skips
#                                              # build/test/lint/coverage/a11y).
#                                              # Used by the mutation-on-pr.yml
#                                              # CI workflow which already runs
#                                              # the rest via unit-testing.yml.
#   scripts/verify-pr.sh --enforce-mutations   # Strictness ON for every changed
#                                              # file (default: critical paths
#                                              # strict, non-critical advisory).
#                                              # Critical paths: Audiobooks/
#                                              # SignInLogic/MyBooks/Download*.
#   scripts/verify-pr.sh --no-enforce-mutations
#                                              # Opt out: critical paths drop
#                                              # to advisory-only too. Use for
#                                              # known-large refactors that need
#                                              # follow-up test work but should
#                                              # not block CI in the meantime.
#   scripts/verify-pr.sh --mutation-min-kill-rate N
#                                              # Override the per-file kill-rate
#                                              # floor (default: 50%).
#   scripts/verify-pr.sh --mutation-whole-file # Mutate the WHOLE file instead of
#                                              # only the lines this PR changed.
#                                              # Default for the PR gate is
#                                              # --diff-only (kill rate reflects
#                                              # YOUR diff, not the file's whole
#                                              # history). Pass this for release
#                                              # runs that want full-file coverage.
#   scripts/verify-pr.sh --simdrive            # Also replay .simdrive/journeys/*.yaml
#                                              # via simdrive. MAINTAINER-INTERNAL:
#                                              # simdrive is not yet publicly
#                                              # distributed; `pip3 install --pre
#                                              # simdrive` requires private access.
#                                              # CI (chaos-replay-on-pr.yml) replays
#                                              # the corpus server-side for every PR
#                                              # regardless of this flag.
#
# Mutation policy (per CLAUDE.md "Mutation testing"):
#   Critical paths (Palace/Audiobooks/, Palace/SignInLogic/,
#   Palace/MyBooks/Download*) are STRICT BY DEFAULT — a kill rate below the
#   --mutation-min-kill-rate floor fails the gate. Non-critical changed files
#   are advisory: low kill rates are surfaced as warnings but do not fail.
#   --enforce-mutations promotes every changed file to strict.
#   --no-enforce-mutations demotes critical paths to advisory.
#
#   DIFF-SCOPED BY DEFAULT: the PR gate runs palace_mutate.py with --diff-only,
#   so the kill rate reflects the lines THIS PR changed, not the file's whole
#   history. Pass --mutation-whole-file for release runs that want full-file
#   coverage.
#
#   CRITICAL-PATH SURVIVOR OVERRIDE: independent of the kill-rate floor, any
#   critical-path file whose JSON report shows summary.critical_path_survivors > 0
#   (a SURVIVED mutant with a consequential op — cmp/bool/bound/retval/cond) is a
#   STRICT FAIL. A 100%-on-paper kill rate cannot mask a surviving consequential
#   mutant on a user-money path.
#
# Designed to be called by:
#   - Claude Code agents before PR creation
#   - forgeos-session.sh evidence (comprehensive mode)
#   - CI workflows for gating

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Load check FIRST, before anything is measured. A suite run on a saturated box
# produces a different unrelated failure each time, each passing in isolation —
# indistinguishable by eye from a known flake, and it has cost this project hours
# of misdiagnosis. Advisory by design: it prints the warning and continues, so a
# busy machine never blocks a run, but the result is labelled untrusted.
if [[ -x "$SCRIPT_DIR/check-machine-quiet.sh" ]]; then
  "$SCRIPT_DIR/check-machine-quiet.sh" || true
fi

QUICK=false
REPORT_FILE=""
SIMDRIVE=false
# Default for --diff-baseline; without this the `elif [ "$DIFF_BASELINE" ...`
# branch dies with "unbound variable" under `set -u` whenever the unit-test
# pass condition is false.
DIFF_BASELINE=false
# Mutation policy tri-state:
#   default        — critical paths strict, others advisory
#   enforce_all    — every changed file strict (--enforce-mutations)
#   advisory_all   — every changed file advisory (--no-enforce-mutations)
MUTATION_POLICY="default"
MUTATION_ONLY=false
# Per-file kill-rate floor. CLAUDE.md says 50%; tunable via flag for the rare
# case where a sweep needs a higher bar (e.g. critical-path hardening sprint).
MUTATION_MIN_KILL_RATE=50
# Diff-scoped by default for the PR gate: palace_mutate.py only mutates the lines
# this PR changed (kill rate reflects YOUR diff, not the whole file's history).
# --mutation-whole-file flips this for release runs that want full-file coverage.
MUTATION_WHOLE_FILE=false

# Critical paths: every changed file matching one of these prefixes is held to
# the strict kill-rate floor unless explicitly opted out via --no-enforce-mutations.
# These are the user-money / access-bearing paths memory flagged as air-tight.
#
# Enumeration methodology, file-by-file inclusion list, and the Reader2
# exemption (covered by Module D contract snapshots, not mutation) are
# documented in `docs/architecture/critical-path-mutation-coverage.md`.
# Re-run that audit after any file rename in the listed surfaces or any PR
# that adds a new state machine, retry handler, or borrow/download/DRM router.
CRITICAL_MUTATION_PATHS_REGEX='^Palace/(Audiobooks/|SignInLogic/|MyBooks/(Download|Borrow|BookSignInRedirectHandler|AdobeDRMHandler|LCPFulfillmentHandler|RightsManagementDispatcher|MyBooksDownload|BackgroundDownloadHandler|OverdriveDownloadHandler)|Book/UI/BookDetail/(BookButtonMapper|BorrowReducer)|Accounts/User/TPPUserAccount|Accounts/Library/AccountsManager|Network/TPPNetworkExecutor|Packages/PalaceAuth/)'
# Sim selection. Honors the harness allocator's per-session UDID so parallel
# agents on the same machine don't collide on one device. Falls back to the
# pool default when the harness isn't claiming. CLAUDE.md: "NEVER hardcode a
# sim UDID" — this default is the documented fallback, not a hardcode.
SIM_ID="${HARNESS_SESSION_SIM_UDID:-DF4A2A27-9888-429D-A749-2E157A049A37}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --report) REPORT_FILE="$2"; shift 2 ;;
    --diff-baseline) DIFF_BASELINE=true; shift ;;
    --simdrive) SIMDRIVE=true; shift ;;
    --enforce-mutations) MUTATION_POLICY="enforce_all"; shift ;;
    --no-enforce-mutations) MUTATION_POLICY="advisory_all"; shift ;;
    --mutation-only) MUTATION_ONLY=true; QUICK=false; shift ;;
    --mutation-min-kill-rate) MUTATION_MIN_KILL_RATE="$2"; shift 2 ;;
    --mutation-whole-file) MUTATION_WHOLE_FILE=true; shift ;;
    *) shift ;;
  esac
done

# Detect changed files against base branch
detect_base_branch() {
  for candidate in origin/develop origin/main origin/master; do
    if git rev-parse --verify "$candidate" &>/dev/null; then
      echo "$candidate"
      return
    fi
  done
  echo "HEAD~10"
}

BASE=$(detect_base_branch)
CHANGED_SWIFT=$(git diff --name-only "$BASE"...HEAD -- '*.swift' 2>/dev/null | grep -v 'Tests/' || true)
CHANGED_TEST_SWIFT=$(git diff --name-only "$BASE"...HEAD -- '*.swift' 2>/dev/null | grep 'Tests/' || true)
# Scope a11y file picker to actual SwiftUI/UIKit view files. Exclude
# non-view siblings (ViewModel, Model, Reducer, Service, Provider, Mapper,
# Store, Coordinator, Builder, Dispatcher) that happen to substring-match
# "View" or "Controller". Documented in feedback_verify_pr_false_positives.md.
CHANGED_UI=$(echo "$CHANGED_SWIFT" \
  | grep -E '(UI/|View|Cell|Controller)' \
  | grep -Ev '(ViewModel|ViewState|Model|Reducer|Service|Provider|Mapper|Store|Coordinator|Builder|Dispatcher|Repository|Manager)\.swift$' \
  || true)
ALL_CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null || true)

# Docs-only fast-path. If every changed file matches a documentation or
# repo-meta pattern, skip the build/test/lint/coverage/mutation/a11y battery.
# The battery exists to gate behavioral risk; pure documentation cannot
# regress runtime behavior, so running 15-30 min of xcodebuild for it is
# policy without substance. Honest evidence in seconds beats expensive
# evidence that asserts the same thing.
#
# Allowlist (any other path triggers the full battery):
#   docs/**           — generated and hand-written docs
#   *.md, *.txt       — markdown / plain text anywhere in the tree
#   README*           — readmes
#   LICENSE*, NOTICE  — legal/attribution files
#   CHANGELOG*        — release notes
#   .gitignore, .gitattributes — repo metadata
DOCS_ONLY=false
if [ -n "$ALL_CHANGED" ]; then
  NON_DOCS=$(echo "$ALL_CHANGED" | grep -vE '^docs/|\.md$|\.txt$|(^|/)README|(^|/)LICENSE|(^|/)NOTICE|(^|/)CHANGELOG|(^|/)\.gitignore$|(^|/)\.gitattributes$' || true)
  if [ -z "$NON_DOCS" ]; then
    DOCS_ONLY=true
  fi
fi

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

record() {
  local check="$1" status="$2" detail="$3"
  if [ "$status" = "pass" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [PASS] $check"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  [FAIL] $check — $detail"
  fi
  RESULTS+=("{\"check\":\"$check\",\"status\":\"$status\",\"detail\":\"$(echo "$detail" | sed 's/"/\\"/g')\"}")
}

echo "=== Palace Pre-PR Verification ==="
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
echo "Changed files: $(echo "$CHANGED_SWIFT" | wc -l | tr -d ' ') production, $(echo "$CHANGED_TEST_SWIFT" | wc -l | tr -d ' ') test"
echo ""

# Docs-only fast-path: skip build/test/lint/coverage/mutation/a11y when no
# source files changed. Honest pass records, written to JSON report and stdout
# the same as the full battery would emit, just with explicit "skipped" detail.
if [ "$DOCS_ONLY" = "true" ]; then
  echo "--- Docs-only fast-path ---"
  echo "All changed files match the docs/meta allowlist. Skipping the full battery."
  echo "Changed files:"
  echo "$ALL_CHANGED" | sed 's/^/  /'
  echo ""
  record "build" "pass" "Skipped — docs-only PR (no source files changed)"
  record "unit_tests" "pass" "Skipped — docs-only PR (no source files changed)"
  record "test_quality" "pass" "Skipped — docs-only PR (no test files changed)"
  record "coverage_floors" "pass" "Skipped — docs-only PR (no source files changed)"
  record "mutation" "pass" "Skipped — docs-only PR (no production Swift changed)"
  record "audiobook_smoke" "pass" "Skipped — docs-only PR (no audiobook files changed)"
  record "accessibility" "pass" "Skipped — docs-only PR (no UI files changed)"
  TEST_PASS=0
  TEST_FAIL=0

  echo ""
  echo "=== Summary ==="
  echo "  Passed: $PASS_COUNT"
  echo "  Failed: $FAIL_COUNT"

  if [ -n "$REPORT_FILE" ]; then
    RESULTS_JSON=$(printf '%s,' "${RESULTS[@]}" | sed 's/,$//')
    cat > "$REPORT_FILE" <<JSONEOF
{
  "branch": "$(git rev-parse --abbrev-ref HEAD)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fast_path": "docs-only",
  "pass_count": $PASS_COUNT,
  "fail_count": $FAIL_COUNT,
  "unit_tests": {"pass": $TEST_PASS, "fail": $TEST_FAIL},
  "checks": [$RESULTS_JSON]
}
JSONEOF
    echo "  Report written to: $REPORT_FILE"
  fi

  echo ""
  echo "CLEAR: docs-only fast-path — full battery skipped (no behavioral risk)."
  exit 0
fi

# 1. Build check
# Skipped in --mutation-only mode: palace_mutate.py rebuilds per-mutant so the
# pre-flight build adds nothing; the CI workflow that uses --mutation-only
# runs the build separately via unit-testing.yml.
echo "--- Build ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "build" "pass" "Skipped (--mutation-only)"
else
BUILD_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM_ID" build 2>&1)
if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED\|BUILD FAILED"; then
  # `|| true` (not `|| echo "0"`): grep -c already prints "0" on no match, so
  # the fallback was producing "0\n0" and breaking the integer test below.
  SWIFT_ERRORS=$(echo "$BUILD_OUTPUT" | grep -c "error:.*\.swift:" || true)
  if [ "${SWIFT_ERRORS:-0}" -eq 0 ]; then
    record "build" "pass" "No Swift compilation errors"
  else
    record "build" "fail" "$SWIFT_ERRORS Swift compilation errors"
  fi
else
  record "build" "fail" "Build did not complete"
fi
fi

# 2. Unit tests
echo "--- Unit Tests ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "unit_tests" "pass" "Skipped (--mutation-only)"
  TEST_PASS=0
  TEST_FAIL=0
else
TEST_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM_ID" test 2>&1 || true)
# Count only the top-level "All tests" rollups (one per .xctest bundle).
# Each XCTestCase suite ALSO emits "Executed N" + each bundle emits its own
# "Selected tests" wrapper, so the prior `grep -o ... | awk '{s+=$1}'` summed
# the same tests 4-5× and inflated the headline by ~3.5× (e.g. 5,867 unique
# tests reported as 17,640). The `-A1` after "Test Suite 'All tests' (passed|failed)"
# captures the bundle-rollup `Executed N tests` line per bundle.
ROLLUP_LINES=$(echo "$TEST_OUTPUT" | grep -A1 "Test Suite '\(All tests\|Selected tests\)' \(passed\|failed\)")
TEST_PASS=$(echo "$ROLLUP_LINES" | grep -o 'Executed [0-9]* tests\?' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
# Failed-bundle rollups say "and 3 failures" (no "with" prefix); passed
# bundles say "with 0 failures". Match on the trailing " failure" word.
TEST_FAIL=$(echo "$ROLLUP_LINES" | grep -oE '[0-9]+ failures? \(' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
if [ "$TEST_FAIL" -eq 0 ] && [ "$TEST_PASS" -gt 0 ]; then
  record "unit_tests" "pass" "$TEST_PASS tests, 0 failures"
elif [ "$DIFF_BASELINE" = "true" ] && [ "$TEST_FAIL" -gt 0 ]; then
  # --diff-baseline: distinguish pre-existing test-isolation flakes from
  # branch-introduced regressions. Extract failing class names from the
  # most recent xcresult, re-run each class in isolation, and only fail
  # the gate if a class fails in isolation too. Mirrors the manual triage
  # for PR #1018 (9 "failures" all passed in isolation).
  XCRESULT=$(find ~/Library/Developer/Xcode/DerivedData -name "*.xcresult" -mmin -30 -type d 2>/dev/null | head -1)
  if [ -n "$XCRESULT" ] && command -v xcrun >/dev/null 2>&1; then
    # Walk xcresult JSON to extract failing test-case node names → class names
    FAILING_CLASSES=$(xcrun xcresulttool get test-results tests --path "$XCRESULT" --format json 2>/dev/null | \
      python3 -c "
import json, sys, re
data = json.load(sys.stdin)
classes = set()
def walk(node, parent=''):
    name = node.get('name', '')
    full = f'{parent}/{name}' if parent else name
    if node.get('result') == 'Failed':
        # Test case path looks like 'Palace > PalaceTests > <Class> > <test>()'
        parts = full.split(' > ')
        if len(parts) >= 3:
            cls = parts[-2]
            if cls and re.match(r'^[A-Za-z_][A-Za-z0-9_]*Tests?$', cls):
                classes.add(cls)
    for child in node.get('children', []) + node.get('testNodes', []):
        walk(child, full)
walk(data)
print('\n'.join(sorted(classes)))
" 2>/dev/null | head -20)

    if [ -n "$FAILING_CLASSES" ]; then
      echo "  → --diff-baseline: re-running $(echo "$FAILING_CLASSES" | wc -l | tr -d ' ') failed class(es) in isolation..."
      REAL_FAIL=0
      FLAKE_COUNT=0
      ONLY_TESTING_ARGS=""
      for cls in $FAILING_CLASSES; do
        ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:PalaceTests/$cls"
      done
      # Single xcodebuild invocation with all failing classes — N classes in
      # one build is much faster than N separate builds with cold derivedData.
      ISOLATED_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
        -destination "id=$SIM_ID" $ONLY_TESTING_ARGS test 2>&1 || true)
      for cls in $FAILING_CLASSES; do
        if echo "$ISOLATED_OUTPUT" | grep -qE "Test Suite '$cls' passed"; then
          FLAKE_COUNT=$((FLAKE_COUNT + 1))
        else
          REAL_FAIL=$((REAL_FAIL + 1))
        fi
      done
      if [ "$REAL_FAIL" -eq 0 ] && [ "$FLAKE_COUNT" -gt 0 ]; then
        record "unit_tests" "pass" "$TEST_PASS tests, $TEST_FAIL fails — all $FLAKE_COUNT failing classes pass in isolation (pre-existing test-isolation flakes per --diff-baseline)"
      else
        record "unit_tests" "fail" "$TEST_PASS tests, $TEST_FAIL fails — $REAL_FAIL classes fail IN ISOLATION (real regression), $FLAKE_COUNT classes are isolation flakes"
      fi
    else
      record "unit_tests" "fail" "$TEST_PASS tests, $TEST_FAIL failures (--diff-baseline could not extract class names from xcresult)"
    fi
  else
    record "unit_tests" "fail" "$TEST_PASS tests, $TEST_FAIL failures (--diff-baseline requires xcrun + recent xcresult)"
  fi
else
  record "unit_tests" "fail" "$TEST_PASS tests, $TEST_FAIL failures"
fi
fi

# 3. Test quality lint
# Diff-scoped: only fail when *changed* test files carry blocking rules
# (FLAKE-* / FLUFF-* / MISSING-* / TIMEOUT-*). SHALLOW-001 is advisory —
# pre-existing shallow tests in files the PR touches don't fail the gate.
# `--per-file` emits one `<path>:<line>:<rule>` line per violation so we
# can scope precisely with anchored grep.
echo "--- Test Quality Lint ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "test_quality" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/lint-test-quality.py ]; then
  LINT_PER_FILE=$(python3 scripts/lint-test-quality.py --per-file 2>&1 || true)
  NEW_VIOLATIONS=0
  while IFS= read -r test_file; do
    [ -z "$test_file" ] && continue
    # Anchor grep to start-of-line so the path matches exactly the
    # changed file and doesn't false-positive on substring overlap
    # (e.g. `Foo.swift` vs `FooExtensionTests.swift`).
    FILE_VIOLATIONS=$(echo "$LINT_PER_FILE" | grep -E "^$test_file:[0-9]+:(FLAKE|FLUFF|MISSING|TIMEOUT)-" | wc -l | tr -d ' ')
    NEW_VIOLATIONS=$((NEW_VIOLATIONS + FILE_VIOLATIONS))
  done <<< "$CHANGED_TEST_SWIFT"
  if [ "$NEW_VIOLATIONS" -eq 0 ]; then
    record "test_quality" "pass" "0 blocking violations in changed test files (SHALLOW advisory)"
  else
    record "test_quality" "fail" "$NEW_VIOLATIONS blocking violations in changed test files"
  fi
else
  record "test_quality" "pass" "Lint script not found (skipped)"
fi

# 3a. Contract reconciliation (M1 universal-rigor-floor gate)
# Reconciles "removes X" / "deletes X" / "migrates Y to Z" / "renames X to Y" /
# "adds field A to type B" claims in the commit body / PR body / intent file
# against the staged-diff (HEAD vs base). Catches the contract-vs-diff drift
# class surfaced in waves 1-4. See `scripts/check-contract-reconciliation.py`.
echo "--- Contract reconciliation ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "contract_reconciliation" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-contract-reconciliation.py ]; then
  CR_DIFF=$(mktemp -t cr-diff.XXXX)
  CR_MSG=$(mktemp -t cr-msg.XXXX)
  git diff "$BASE"...HEAD > "$CR_DIFF" 2>/dev/null || true
  # Capture HEAD commit subject + body as the claim source. Architect rev_f1c4ea3c
  # caught the wiring gap where this script ran without a claim source and silently
  # passed regardless of what the commit body claimed. Pass --commit-msg so the
  # gate is no longer decorative.
  git log -1 --format=%B HEAD > "$CR_MSG" 2>/dev/null || echo "" > "$CR_MSG"
  # Also pass --intent if a matching intent file exists. Match on the commit
  # subject's first 4 dash-separated tokens (e.g. "[swarm_M1_83be56fc] Module C ..."
  # → "swarm-m1" matches `.forgeos/intent/swarm-m1-*.md`).
  CR_INTENT_FLAG=""
  CR_SUBJECT=$(head -1 "$CR_MSG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{print $1"-"$2}')
  if [ -n "$CR_SUBJECT" ] && [ -d .forgeos/intent ]; then
    CR_INTENT_MATCH=$(find .forgeos/intent -maxdepth 1 -name "*${CR_SUBJECT}*.md" -type f 2>/dev/null | head -1)
    [ -n "$CR_INTENT_MATCH" ] && CR_INTENT_FLAG="--intent $CR_INTENT_MATCH"
  fi
  CR_OUT=$(python3 scripts/check-contract-reconciliation.py --diff "$CR_DIFF" --commit-msg "$CR_MSG" $CR_INTENT_FLAG --quiet 2>&1)
  CR_EXIT=$?
  rm -f "$CR_DIFF" "$CR_MSG"
  if [ "$CR_EXIT" -eq 0 ]; then
    record "contract_reconciliation" "pass" "All commit/PR/intent claims reconciled with diff"
  else
    record "contract_reconciliation" "fail" "Unreconciled claims: $(echo "$CR_OUT" | head -3 | tr '\n' ' ')"
  fi
else
  record "contract_reconciliation" "pass" "check-contract-reconciliation.py not found (skipped)"
fi

# 3b. Blast-radius (M1 universal-rigor-floor gate)
# Scans the diff for new public/open symbols, #if DEBUG production reach,
# test-only public(private(set)) counters, container-init churn, and
# discarded function results without `// TODO(ticket):` justification.
# High-severity findings block. See `scripts/check-blast-radius.py`.
echo "--- Blast-radius ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "blast_radius" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-blast-radius.py ]; then
  BR_DIFF=$(mktemp -t br-diff.XXXX)
  git diff "$BASE"...HEAD > "$BR_DIFF" 2>/dev/null || true
  BR_OUT=$(python3 scripts/check-blast-radius.py --diff "$BR_DIFF" --quiet 2>&1)
  BR_EXIT=$?
  rm -f "$BR_DIFF"
  if [ "$BR_EXIT" -eq 0 ]; then
    record "blast_radius" "pass" "No high-severity blast-radius findings"
  else
    record "blast_radius" "fail" "High-severity findings: $(echo "$BR_OUT" | head -3 | tr '\n' ' ')"
  fi
else
  record "blast_radius" "pass" "check-blast-radius.py not found (skipped)"
fi

# 3c. Adjacency staleness (M1 universal-rigor-floor gate, warn-only)
# Greps comments in the surviving codebase for references to removed/renamed
# declarations in the diff. Always passes; counts warnings.
# See `scripts/check-adjacency-staleness.py`.
echo "--- Adjacency staleness ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "adjacency_staleness" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-adjacency-staleness.py ]; then
  ADJ_DIFF=$(mktemp -t adj-diff.XXXX)
  git diff "$BASE"...HEAD > "$ADJ_DIFF" 2>/dev/null || true
  ADJ_OUT=$(python3 scripts/check-adjacency-staleness.py --diff "$ADJ_DIFF" --quiet 2>&1)
  ADJ_EXIT=$?
  rm -f "$ADJ_DIFF"
  ADJ_WARN_COUNT=$(echo "$ADJ_OUT" | grep -c "ADJ-STALE" || true)
  if [ "$ADJ_EXIT" -eq 0 ]; then
    record "adjacency_staleness" "pass" "0 stale-comment references"
  else
    # warn-only: still record pass, but surface the count
    record "adjacency_staleness" "pass" "${ADJ_WARN_COUNT:-0} stale-comment warning(s) — non-blocking"
  fi
else
  record "adjacency_staleness" "pass" "check-adjacency-staleness.py not found (skipped)"
fi

# 3d. Intent recorded (M1 universal-rigor-floor gate)
# Requires a `.forgeos/intent/<name>.md` for diffs ≥10 prod LOC under Palace/.
# Intent file must have frontmatter (name/created/author) + body sections
# (## Claims / ## Anti-claims / ## Files in scope). See `scripts/check-intent-recorded.py`.
echo "--- Intent recorded ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "intent_recorded" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-intent-recorded.py ]; then
  IR_DIFF=$(mktemp -t ir-diff.XXXX)
  IR_MSG=$(mktemp -t ir-msg.XXXX)
  git diff "$BASE"...HEAD > "$IR_DIFF" 2>/dev/null || true
  # Pass HEAD's commit subject so the intent-name → subject match runs.
  # Without this, the check sees the diff but has no subject to match
  # `.forgeos/intent/<name>.md`'s `name:` field against, and bails out
  # with INTENT-MISSING even when the intent file exists and matches.
  git log -1 --format="%s" > "$IR_MSG" 2>/dev/null || true
  IR_OUT=$(python3 scripts/check-intent-recorded.py --diff "$IR_DIFF" \
                                                   --commit-msg "$IR_MSG" \
                                                   --quiet 2>&1)
  IR_EXIT=$?
  rm -f "$IR_DIFF" "$IR_MSG"
  if [ "$IR_EXIT" -eq 0 ]; then
    record "intent_recorded" "pass" "Intent file present (or below threshold)"
  else
    record "intent_recorded" "fail" "Intent missing/invalid: $(echo "$IR_OUT" | head -3 | tr '\n' ' ')"
  fi
else
  record "intent_recorded" "pass" "check-intent-recorded.py not found (skipped)"
fi

# 3e. Superpartner spectrum (M1 universal-rigor-floor gate, warn-only)
# Flags new functions / enum cases / state changes in the diff that have no
# matching test in the diff, unless marked `// no-superpartner:`. Warn-only for
# now (promotion path in docs/architecture/superpartner-spectrum.md).
# See `scripts/check-superpartner-spectrum.py`.
echo "--- Superpartner spectrum ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "superpartner_spectrum" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-superpartner-spectrum.py ]; then
  SP_DIFF=$(mktemp -t sp-diff.XXXX)
  git diff "$BASE"...HEAD > "$SP_DIFF" 2>/dev/null || true
  SP_OUT=$(python3 scripts/check-superpartner-spectrum.py --diff "$SP_DIFF" --quiet 2>&1)
  SP_EXIT=$?
  rm -f "$SP_DIFF"
  SP_WARN_COUNT=$(echo "$SP_OUT" | grep -cE ": SP-[0-9]" || true)
  if [ "$SP_EXIT" -eq 0 ]; then
    record "superpartner_spectrum" "pass" "0 untested new functions/cases/state"
  else
    # warn-only: still record pass, but surface the count
    record "superpartner_spectrum" "pass" "${SP_WARN_COUNT:-0} superpartner warning(s) — non-blocking"
  fi
else
  record "superpartner_spectrum" "pass" "check-superpartner-spectrum.py not found (skipped)"
fi

# 3f. Test name-vs-body (M1 universal-rigor-floor gate, warn-only, file-based)
# Flags diffed test files whose method names embed a production-class noun the
# body never references (fake-wiring). File-based: operates on the changed test
# files, not a diff. See `scripts/check-test-name-vs-body.py`.
echo "--- Test name-vs-body ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "test_name_vs_body" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/check-test-name-vs-body.py ] && [ -n "$CHANGED_TEST_SWIFT" ]; then
  TNB_FILES=()
  while IFS= read -r f; do [ -n "$f" ] && [ -f "$f" ] && TNB_FILES+=("$f"); done <<< "$CHANGED_TEST_SWIFT"
  if [ "${#TNB_FILES[@]}" -eq 0 ]; then
    record "test_name_vs_body" "pass" "No changed test files on disk"
  else
    TNB_OUT=$(python3 scripts/check-test-name-vs-body.py "${TNB_FILES[@]}" --quiet 2>&1)
    TNB_EXIT=$?
    TNB_COUNT=$(echo "$TNB_OUT" | grep -cE "embeds|fake-wiring" || true)
    if [ "$TNB_EXIT" -eq 0 ]; then
      record "test_name_vs_body" "pass" "No fake-wiring test names"
    else
      # warn-only: still record pass, but surface the count
      record "test_name_vs_body" "pass" "${TNB_COUNT:-0} name-vs-body warning(s) — non-blocking"
    fi
  fi
else
  record "test_name_vs_body" "pass" "No changed test files (skipped)"
fi

# 3g-3l. Phase 3.5 class-detectable detectors (swarm_162a3219)
# Each codifies a shipped-bug class as a runnable detector that scans the
# staged diff. Block-mode on high-severity classes (foreign-host 401, LCP
# recursive acquisition, completion-nil-error suppression, NSError problemDoc
# preservation); warn-only on lower-severity classes (SwiftUI placeholder a11y,
# NotificationCenter observer storage). Same inline shape as the M1 gates above.
run_phase35_detector() {
  # $1=record key  $2=script  $3=block|warn  $4=pass message  $5=diff|scan (invocation mode)
  local key="$1" script="$2" mode="$3" pass_msg="$4" scan_mode="${5:-diff}"
  if [ "$MUTATION_ONLY" = "true" ]; then
    record "$key" "pass" "Skipped (--mutation-only)"
  elif [ -f "scripts/$script" ]; then
    local d out exit_code
    if [ "$scan_mode" = "scan" ]; then
      # Tree-scan detectors (e.g. check-lcp-acquisition-recursive.py) have no
      # --diff flag — passing one is an argparse error → spurious block.
      out=$(python3 "scripts/$script" --quiet 2>&1)
      exit_code=$?
    else
      d=$(mktemp -t p35-diff.XXXX)
      git diff "$BASE"...HEAD > "$d" 2>/dev/null || true
      out=$(python3 "scripts/$script" --diff "$d" --quiet 2>&1)
      exit_code=$?
      rm -f "$d"
    fi
    if [ "$exit_code" -eq 0 ]; then
      record "$key" "pass" "$pass_msg"
    elif [ "$mode" = "warn" ]; then
      record "$key" "pass" "$(echo "$out" | head -1) — non-blocking"
    else
      record "$key" "fail" "$(echo "$out" | head -3 | tr '\n' ' ')"
    fi
  else
    record "$key" "pass" "scripts/$script not found (skipped)"
  fi
}

echo "--- Phase 3.5 class-detectable detectors ---"
run_phase35_detector "foreign_host_401_scoping" "check-foreign-host-401-scoping.py" "block" \
  "No 401 dispatch site missing current-account host scoping" "diff"
run_phase35_detector "lcp_acquisition_recursive" "check-lcp-acquisition-recursive.py" "block" \
  "No LCP acquisition predicate inspects only defaultAcquisition.type" "scan"
run_phase35_detector "completion_nil_error_suppression" "check-completion-nil-error-suppression.py" "block" \
  "No completion(nil, title, message) sites suppress consumer alert path" "diff"
run_phase35_detector "nserror_problemdoc_preservation" "check-nserror-problemdoc-preservation.py" "block" \
  "No NSError construction discards in-scope TPPProblemDocument context" "diff"
run_phase35_detector "swiftui_placeholder_a11y" "check-swiftui-placeholder-a11y.py" "warn" \
  "No SwiftUI placeholder/label without .accessibilityLabel" "diff"
run_phase35_detector "notification_center_observer_storage" "check-notification-center-observer-storage.py" "warn" \
  "No NotificationCenter observer registered without storage/removal" "diff"

# 4. Coverage floors
echo "--- Coverage Floors ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "coverage_floors" "pass" "Skipped (--mutation-only)"
elif [ -f scripts/enforce_coverage_floors.py ] && [ -f scripts/coverage-floors.json ]; then
  # Extract coverage from test results
  XCRESULT=$(find ~/Library/Developer/Xcode/DerivedData -name "*.xcresult" -newer /tmp/.verify-pr-start 2>/dev/null | head -1)
  if [ -n "$XCRESULT" ]; then
    COV_OUTPUT=$(python3 scripts/enforce_coverage_floors.py --baseline-only 2>&1 || true)
    if echo "$COV_OUTPUT" | grep -q "VIOLATED"; then
      record "coverage_floors" "fail" "Coverage below module thresholds"
    else
      record "coverage_floors" "pass" "All module floors met"
    fi
  else
    record "coverage_floors" "pass" "No xcresult found (skipped)"
  fi
else
  record "coverage_floors" "pass" "Coverage enforcement not configured (skipped)"
fi

# 5. Mutation testing
# Policy:
#   --quick (no --mutation-only)  → skipped entirely
#   --mutation-only               → runs even if --quick was also passed
#   default policy                → critical paths strict (50%), others advisory
#   --enforce-mutations           → ALL changed files strict
#   --no-enforce-mutations        → ALL changed files advisory (incl. critical)
#   --mutation-min-kill-rate N    → override the 50% floor
#
#   palace_mutate.py uses .forgeos/mutation-cache by default — repeat verify
#   runs on the same files are near-instant (cache hit).
#
# Per-file per-run JSON reports land at .forgeos/mutation-reports/<slug>.json
# so the CI workflow can post a comment with the table; the script writes them
# alongside the aggregated decision so locally you also have the raw data.
echo "--- Mutation Testing ---"
MUTATION_REPORTS_DIR=".forgeos/mutation-reports"
if [ "$QUICK" = "true" ] && [ "$MUTATION_ONLY" != "true" ]; then
  record "mutation" "pass" "Skipped (--quick mode)"
elif [ -f scripts/palace_mutate.py ] && [ -n "$CHANGED_SWIFT" ]; then
  TOTAL_KILLED=0
  TOTAL_MUTATIONS=0
  STRICT_FAIL_FILES=()  # strict policy applies AND kill rate < min
  WARN_FILES=()         # kill rate < min but advisory only
  # Critical-path files with >=1 surviving consequential mutant. These are a
  # STRICT FAIL regardless of kill rate or MUTATION_POLICY — a 100%-on-paper
  # kill rate cannot mask a surviving consequential mutant on a user-money path.
  CRITICAL_SURVIVOR_FILES=()
  MUTATION_HARD_FAILED=false
  mkdir -p "$MUTATION_REPORTS_DIR"

  # Diff-scoped by default for the PR gate; --mutation-whole-file opts into a
  # full-file scan (release runs). palace_mutate.py caches diff-only and
  # whole-file runs under independent keys, so switching modes is safe.
  MUTATION_SCOPE_ARGS=()
  if [ "$MUTATION_WHOLE_FILE" = "true" ]; then
    echo "  Mutation scope: WHOLE FILE (--mutation-whole-file)"
  else
    MUTATION_SCOPE_ARGS+=("--diff-only")
    echo "  Mutation scope: diff-only vs $BASE (default; pass --mutation-whole-file for full-file)"
  fi

  while IFS= read -r swift_file; do
    [ -z "$swift_file" ] && continue
    # Skip non-production files
    echo "$swift_file" | grep -qE 'Tests/|Mocks/|Config/' && continue

    # Per-file strictness — resolved from MUTATION_POLICY + critical-path match.
    IS_STRICT=false
    case "$MUTATION_POLICY" in
      enforce_all)  IS_STRICT=true ;;
      advisory_all) IS_STRICT=false ;;
      default)
        if echo "$swift_file" | grep -qE "$CRITICAL_MUTATION_PATHS_REGEX"; then
          IS_STRICT=true
        fi
        ;;
    esac

    # Resolve XCTestCase class selectors for this production file.
    # The old logic passed a directory path (e.g. `PalaceTests/Book`) to
    # `-only-testing:`, which silently matched zero classes — every mutant
    # graded as SURVIVED against an empty test set, and the gate "passed"
    # with no kill rate. resolve-tests-for.py emits proper
    # `PalaceTests/<ClassName>` selectors, one per line.
    if ! TEST_SELECTORS=$(python3 scripts/resolve-tests-for.py "$swift_file" 2>/dev/null); then
      echo "  [SKIP] no test selectors resolved for $swift_file — file has no matching *Tests.swift"
      continue
    fi

    # Per-file JSON report so post-mutation-pr-comment.py can render the table.
    SLUG=$(echo "$swift_file" | tr '/' '_' | sed 's/\.swift$//')
    REPORT_PATH="$MUTATION_REPORTS_DIR/$SLUG.json"

    # Build --tests arg list (one --tests per class — palace_mutate uses
    # action="append" on --tests).
    MUTATE_TEST_ARGS=()
    while IFS= read -r sel; do
      [ -z "$sel" ] && continue
      MUTATE_TEST_ARGS+=("--tests" "$sel")
    done <<< "$TEST_SELECTORS"

    # ${arr[@]+"${arr[@]}"} guards against `set -u` "unbound variable" when the
    # scope array is empty (whole-file mode) on bash 3.2 (macOS default).
    MUT_OUTPUT=$(python3 scripts/palace_mutate.py \
      --file "$swift_file" \
      "${MUTATE_TEST_ARGS[@]}" \
      ${MUTATION_SCOPE_ARGS[@]+"${MUTATION_SCOPE_ARGS[@]}"} \
      --report "$REPORT_PATH" \
      --max-mutations 10 2>&1)
    MUT_EXIT=$?

    # palace_mutate exit codes:
    #   0 — all mutations ran, kill rate ≥ 50% (or none generated)
    #   1 — all mutations ran, kill rate < 50% (advisory floor)
    #   2 — script error (file not found, baseline failed, etc.) — surface loudly
    # Previously this was wrapped in `|| true` which swallowed exit 2 silently,
    # which let the hardcoded-REPO_ROOT bug ship to CI undetected. We now
    # treat 2 as a hard error so it can never masquerade as a clean pass again.
    if [ "$MUT_EXIT" -ge 2 ]; then
      echo "$MUT_OUTPUT" | tail -20
      record "mutation" "fail" "palace_mutate.py errored on $swift_file (exit $MUT_EXIT) — see log above"
      MUTATION_HARD_FAILED=true
      break
    fi

    # palace_mutate.py emits "killed: N  survived: N  errored: N  kill rate: P%"
    # in both fresh-run and CACHED branches. Parse from that line.
    KILLED=$(echo "$MUT_OUTPUT" | grep -oE 'killed: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "0")
    SURVIVED=$(echo "$MUT_OUTPUT" | grep -oE 'survived: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "0")
    FILE_TOTAL=$((KILLED + SURVIVED))
    TOTAL_KILLED=$((TOTAL_KILLED + KILLED))
    TOTAL_MUTATIONS=$((TOTAL_MUTATIONS + FILE_TOTAL))

    # Critical-path survivor override. Read summary.critical_path_survivors from
    # the per-file JSON report. >0 means a SURVIVED mutant with a consequential
    # op (cmp/bool/bound/retval/cond) on a user-money path — a STRICT FAIL even
    # if the kill rate clears the floor. We read from the report (not the printed
    # line) because the survivor count is a report-only field. Default to 0 when
    # the key is absent (older cached reports) so this never blocks spuriously.
    CP_SURVIVORS=0
    CP_SURVIVOR_LINES=""
    if [ -f "$REPORT_PATH" ]; then
      CP_PARSED=$(python3 - "$REPORT_PATH" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("0|")
    sys.exit(0)
summary = data.get("summary", {}) or {}
n = int(summary.get("critical_path_survivors", 0) or 0)
# Collect the line numbers of surviving consequential mutants for the message.
# A survivor on a non-assign op is what critical_path_survivors counts; surface
# every SURVIVED result's line so the reviewer can find them (the report itself
# is the authority on which were consequential).
lines = sorted({
    str((r.get("mutation") or {}).get("line"))
    for r in (data.get("results") or [])
    if r.get("status") == "survived"
    and (r.get("mutation") or {}).get("line") is not None
})
print(f"{n}|{','.join(lines)}")
PYEOF
)
      CP_SURVIVORS=$(echo "$CP_PARSED" | cut -d'|' -f1)
      CP_SURVIVOR_LINES=$(echo "$CP_PARSED" | cut -d'|' -f2)
      [ -z "$CP_SURVIVORS" ] && CP_SURVIVORS=0
    fi
    if [ "${CP_SURVIVORS:-0}" -gt 0 ]; then
      if [ -n "$CP_SURVIVOR_LINES" ]; then
        CRITICAL_SURVIVOR_FILES+=("$swift_file (${CP_SURVIVORS} consequential survivor(s) at line(s) ${CP_SURVIVOR_LINES})")
      else
        CRITICAL_SURVIVOR_FILES+=("$swift_file (${CP_SURVIVORS} consequential survivor(s))")
      fi
    fi

    # Per-file policy evaluation against the (possibly overridden) floor.
    if [ "$FILE_TOTAL" -gt 0 ]; then
      FILE_RATE=$((KILLED * 100 / FILE_TOTAL))
      if [ "$FILE_RATE" -lt "$MUTATION_MIN_KILL_RATE" ]; then
        if [ "$IS_STRICT" = "true" ]; then
          STRICT_FAIL_FILES+=("$swift_file (${FILE_RATE}%)")
        else
          WARN_FILES+=("$swift_file (${FILE_RATE}%)")
        fi
      fi
    fi
  done <<< "$CHANGED_SWIFT"

  if [ "$MUTATION_HARD_FAILED" = "true" ]; then
    : # fail already recorded inside the loop; skip the post-aggregation record
  elif [ ${#CRITICAL_SURVIVOR_FILES[@]} -gt 0 ]; then
    # Critical-path survivor override: this takes priority over the kill-rate
    # decision. A surviving consequential mutant on a user-money path blocks
    # merge even if the kill rate clears the floor. We still surface any
    # kill-rate strict failures alongside so the reviewer sees the full picture.
    DETAIL="${#CRITICAL_SURVIVOR_FILES[@]} critical-path file(s) with surviving consequential mutant(s) — BLOCKS regardless of kill rate: ${CRITICAL_SURVIVOR_FILES[*]}"
    if [ ${#STRICT_FAIL_FILES[@]} -gt 0 ]; then
      DETAIL="$DETAIL || also below ${MUTATION_MIN_KILL_RATE}%: ${STRICT_FAIL_FILES[*]}"
    fi
    record "mutation" "fail" "$DETAIL"
  elif [ "$TOTAL_MUTATIONS" -eq 0 ]; then
    # Defensive: if zero mutations across ≥3 production files, that's
    # almost certainly a tool misconfiguration, not a genuine no-op diff.
    # Most real production files have at least one comparison/boolean op.
    #
    # EXCEPTION: in diff-only mode (the default PR gate), zero mutations across
    # the diff is legitimate — a PR can change only comments, whitespace, log
    # lines, or already-uncovered lines. Don't treat that as misconfiguration;
    # whole-file mode keeps the strict "≥3 files but 0 mutants is suspicious" net.
    PROD_COUNT=$(echo "$CHANGED_SWIFT" | grep -cv '^$' || echo "0")
    if [ "${PROD_COUNT:-0}" -ge 3 ] && [ "$MUTATION_WHOLE_FILE" = "true" ]; then
      record "mutation" "fail" "Suspicious: $PROD_COUNT production files changed but 0 mutations generated total — palace_mutate.py likely misconfigured (check REPO_ROOT, file paths, and exit codes)"
    elif [ "$MUTATION_WHOLE_FILE" = "true" ]; then
      record "mutation" "pass" "No mutations generated for changed files"
    else
      record "mutation" "pass" "No mutations generated for changed lines (diff-only scope)"
    fi
  elif [ ${#STRICT_FAIL_FILES[@]} -gt 0 ]; then
    KILL_RATE=$((TOTAL_KILLED * 100 / TOTAL_MUTATIONS))
    DETAIL="${KILL_RATE}% aggregate; ${#STRICT_FAIL_FILES[@]} strict-path file(s) below ${MUTATION_MIN_KILL_RATE}%: ${STRICT_FAIL_FILES[*]}"
    record "mutation" "fail" "$DETAIL"
  else
    KILL_RATE=$((TOTAL_KILLED * 100 / TOTAL_MUTATIONS))
    if [ ${#WARN_FILES[@]} -gt 0 ]; then
      DETAIL="${TOTAL_KILLED}/${TOTAL_MUTATIONS} killed (${KILL_RATE}%); advisory files <${MUTATION_MIN_KILL_RATE}%: ${WARN_FILES[*]}"
    else
      DETAIL="${TOTAL_KILLED}/${TOTAL_MUTATIONS} killed (${KILL_RATE}%)"
    fi
    record "mutation" "pass" "$DETAIL"
  fi
else
  record "mutation" "pass" "No production Swift files changed (skipped)"
fi

# 5b. Audiobook cross-vendor smoke (if audiobook files changed)
# When any Palace/Audiobooks/ or ios-audiobooktoolkit/ file changes, run the
# four-case smoke test (LCP / BearerToken / OpenAccess / LocalFile) that pins
# the cross-vendor adapter contract. Skipped otherwise so non-audiobook PRs
# don't eat the build/run cost. The gate fails if any smoke case fails — the
# audiobook toolkit overhaul (PR #990 → F-011) is the historical reason this
# gate exists: a vendor adapter regression slipped through because there was
# no smoke net for "did the four adapters at least load and emit a session?"
#
# The test class lives in PalaceTests (owned by Module B of swarm_eefef87a).
# We reference it as a -only-testing string, not a Swift import, so the gate
# is robust if the file lands on develop before Module B's PR merges.
echo "--- Audiobook Cross-Vendor Smoke ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "audiobook_smoke" "pass" "Skipped (--mutation-only)"
else
  AUDIOBOOK_CHANGED=$(echo "$ALL_CHANGED" | grep -E '^Palace/Audiobooks/|^ios-audiobooktoolkit/' || true)
  if [ -z "$AUDIOBOOK_CHANGED" ]; then
    record "audiobook_smoke" "pass" "Skipped (no audiobook files changed)"
  else
    SMOKE_OUTPUT=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
      -destination "id=$SIM_ID" \
      -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test 2>&1 || true)
    # Same rollup parsing as the main unit-tests step — one Executed line per
    # bundle rollup, count failures from the trailing "N failure(s)" token.
    SMOKE_ROLLUP=$(echo "$SMOKE_OUTPUT" | grep -A1 "Test Suite '\(All tests\|Selected tests\)' \(passed\|failed\)")
    SMOKE_PASS=$(echo "$SMOKE_ROLLUP" | grep -o 'Executed [0-9]* tests\?' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
    SMOKE_FAIL=$(echo "$SMOKE_ROLLUP" | grep -oE '[0-9]+ failures? \(' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
    if [ "${SMOKE_FAIL:-0}" -eq 0 ] && [ "${SMOKE_PASS:-0}" -gt 0 ]; then
      record "audiobook_smoke" "pass" "${SMOKE_PASS} smoke case(s), 0 failures"
    elif [ "${SMOKE_PASS:-0}" -eq 0 ]; then
      # Zero executed with audiobook files changed = misconfiguration (the
      # smoke test class may not have landed yet, or -only-testing matched
      # zero classes). Fail loudly rather than silently rubber-stamp.
      record "audiobook_smoke" "fail" "0 smoke cases executed — AudiobookCrossVendorSmokeTests class missing or unbuilt"
    else
      record "audiobook_smoke" "fail" "${SMOKE_PASS} smoke case(s), ${SMOKE_FAIL} failure(s)"
    fi
  fi
fi

# 6. Accessibility audit (if UI files changed)
echo "--- Accessibility ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "accessibility" "pass" "Skipped (--mutation-only)"
elif [ -n "$CHANGED_UI" ]; then
  # Check for missing accessibility identifiers in changed UI files
  A11Y_ISSUES=0
  while IFS= read -r ui_file; do
    [ -z "$ui_file" ] && continue
    [ ! -f "$ui_file" ] && continue
    # Check for Button/Image without accessibilityIdentifier or accessibilityLabel.
    # Use a word-boundary regex on `Button(` so we don't substring-match
    # method names like `removeProcessingButton(` on a ViewModel call site
    # (see feedback_verify_pr_false_positives.md).
    HAS_BUTTON=$(grep -cE '(^|[^A-Za-z0-9_])(UIButton|Button)\(' "$ui_file" 2>/dev/null || true)
    HAS_A11Y=$(grep -c 'accessibilityIdentifier\|accessibilityLabel\|isAccessibilityElement' "$ui_file" 2>/dev/null || true)
    if [ "${HAS_BUTTON:-0}" -gt 0 ] && [ "${HAS_A11Y:-0}" -eq 0 ]; then
      A11Y_ISSUES=$((A11Y_ISSUES + 1))
    fi
  done <<< "$CHANGED_UI"
  if [ "$A11Y_ISSUES" -eq 0 ]; then
    record "accessibility" "pass" "UI files have accessibility annotations"
  else
    record "accessibility" "fail" "$A11Y_ISSUES UI files missing accessibility annotations"
  fi
else
  record "accessibility" "pass" "No UI files changed (skipped)"
fi

# 6b. Ledger PR-drift check — flags contracts whose source files changed
#     in this PR but whose contract markdown was not updated. Catches
#     "you edited the code, you should reflect it in the contract."
#     Strict on critical-path contracts (Audiobooks / SignInLogic /
#     MyBooks/Download* / DNA-marked), warns elsewhere. Honors
#     [skip-ledger-check] in commit messages for typo/refactor PRs.
echo "--- Ledger PR Drift ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "ledger_pr_drift" "pass" "Skipped (--mutation-only)"
elif [ ! -x scripts/ledger-pr-check.py ] || [ ! -d docs/ledger ]; then
  record "ledger_pr_drift" "pass" "Ledger PR-drift check not available (skipped)"
else
  LEDGER_PR_OUT=$(scripts/ledger-pr-check.py "$BASE" 2>&1 || true)
  if echo "$LEDGER_PR_OUT" | grep -q "^✓ ledger pr-drift clean"; then
    record "ledger_pr_drift" "pass" "No contract drift in this PR"
  elif echo "$LEDGER_PR_OUT" | grep -q "^\[STRICT\]"; then
    # Strict drift on a critical-path contract — record as fail.
    STRICT_COUNT=$(echo "$LEDGER_PR_OUT" | grep -oE '\[STRICT\] [0-9]+' | grep -oE '[0-9]+' || echo "?")
    record "ledger_pr_drift" "fail" "${STRICT_COUNT} critical-path contract(s) drifted — see scripts/ledger-pr-check.py output"
  else
    # Non-critical drift — warn but pass.
    WARN_COUNT=$(echo "$LEDGER_PR_OUT" | grep -oE '\[WARN\] [0-9]+' | grep -oE '[0-9]+' || echo "?")
    record "ledger_pr_drift" "pass" "${WARN_COUNT} non-critical contract drift finding(s) (warning)"
  fi
fi

# 7. simdrive replay (opt-in via --simdrive). Delegates to scripts/simdrive-regress.sh
#    which enforces the two-tier gate (stateless = blocking on drift, stateful = smoke).
echo "--- simdrive Replay ---"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "simdrive" "pass" "Skipped (--mutation-only)"
elif [ "$SIMDRIVE" != "true" ]; then
  record "simdrive" "pass" "Skipped (pass --simdrive to enable)"
elif [ ! -x scripts/simdrive-regress.sh ]; then
  record "simdrive" "fail" "scripts/simdrive-regress.sh missing or not executable"
elif ! python3 -c 'import simdrive' >/dev/null 2>&1; then
  record "simdrive" "fail" "simdrive package not installed (pip3 install --pre simdrive)"
else
  SIMDRIVE_REPORT=$(mktemp)
  if SIMDRIVE_SIM_ID="$SIM_ID" scripts/simdrive-regress.sh --tier stateless --report "$SIMDRIVE_REPORT" >/dev/null 2>&1; then
    SD_PASS=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('pass_count', 0))" 2>/dev/null || echo 0)
    record "simdrive" "pass" "${SD_PASS} stateless journey(s) clean"
  else
    SD_FAIL=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('fail_count', 0))" 2>/dev/null || echo "?")
    SD_PASS=$(python3 -c "import json; print(json.load(open('$SIMDRIVE_REPORT')).get('pass_count', 0))" 2>/dev/null || echo 0)
    record "simdrive" "fail" "${SD_FAIL} stateless journey(s) drifted (${SD_PASS} clean) — see ${SIMDRIVE_REPORT}"
  fi
fi

# 8. FR↔Tests coverage matrix integrity (skipped if harness not installed —
#    the matrix is maintained by the optional harness governance layer; outside
#    contributors aren't blocked by its absence).
#
# Presence-probe: `harness srd --help` lists subcommands (exit 0 always,
# regardless of matrix state). Don't probe with `srd coverage --json` exit
# code — that returns 1 when the matrix is dirty (the case this step is
# meant to catch), which would falsely route to "skipped".
echo "--- Coverage by FR ---"
HARNESS_BIN="$HOME/harness/bin/harness"
if [ "$MUTATION_ONLY" = "true" ]; then
  record "coverage_by_fr" "pass" "Skipped (--mutation-only)"
elif [ ! -x "$HARNESS_BIN" ]; then
  record "coverage_by_fr" "pass" "harness not installed (skipped)"
elif ! "$HARNESS_BIN" srd --help 2>&1 | grep -q '\bcoverage\b'; then
  record "coverage_by_fr" "pass" "harness srd coverage subcommand not available (skipped)"
else
  COV_JSON=$("$HARNESS_BIN" srd coverage --json 2>/dev/null)
  COV_GAPS=$(printf '%s' "$COV_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('fr_gaps', [])))" 2>/dev/null || echo "?")
  COV_MISSING=$(printf '%s' "$COV_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('missing_test_areas', [])))" 2>/dev/null || echo "?")
  COV_STALE=$(printf '%s' "$COV_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('fr_stale',[]))+len(d.get('nfr_stale',[])))" 2>/dev/null || echo "?")
  if [ "$COV_GAPS" = "0" ] && [ "$COV_MISSING" = "0" ] && [ "$COV_STALE" = "0" ]; then
    if "$HARNESS_BIN" srd diff --code-vs-narrative --strict >/dev/null 2>&1; then
      record "coverage_by_fr" "pass" "FR↔Tests matrix clean (0 gaps, 0 missing, 0 stale, 0 drift)"
    else
      record "coverage_by_fr" "fail" "FR↔Tests matrix has code-vs-narrative drift > 10% — run: harness srd diff --code-vs-narrative"
    fi
  else
    record "coverage_by_fr" "fail" "FR↔Tests matrix issues — gaps=$COV_GAPS missing=$COV_MISSING stale=$COV_STALE — run: harness srd coverage"
  fi
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"

# Write JSON report if requested
if [ -n "$REPORT_FILE" ]; then
  RESULTS_JSON=$(printf '%s,' "${RESULTS[@]}" | sed 's/,$//')
  cat > "$REPORT_FILE" <<JSONEOF
{
  "branch": "$(git rev-parse --abbrev-ref HEAD)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pass_count": $PASS_COUNT,
  "fail_count": $FAIL_COUNT,
  "unit_tests": {"pass": $TEST_PASS, "fail": $TEST_FAIL},
  "checks": [$RESULTS_JSON]
}
JSONEOF
  echo "  Report written to: $REPORT_FILE"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "BLOCKED: $FAIL_COUNT check(s) failed. Fix before creating PR."
  exit 1
fi

echo ""
echo "CLEAR: All checks passed."
exit 0

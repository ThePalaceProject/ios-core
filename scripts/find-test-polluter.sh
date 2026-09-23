#!/usr/bin/env bash
#
# find-test-polluter.sh — diagnose test-pollution flakes by bisection.
#
# Flaky CI failures in this repo are almost always test pollution: a test that
# passes in isolation but fails in the full suite because an earlier test left
# shared mutable state dirty (`.shared` singletons, AccountsManager() background
# loadCatalogs outliving the test, layout-engine-off-main, keychain/UserDefaults
# bleed). Retry (-retry-tests-on-failure) masks these on the board; this tool
# finds the ACTUAL polluter so it can be fixed at the root.
#
# Strategy:
#   1. Run the VICTIM class alone. If it fails alone, it's a real bug, not
#      pollution — stop and say so.
#   2. If it passes alone, run each SUSPECT class immediately before the victim
#      (`-only-testing:SUSPECT -only-testing:VICTIM`, in that order). The first
#      suspect that makes the victim fail is a polluter — report it.
#
#      `-only-testing` order is NOT a promise of execution order: Palace.xcscheme
#      sets testExecutionOrdering = "random". So the observed order is read back
#      out of the log, and a pair where the victim ran first is reported NOT
#      TESTED rather than acquitted. Parallel testing is pinned off for the same
#      reason — under clones the two classes can land in different processes,
#      where pollution is impossible by construction and every acquittal is
#      vacuous (it also changes the log format to "Test case ... on 'Clone N'").
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT READS ITS OWN LOGS INSTEAD OF THE EXIT CODE
#
# Every verdict below rests on one distinction, and an exit code cannot make it:
#
#     the test ran and failed   ->  a finding
#     the test never ran        ->  no information
#
# Both are "non-zero exit". Reading the exit code alone, a destination failure,
# a build failure, or a class name with a typo in it all produced this tool's
# single most confident sentence — "this is a REAL bug, not pollution, fix the
# test/production code" — and sent the reader off to debug code that was fine.
#
# It did exactly that on 2026-08-26 from a run in which ZERO tests executed. The
# trigger was this script's own default simulator lookup: awk '/Booted/ {print
# $NF}' over `xcrun simctl list devices` returns "(Booted)", because that is the
# last field of the line — not the UDID. After `tr -d '()'` the destination it
# built was the literal id=Booted, which matches no device. That was the DEFAULT
# path, taken whenever a simulator was booted and --sim was omitted.
#
# So a diagnostic that could not tell "failed" from "never ran" was wired to a
# selector that reliably produced "never ran". Both halves are fixed here, and
# the classification half is the one that matters: with classify_run in place, a
# future selection bug can only ever reach an `error:` outcome — reported as
# CANNOT DIAGNOSE — never a verdict about somebody's code.
#
# The same failure shape is documented in xcode-test-optimized.sh (#1419): a run
# that dies before the branch under test executes anything, reports failure with
# no failing assertion, and names a different innocent victim each time.
# ---------------------------------------------------------------------------
#
# Usage:
#   scripts/find-test-polluter.sh --victim AudiobookBookmarkBusinessLogicTests \
#       [--suspects "ClassA ClassB ClassC"] \
#       [--sim <UDID>]
#
#   --victim    Required. The XCTest class that flakes in the full suite.
#   --suspects  Space-separated candidate polluter classes. If omitted, supply
#               the classes that ran BEFORE the victim in the failing run
#               (tests run alphabetically by default, so the polluter is usually
#               alphabetically-earlier and shares a subsystem — auth, audiobook,
#               registry, account).
#   --iterations N
#               How many times to sample each verdict. Default 1.
#
#               EVERY VERDICT THIS TOOL PRINTS RESTS ON N SAMPLES, and its whole
#               input domain is NONDETERMINISTIC failures. At N=1, a victim that
#               fails intermittently ON ITS OWN -- which is the "REAL bug" case,
#               not pollution -- passes step 1 with probability (1-p) and is
#               declared cleared. Each pair then re-samples it once, and the
#               first flip is printed as "polluter is X" about whichever
#               innocent class happened to hold the dice. For p=0.2 over five
#               suspects that is roughly a 54% chance of a confident false
#               accusation. CI runs -test-iterations 3 for exactly this reason.
#
#               A FOUND result is always re-run once to confirm before it is
#               called a polluter; an unreproduced hit is reported as a
#               CANDIDATE. Raise --iterations for a flakier victim.
#
#   --sim       Simulator UDID. Otherwise: $PALACE_TEST_SIMULATOR_ID, then
#               $HARNESS_SESSION_SIM_UDID (so a session that claimed a device
#               keeps it and parallel agents do not collide), then a device the
#               project actually targets, then the first available iPhone.
#
# Exit codes:
#   0  ran cleanly, nothing to report — a bisection happened and cleared
#      every suspect it was given
#   1  a FINDING: the victim fails alone, or a polluter was identified
#   2  usage error
#   3  no usable verdict — either the run could not produce one at all, or it
#      ran and some suspects could not be tested (INCOMPLETE). The output says
#      which; an INCOMPLETE run DID clear the suspects it actually tested.

set -uo pipefail

PROJECT="Palace.xcodeproj"
SCHEME="Palace"
# Substitutable so the reporting paths below can be exercised end-to-end without
# Xcode (the tooling-checks runner is Linux). Production default is the real one.
XCB="${PALACE_XCODEBUILD:-xcodebuild}"
VICTIM=""
SUSPECTS=""
SIM_UDID=""
ITERATIONS=1

# `$2` under `set -u` with a flag in last position aborts with "unbound
# variable" and exit 1 -- which this script documents as "a FINDING". A wrapper
# would read a typo as a polluter identification.
need_value() {
  [ "$1" -ge 2 ] || { echo "ERROR: $2 requires a value." >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --victim)     need_value $# "$1"; VICTIM="$2"; shift 2 ;;
    --suspects)   need_value $# "$1"; SUSPECTS="$2"; shift 2 ;;
    --sim)        need_value $# "$1"; SIM_UDID="$2"; shift 2 ;;
    --iterations) need_value $# "$1"; ITERATIONS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# (1) An unvalidated count is a silent skip, not a bad number. `seq 1 abc`
# fails, the isolation loop never runs, VERDICT stays empty, and step 1's case
# falls through into step 2 -- so a victim that fails EVERY run gets reported as
# a polluter, and the confirmation run confirms it by re-sampling the same
# broken victim. That is this script's headline defect, reintroduced by the
# remedy for the sampling defect.
if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --iterations must be a positive integer (got '$ITERATIONS')." >&2
  exit 2
fi

if [ -z "$VICTIM" ]; then
  echo "ERROR: --victim <TestClass> is required." >&2
  exit 2
fi

# Class names go into a `-only-testing:` selector, a grep -E pattern, and a
# filename. A name outside this set breaks at least one of those silently: a `/`
# makes the log path unwritable (reported as an empty log, pointing at a file
# that does not exist), and a regex metacharacter quietly changes what the
# attribution greps match.
valid_class_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

if ! valid_class_name "$VICTIM"; then
  echo "ERROR: --victim '$VICTIM' is not a plain class name ([A-Za-z0-9_]+)." >&2
  exit 2
fi

# ONE definition of "this log carries per-case lines". It was spelled four
# different ways — `(passed|failed)` in two places, a started/passed/failed
# variant in a third, and a bare `Test Case '-[X ` grep in order_state — and
# that is why a round-8 guard re-opened a round-2 fix: a log of nothing but
# `skipped` lines satisfied "no per-case lines", which suppressed the
# focus-absence check and acquitted the pair at exit 0.
#
# `skipped` belongs here precisely because a skipped victim is the pollution
# symptom this tool exists to catch: pollution that wipes shared account state
# makes a victim XCTSkip, and a skip is not a pass.
has_per_case_lines() {
  grep -qE "^Test Case '.*' (started\.|passed|failed|skipped)" "$1"
}

# >>> classify_run BEGIN
# Classify a completed test run from its LOG, not its exit status.
#
#   classify_run <exit_code> <log> [focus_class]
#
# Echoes exactly one of:
#   pass          — tests executed and none failed
#   test-failure  — the FOCUS class had a named failing case
#   error:<why>   — the run produced no attributable verdict
#
# `focus_class` is what makes step 2 sound. A pair run executes SUSPECT and
# VICTIM together, so "some test failed" is not "the victim failed" — without a
# focus, a suspect whose OWN test is broken reads as a polluter, and the tool
# announces "SuspectB leaves shared state dirty that breaks VictimTests" from a
# log in which the victim passed. That is this script's original defect wearing
# a different hat, so the focus is required wherever a verdict is drawn.
#
# The error: arm is the whole point. A caller must never turn it into a
# statement about the code under test.
classify_run() {
  local exit_code="$1" log="$2" focus="${3:-}"

  if [ ! -s "$log" ]; then
    echo "never-ran:empty-log"
    return 0
  fi

  # FACT 1 — did anything execute? OBSERVED, never inferred from which message
  # happened to appear. Two independent signals, because the per-case lines can
  # be suppressed by output formatting while the rollup survives.
  local executed_cases started_cases rollup_nonzero ran
  executed_cases=$(grep -cE "^Test Case '.*' (passed|failed)" "$log" 2>/dev/null || true)
  # A case that STARTED executed, even if it never completed -- which is exactly
  # the shape of a crash or hang mid-test. Counting only completions classified
  # those as "never ran", which is false and, worse, dropped the "a hang can
  # itself be the pollution symptom" lead that the ran: sibling carries.
  started_cases=$(grep -cE "^Test Case '.*' started\." "$log" 2>/dev/null || true)
  rollup_nonzero=$(grep -cE "Executed [1-9][0-9]* test" "$log" 2>/dev/null || true)
  if [ "${executed_cases:-0}" -gt 0 ] || [ "${started_cases:-0}" -gt 0 ] \
     || [ "${rollup_nonzero:-0}" -gt 0 ]; then
    ran="ran"
  else
    ran="never-ran"
  fi

  # FACT 2 — why. This precedence chooses the MESSAGE only. It cannot move a
  # run between buckets, because the bucket is decided by FACT 1 above.
  #
  # Collapsing these two facts into one token is what made the ordering of these
  # greps load-bearing, and it was wrong in both directions across two rounds:
  # first a launch crash reported as "the pair ran", then a pair that DID run
  # reported as "never ran" because a destination error appeared later in its
  # log. Neither is an ordering problem once the facts are separate.
  local reason=""
  if grep -qE "error: Unable to find a device matching|Unsupported destination specifier|does not match any of the available destinations" "$log"; then
    reason="destination-not-found"
  elif grep -qE "\*\* BUILD FAILED \*\*|The following build commands failed|error: Build input file cannot be found" "$log"; then
    reason="build-failed"
  elif grep -qE "Restarting after unexpected exit, crash, or test timeout|exceeded execution time allowance" "$log"; then
    reason="timeout-or-restart"
  fi

  if [ "$ran" = "never-ran" ]; then
    # No reason found means the selectors simply matched nothing. That is a
    # DIFFERENT thing from a runner that died at launch, and the two used to
    # share a label whose guidance ("check the class name") is a false positive
    # for the second.
    [ -z "$reason" ] && reason="no-tests-matched"
    echo "never-ran:$reason"
    return 0
  fi

  # Tests executed. A launch-level reason found alongside that means the run
  # started, produced results, and then something broke — unjudgeable, but not
  # "never ran".
  if [ -n "$reason" ]; then
    echo "ran:$reason"
    return 0
  fi

  # The FOCUS must itself have executed, or a `pass` is a statement about the
  # run rather than about the victim. `XCTSkip` appears 127x in PalaceTests, and
  # pollution that wipes shared account state makes a victim SKIP rather than
  # fail — emitting no failing line.
  local any_failed=0 focus_failed=0 case_lines=0
  grep -qE "^Test Case '.*' failed" "$log" && any_failed=1
  grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failure" "$log" && any_failed=1
  has_per_case_lines "$log" && case_lines=1

  # Only conclude the focus did not run when the log CARRIES per-case lines. If
  # the output format suppressed them, the rollup still proves tests executed
  # but says nothing about which — asserting the victim was absent there would
  # be a claim the log cannot support.
  if [ -n "$focus" ] && [ "$case_lines" -eq 1 ] && \
     ! grep -qE "^Test Case '-\[([A-Za-z0-9_]+\.)?${focus} [^]]*\]' (passed|failed)" "$log"; then
    echo "ran:focus-did-not-run"
    return 0
  fi
  if [ -n "$focus" ] && \
     grep -qE "^Test Case '-\[([A-Za-z0-9_]+\.)?${focus} [^]]*\]' failed" "$log"; then
    focus_failed=1
  fi

  if [ "$focus_failed" -eq 1 ]; then
    echo "ran:test-failure"
    return 0
  fi

  if [ "$any_failed" -eq 1 ]; then
    if [ -z "$focus" ]; then
      echo "ran:test-failure"
    elif [ "$case_lines" -eq 1 ]; then
      echo "ran:other-class-failed"
    else
      echo "ran:unattributed-failure"
    fi
    return 0
  fi

  if [ "$exit_code" -eq 0 ]; then
    echo "ran:pass"
    return 0
  fi

  echo "ran:unexplained-exit-${exit_code}"
}
# <<< classify_run END

# Resolve a simulator using the same precedence as xcode-test-optimized.sh: an
# explicit id wins, then a session-allocated device (so concurrent agents do not
# collide), then a device the project targets, then first available.
resolve_simulator() {
  local candidate="${SIM_UDID:-${PALACE_TEST_SIMULATOR_ID:-${HARNESS_SESSION_SIM_UDID:-}}}"
  if [ -n "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  local destinations
  destinations=$("$XCB" -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | grep "platform:iOS Simulator" | grep "iPhone" | grep -v "error:")

  local preferred found
  for preferred in "iPhone 16 Pro" "iPhone 17 Pro" "iPhone 16" "iPhone 17"; do
    found=$(printf '%s\n' "$destinations" | grep -F "name:$preferred " | head -1 | sed 's/.*id:\([^,]*\).*/\1/')
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
  done

  printf '%s' "$(printf '%s\n' "$destinations" | head -1 | sed 's/.*id:\([^,]*\).*/\1/')"
}

# All input validation happens BEFORE anything is created or run: a usage error
# should cost nothing and leave nothing behind.
# Word splitting with globbing disabled. `read -ra` was tried here and reads only
# ONE LINE, so a newline-separated list silently lost every entry after the first
# and printed "no polluter found" over the survivors; plain `for s in $SUSPECTS`
# handles newlines but also expands `*Tests*` against the filesystem. `set -f`
# plus word splitting is the combination that does neither.
SUSPECT_LIST=()
set -f
IFS=$' \t\n'
SUSPECT_LIST=($SUSPECTS)
set +f
IFS=$' \t\n'

# Same validation as --victim. A suspect name reaches a grep -E pattern and a
# filename too, so `*Tests*` (which no longer globs, but is still not a class)
# would otherwise reach grep as `repetition-operator operand invalid` and be
# classified as an unreadable run rather than as the input error it is.
# `--suspects "   "` passed a bare `-z` test, iterated zero times, and printed
# "no polluter found among the given suspects" at exit 0 -- a clean sweep over
# nothing. Reachable whenever the list comes from a command substitution that
# returned whitespace, which is also how newlines arrive.
if [ ${#SUSPECT_LIST[@]} -eq 0 ] && [ -n "$SUSPECTS" ]; then
  echo "ERROR: --suspects contained no class names (got whitespace only)." >&2
  echo "       Nothing was tested; this is not a clean result." >&2
  exit 2
fi

for s in ${SUSPECT_LIST[@]+"${SUSPECT_LIST[@]}"}; do
  if ! valid_class_name "$s"; then
    echo "ERROR: --suspects entry '$s' is not a plain class name ([A-Za-z0-9_]+)." >&2
    echo "       Nothing was tested; this is not a clean result." >&2
    exit 2
  fi
done

SIM_UDID=$(resolve_simulator)
if [ -z "$SIM_UDID" ]; then
  echo "ERROR: no simulator found; pass --sim <UDID>." >&2
  exit 3
fi
echo "Simulator: $SIM_UDID"

# Explicit path rather than `mktemp -t`: BSD and GNU disagree on what `-t`
# means, and on macOS it ignored TMPDIR outright, so the tests could not contain
# the dirs the script deliberately retains.
DD=$(mktemp -d "${TMPDIR:-/tmp}/polluter-dd.XXXXXX")
# Per-run log dir. The old fixed /tmp/polluter-run.log meant two concurrent
# invocations overwrote each other's evidence, so a verdict could be read from
# another run's log.
LOGDIR=$(mktemp -d "${TMPDIR:-/tmp}/polluter-log.XXXXXX")
LAST_LOG=""
STEP2_RAN=0

# The logs are evidence, so they outlive the run — but only when there is
# something to read. A clean run has nothing to investigate, and keeping its
# logs unconditionally leaked a temp dir per invocation (107 of them had
# accumulated on one machine before this was noticed).
cleanup() {
  local rc=$?
  rm -rf "$DD"
  # Keep them when step 2 ran: a clean "no polluter found" is the result that
  # sends the reader back to widen the suspect list, and the logs are what
  # they need to see why.
  [ "$rc" -eq 0 ] && [ "$STEP2_RAN" -eq 0 ] && rm -rf "$LOGDIR"
  return $rc
}
trap cleanup EXIT

# One definition of where a run's log lives, used both by the subshell that
# writes it and by the parent that reports it.
#
# `VERDICT=$(run_tests ...)` executes in a SUBSHELL, so a LAST_LOG assignment
# made inside run_tests is discarded when it returns. The script used to do
# exactly that and then printed a log path that did not exist — a diagnostic
# pointing at nothing. No unit test saw it; the first real end-to-end run did.
log_for() { printf '%s' "$LOGDIR/$1.log"; }

# Runs the given -only-testing selectors and echoes the classification.
run_tests() {
  local label="$1"; shift
  local args=()
  local sel
  for sel in "$@"; do args+=(-only-testing:"PalaceTests/$sel"); done
  echo "  -> $label: ${args[*]}" >&2
  local out; out=$(log_for "$label")
  "$XCB" test \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DD" \
    -parallel-testing-enabled NO \
    "${args[@]}" >"$out" 2>&1
  local code=$?
  classify_run "$code" "$out" "$VICTIM"
}

# >>> pair_outcome BEGIN
# THE DECISION TABLE, over classify_run's TWO facts x order_state's four states.
#
# `classify_run` returns `<ran|never-ran>:<reason>`. Field 1 decides the bucket;
# field 2 only chooses the message. Collapsing them into one token is what made
# the ORDER of the classifier's greps load-bearing, and that was wrong in both
# directions across two rounds: first a runner dying at launch reported as "the
# pair ran", then a pair that DID run reported as "never ran" because a
# destination error appeared later in its log. Neither is an ordering problem
# once the facts are separate.
#
#   ran:pass         | ok -> acquitted | wrong-order/absent -> inconclusive-*
#   ran:test-failure | ok -> flip      | wrong-order/absent -> inconclusive-*
#   ran:focus-did-not-run              -> inconclusive-victim-absent
#   ran:<anything else>                -> inconclusive-ran-unjudgeable
#   never-ran:<any reason>             -> no-result
#
# `inconclusive-*` and `no-result` are DIFFERENT buckets on purpose: one ran and
# could not be judged, the other did not run. Folding them together is how "ran
# but could not be judged" ended up printed under the words "never ran".
pair_outcome() {
  local verdict="$1" order="$2"
  local ran="${verdict%%:*}" reason="${verdict#*:}"

  # FACT 1 decides the bucket. Nothing about WHY can move a run that executed
  # into "never ran", or vice versa — which is the whole reason the two facts
  # are carried separately.
  if [ "$ran" = "never-ran" ]; then
    echo "no-result"
    return 0
  fi

  case "$reason" in
    pass)
      case "$order" in
        ok)             echo "acquitted" ;;
        wrong-order)    echo "inconclusive-order" ;;
        first-absent)   echo "inconclusive-suspect-absent" ;;
        second-absent)  echo "inconclusive-victim-absent" ;;
        order-unobservable)
                        echo "inconclusive-ran-unjudgeable" ;;
        *)              echo "inconclusive-ran-unjudgeable" ;;
      esac ;;
    test-failure)
      case "$order" in
        ok)             echo "flip" ;;
        wrong-order)    echo "inconclusive-order" ;;
        first-absent)   echo "inconclusive-suspect-absent" ;;
        second-absent)  echo "inconclusive-victim-absent" ;;
        order-unobservable)
                        echo "inconclusive-ran-unjudgeable" ;;
        *)              echo "inconclusive-ran-unjudgeable" ;;
      esac ;;
    focus-did-not-run)
      echo "inconclusive-victim-absent" ;;
    *)
      # Ran, and could not be judged: other-class-failed, unattributed-failure,
      # timeout-or-restart, unexplained-exit-N, and anything added later. Fails
      # toward "we cannot say" rather than inheriting a verdict.
      echo "inconclusive-ran-unjudgeable" ;;
  esac
}
# <<< pair_outcome END

# WHICH of first/second ran, and in what order? The entire method rests on the
# suspect running BEFORE the victim, and `Palace.xcscheme` sets
# testExecutionOrdering = "random", so `-only-testing` order is NOT a guarantee
# of execution order. If the victim ran first it cannot have been polluted by
# the suspect, and "victim still passes" would be a false acquittal. Execution
# order is right there in the log, so it is observed rather than assumed.
order_state() {
  local log="$1" first="$2" second="$3" line_first line_second
  # The suspect's LAST line must precede the victim's FIRST. That is what
  # pollution actually requires -- the suspect finished dirtying shared state
  # before the victim started reading it -- and unlike first-vs-first it stays
  # meaningful if the two ever interleave. With parallel testing pinned off
  # XCTest runs suites contiguously, so today the two readings agree; this rule
  # is the one that remains correct if that ever stops being true.
  line_first=$(grep -nE "^Test Case '-\[([A-Za-z0-9_]+\.)?${first} " "$log" | tail -1 | cut -d: -f1)
  line_second=$(grep -nE "^Test Case '-\[([A-Za-z0-9_]+\.)?${second} " "$log" | head -1 | cut -d: -f1)
  # Absence and order are DIFFERENT facts and get different names. Collapsing
  # them let the tool say "'VICTIM' executed BEFORE 'SUSPECT', so 'SUSPECT'
  # cannot be the cause" about a suspect that never ran at all -- an
  # exculpatory claim the log flatly contradicts.
  # Absence is only meaningful when the log CARRIES per-case lines. Without
  # them, order is unobservable and "X never executed" is a claim the log cannot
  # support -- the same absence-category conflation, in the arm that classify_run
  # 's guard did not cover.
  if ! has_per_case_lines "$log"; then
    echo "order-unobservable"; return 0
  fi
  if [ -z "$line_first" ]; then echo "first-absent"; return 0; fi
  if [ -z "$line_second" ]; then echo "second-absent"; return 0; fi
  if [ "$line_first" -lt "$line_second" ]; then echo "ok"; else echo "wrong-order"; fi
}

# A run that produced no verdict stops the tool. Reporting anything about the
# code from here would be inventing a result for work that never happened.
abort_unrunnable() {
  local verdict="$1" context="$2"
  echo ""
  echo "CANNOT DIAGNOSE: the $context run produced no attributable result (${verdict#*:})."
  echo "  No conclusion about '$VICTIM' is possible from this run — this is NOT"
  echo "  evidence that the test passes, fails, or is polluted."
  case "$verdict" in
    *:destination-not-found)
      echo "  The simulator '$SIM_UDID' did not resolve. Pass --sim <UDID>, or export"
      echo "  HARNESS_SESSION_SIM_UDID. List devices: xcrun simctl list devices available" ;;
    *:build-failed)
      echo "  The build failed. Fix the build first — its errors are in the log." ;;
    never-ran:no-tests-matched)
      echo "  No test matched the selectors. Check the class name is an XCTestCase"
      echo "  subclass in the PalaceTests bundle (-only-testing matches <bundle>/<class>)." ;;
    never-ran:timeout-or-restart)
      # DIFFERENT from the line above, and it used to share it: a runner that
      # dies at launch executes nothing, and telling its reader to check the
      # class name sends them to debug something that is not broken.
      echo "  The runner died before any test executed. The class name is fine —"
      echo "  this is a launch failure, not a selector problem. Read the log." ;;
    ran:timeout-or-restart)
      echo "  The run timed out or restarted after tests had executed, so its"
      echo "  totals span multiple launches. A hang can itself be the pollution"
      echo "  symptom — read the log directly." ;;
    ran:other-class-failed)
      echo "  A test failed, but not one of '$VICTIM'. That is a fact about the"
      echo "  other class, not evidence about the victim. Fix it, then re-run." ;;
    ran:focus-did-not-run)
      echo "  '$VICTIM' did not execute — no passed/failed line for it. A test that"
      echo "  SKIPPED (XCTSkip) looks exactly like this, and a skip is not a pass."
      echo "  Check the class name, and read the log for a skip reason." ;;
    ran:unattributed-failure)
      echo "  The run recorded failures but no per-case lines, so no failure can"
      echo "  be attributed to a class. Read the log directly." ;;
  esac
  echo "  Full log: $LAST_LOG"
  echo "  (tail:)"
  tail -25 "$LAST_LOG" | sed 's/^/    /'
  exit 3
}

echo ""
echo "=== Step 1: does $VICTIM pass in isolation? ==="
ISOLATION_PASSES=0
VERDICT=""
for i in $(seq 1 "$ITERATIONS"); do
  LAST_LOG=$(log_for "isolation-$i")
  VERDICT=$(run_tests "isolation-$i" "$VICTIM")
  case "$VERDICT" in
    ran:pass) ISOLATION_PASSES=$((ISOLATION_PASSES + 1)) ;;
    *) break ;;
  esac
done
case "$VERDICT" in
  ran:pass)
    echo "  PASS alone x$ISOLATION_PASSES -> $VICTIM is a pollution VICTIM."
    if [ "$ITERATIONS" -eq 1 ]; then
      # Say the sample size out loud. A victim that fails intermittently ON ITS
      # OWN looks EXACTLY like this in one run, and that is the "real bug" case
      # this step exists to rule out.
      echo "       NOTE: that is ONE sample. A victim that fails intermittently"
      echo "       alone is indistinguishable from a clean one here — re-run with"
      echo "       --iterations 3+ before trusting a polluter verdict."
    fi ;;
  "")
    # Unreachable with the validation above; kept so that any future path which
    # leaves the isolation verdict unset STOPS rather than silently proceeding
    # to draw conclusions about suspects.
    echo "CANNOT DIAGNOSE: step 1 produced no verdict at all." >&2
    exit 3 ;;
  ran:test-failure)
    echo ""
    echo "RESULT: $VICTIM FAILS in isolation — this is a REAL bug, not pollution."
    echo "        Fix the test/production code; pollution bisection does not apply."
    echo "        Failing cases:"
    grep -E "^Test Case '.*' failed" "$LAST_LOG" | sed 's/^/          /'
    echo "        Full log: $LAST_LOG"
    exit 1 ;;
  *)
    # Every remaining token — never-ran:* and ran:<error reason> — means step 1
    # produced no usable verdict about the victim. Abort rather than proceed to
    # draw conclusions about suspects from it.
    abort_unrunnable "$VERDICT" "isolation" ;;
esac

if [ ${#SUSPECT_LIST[@]} -eq 0 ]; then
  echo ""
  echo "No --suspects given. Re-run with the classes that executed BEFORE"
  echo "$VICTIM in the failing run, e.g.:"
  echo "  scripts/find-test-polluter.sh --victim $VICTIM \\"
  echo "      --suspects \"TokenRefreshAndRetryQueueTests AccountsManagerStateMachineWiringTests ...\""
  # NOT exit 0. Step 1 ran, but no pair was bisected, so there is no verdict
  # about any suspect — and exit 0 documents itself as "ran cleanly, nothing to
  # report". The whitespace-only sibling already refuses to make that claim.
  exit 3
fi

echo ""
STEP2_RAN=1
echo "=== Step 2: bisect suspects (each run: SUSPECT then $VICTIM) ==="
FOUND=""
FOUND_LOG=""
CANDIDATES=""     # flipped once, then a CLEAN run did not reproduce it
UNCONFIRMED=""    # flipped once, and the confirming run never happened
INCONCLUSIVE=""   # the pair ran, but could not be judged
NEVER_RAN=""      # the pair produced no result at all
ATTEMPTED=0

for s in "${SUSPECT_LIST[@]}"; do
  ATTEMPTED=$((ATTEMPTED + 1))
  LAST_LOG=$(log_for "pair-$s")
  VERDICT=$(run_tests "pair-$s" "$s" "$VICTIM")
  case "$(pair_outcome "$VERDICT" "$(order_state "$LAST_LOG" "$s" "$VICTIM")")" in
    acquitted)
      echo "    $s -> victim still passes (not the polluter)" ;;

    flip)
      # Confirm before accusing. One flip is one sample, and a victim that is
      # merely self-flaky produces exactly this line against whichever innocent
      # suspect happened to be running when the dice came up.
      echo "    $s -> victim FAILS after this class ran first — confirming..."
      CONFIRM_LOG=$(log_for "confirm-$s")
      CONFIRM=$(run_tests "confirm-$s" "$s" "$VICTIM")
      case "$(pair_outcome "$CONFIRM" "$(order_state "$CONFIRM_LOG" "$s" "$VICTIM")")" in
        flip)
          echo "         reproduced ***"
          FOUND="$s"; FOUND_LOG="$CONFIRM_LOG"
          break ;;
        acquitted)
          # A clean run that did not reproduce. THIS is the observation that
          # says something about the victim.
          echo "         DID NOT reproduce — recording as a candidate, not a"
          echo "         polluter. log: $CONFIRM_LOG"
          CANDIDATES="$CANDIDATES $s" ;;
        no-result)
          # The confirm run never happened. This is its OWN state: the pair ran
          # once and flipped, and the second sample was never taken. Filing it
          # under "ran but not judged" asserts a run that did not occur, and
          # filing it under "never ran" throws away the flip we did observe.
          echo "         confirm run never executed (${CONFIRM#*:}) — the flip"
          echo "         stands UNCONFIRMED, not refuted. log: $CONFIRM_LOG"
          UNCONFIRMED="$UNCONFIRMED $s" ;;
        *)
          # The confirmation ran and could not be judged. Not a reproduction,
          # and not evidence about the victim either.
          echo "         confirmation ran but could not be judged — '$s' is"
          echo "         neither cleared nor named. log: $CONFIRM_LOG"
          INCONCLUSIVE="$INCONCLUSIVE $s" ;;
      esac ;;

    inconclusive-order)
      echo "    $s -> INCONCLUSIVE: '$s' did not finish before '$VICTIM' started,"
      echo "                        so this pair can neither clear nor implicate"
      echo "                        it. log: $LAST_LOG"
      INCONCLUSIVE="$INCONCLUSIVE $s" ;;

    inconclusive-suspect-absent)
      echo "    $s -> INCONCLUSIVE: '$s' never executed — no test case for it in"
      echo "                        the log. Check the class name. log: $LAST_LOG"
      INCONCLUSIVE="$INCONCLUSIVE $s" ;;

    inconclusive-victim-absent)
      echo "    $s -> INCONCLUSIVE: '$VICTIM' did not execute in this pair."
      echo "                        Step 1 already proved the name valid, so the"
      echo "                        likely cause is a SKIP — pollution that wipes"
      echo "                        shared state makes a victim XCTSkip, and a skip"
      echo "                        is not a pass. Read the log for a skip reason."
      echo "                        log: $LAST_LOG"
      INCONCLUSIVE="$INCONCLUSIVE $s" ;;

    inconclusive-ran-unjudgeable)
      echo "    $s -> INCONCLUSIVE: the pair ran but produced no verdict about"
      echo "                        '$VICTIM' (${VERDICT#*:})."
      case "$VERDICT" in
        ran:timeout-or-restart)
          echo "                        A hang can itself be the pollution symptom —"
          echo "                        read the log directly rather than re-running." ;;
        ran:other-class-failed)
          echo "                        '$s' own test failed; fix that first, then"
          echo "                        this pair can say something about '$VICTIM'." ;;
      esac
      echo "                        log: $LAST_LOG"
      INCONCLUSIVE="$INCONCLUSIVE $s" ;;

    no-result)
      echo "    $s -> NEVER RAN (${VERDICT#*:}); log: $LAST_LOG"
      NEVER_RAN="$NEVER_RAN $s" ;;

    *)
      # Unreachable today: every pair_outcome value is named above. If a new
      # one is ever added, it must NOT bucket nowhere and let the run finish
      # with "no polluter found" at exit 0.
      echo "INTERNAL: unhandled pair outcome for '$s'" >&2
      exit 3 ;;
  esac
done

# Everything the `break` never reached is in neither bucket and must not be
# read as cleared.
UNATTEMPTED=""
if [ "$ATTEMPTED" -lt "${#SUSPECT_LIST[@]}" ]; then
  UNATTEMPTED=" ${SUSPECT_LIST[*]:$ATTEMPTED}"
fi

# Each bucket gets its own sentence. Folding them together is what let "ran but
# could not be judged" print under the words "never ran and remain untested".
report_uncleared() {
  [ -n "$NEVER_RAN$UNATTEMPTED" ] &&     echo "  NEVER RAN (no result at all):${NEVER_RAN}${UNATTEMPTED}"
  [ -n "$INCONCLUSIVE" ] && \
    echo "  RAN BUT NOT JUDGED (order/absence/inconclusive confirm):${INCONCLUSIVE}"
  [ -n "$UNCONFIRMED" ] && \
    echo "  FLIPPED, CONFIRMATION NEVER RAN (re-run these first):${UNCONFIRMED}"
  return 0
}

echo ""
if [ -n "$FOUND" ]; then
  echo "RESULT: polluter is '$FOUND' (flip reproduced on a second run)."
  echo "  '$FOUND' leaves shared state dirty that breaks '$VICTIM'."
  echo "  Fix at the root: tear down the singleton / await the background task /"
  echo "  reset UserDefaults+keychain in '$FOUND' tearDown (or the SUT it drives)."
  echo "  Failing cases:"
  grep -E "^Test Case '.*' failed" "$FOUND_LOG" | sed 's/^/    /'
  echo "  Confirming run: $FOUND_LOG"
  report_uncleared
  if [ -n "$CANDIDATES" ]; then
    # This CUTS AGAINST the verdict just printed.
    echo "  CAUTION: these flipped the victim once but did NOT reproduce:${CANDIDATES}"
    echo "  That is evidence '$VICTIM' may be flaky on its own, which would make"
    echo "  the verdict above a coincidence. Re-run with --iterations 3+."
  fi
  exit 1
elif [ -n "$CANDIDATES" ]; then
  echo "RESULT: no CONFIRMED polluter. These flipped the victim once but did not"
  echo "  reproduce on a second run:${CANDIDATES}"
  echo "  That pattern is equally consistent with '$VICTIM' being flaky on its"
  echo "  own, which is a REAL bug rather than pollution. Re-run with"
  echo "  --iterations 3+ to tell the two apart before changing any teardown."
  report_uncleared
  exit 3
elif [ -n "$NEVER_RAN$INCONCLUSIVE$UNATTEMPTED$UNCONFIRMED" ]; then
  echo "RESULT: INCOMPLETE — no polluter among the suspects that were actually"
  echo "  judged, but these were not:"
  report_uncleared
  echo "  Fix the causes above and re-run; do not treat them as cleared."
  exit 3
else
  echo "RESULT: no polluter found among the given suspects."
  echo "  Widen --suspects (the polluter may be a class you didn't list); the"
  echo "  failure may need >=2 classes in combination; or the flake is not"
  echo "  pollution at all — this tool pins parallel testing OFF, so a failure"
  echo "  caused by clone contention cannot reproduce here by construction."
  echo "  Tail of last run:"
  tail -10 "$LAST_LOG" | sed 's/^/    /'
  exit 0
fi

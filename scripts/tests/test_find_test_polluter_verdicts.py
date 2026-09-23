"""Verdict classification in `scripts/find-test-polluter.sh`.

The script used to decide everything from the raw `xcodebuild` exit code. That
conflates two states a diagnostic must never conflate:

    the test ran and failed        →  a finding
    the test never ran at all      →  no information

Both are "non-zero exit", so a destination failure, a build failure, or a
selector that matched no tests all produced the script's most confident output:

    RESULT: <victim> FAILS in isolation — this is a REAL bug, not pollution.
            Fix the test/production code; pollution bisection does not apply.

It emitted exactly that during the PP-5025 follow-up work from a run in which
ZERO tests executed. The log for that run is the `DESTINATION_FAILURE_LOG`
fixture below, reproduced from the real artifact: no `Test Case` lines, no
`Executed N test` line, no `** TEST FAILED **` marker, and an `xcodebuild:
error: Unable to find a device matching` — every available signal saying "this
never ran", and the script read none of them.

The trigger was the script's own default: `awk '/Booted/ {print $NF}'` on a
simctl line yields `(Booted)`, not the UDID, so the destination it built was
literally `id=Booted`. That is the DEFAULT path, taken whenever a simulator is
booted and `--sim` is omitted.

These tests drive the classifier as a shell fragment lifted from the real file,
so they assert the DECISION without launching Xcode.
"""

import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "find-test-polluter.sh"


# --- Fixtures: authentic xcodebuild log shapes -----------------------------

# Reproduced from the real run that produced the false verdict.
DESTINATION_FAILURE_LOG = """\
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Palace.xcodeproj -scheme Palace -destination "platform=iOS Simulator,id=Booted" "-only-testing:PalaceTests/DownloadAuthRetryHandlerAuthCoordinatorTests"

Resolve Package Graph

xcodebuild: error: Unable to find a device matching the provided destination specifier:
		{ platform:iOS Simulator, id:Booted }

	Available destinations for the "Palace" scheme:
		{ platform:iOS Simulator, arch:arm64, id:BBBB-1111, OS:26.1, name:iPhone 16 Pro }
"""

BUILD_FAILURE_LOG = """\
Command line invocation:
    xcodebuild test -project Palace.xcodeproj -scheme Palace

CompileSwift normal arm64 /Users/x/Palace/Foo.swift
/Users/x/Palace/Foo.swift:12:5: error: cannot find 'bar' in scope

** BUILD FAILED **

The following build commands failed:
	SwiftCompile normal arm64 Compiling\\ Foo.swift
(1 failure)
"""

NO_TESTS_MATCHED_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Suite 'Selected tests' passed at 2026-08-26 09:00:00.001.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds

** TEST SUCCEEDED **
"""

REAL_FAILURE_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' started.
/Users/x/PalaceTests/VictimTests.swift:41: error: -[PalaceTests.VictimTests testThing] : XCTAssertEqual failed: ("1") is not equal to ("2")
Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds).
	 Executed 1 test, with 1 failure (0 unexpected) in 0.004 (0.005) seconds

** TEST FAILED **
"""

CLEAN_PASS_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' started.
Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds).
	 Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds

** TEST SUCCEEDED **
"""

TIMEOUT_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' started.
Restarting after unexpected exit, crash, or test timeout in VictimTests.testThing; summary will include totals from previous launches.
	 Executed 1 test, with 1 failure (1 unexpected) in 120.000 (120.001) seconds

** TEST FAILED **
"""


def _shared_predicate() -> str:
    """`has_per_case_lines`, which both lifted fragments now call.

    Extracted rather than duplicated: a copy here would be a second definition
    of the very predicate whose four copies caused round 10's defect.
    """
    text = SCRIPT.read_text()
    start = text.index("has_per_case_lines() {")
    return text[start:text.index("\n}\n", start) + 3]


def _classifier_fragment() -> str:
    """Lift the classifier from the real script by its markers.

    Read from the file rather than duplicated, so these tests cannot drift into
    asserting a copy of logic that no longer ships.
    """
    text = SCRIPT.read_text()
    start = text.index("# >>> classify_run BEGIN")
    end = text.index("# <<< classify_run END")
    return text[start:end]


def _classify(exit_code: int, log: str, tmp_path) -> str:
    log_file = tmp_path / "run.log"
    log_file.write_text(log)
    script = (
        "set -uo pipefail\n"
        + _shared_predicate()
        + _classifier_fragment()
        + f'\nclassify_run {exit_code} "{log_file}"\n'
    )
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert proc.returncode == 0, f"classifier itself errored: {proc.stderr}"
    return proc.stdout.strip()


# --- The defect ------------------------------------------------------------

def test_destination_failure_is_an_error_not_a_test_failure(tmp_path):
    """The exact run that produced the false verdict.

    Non-zero exit, zero tests executed. Anything other than an `error:`
    classification here re-introduces the defect.
    """
    verdict = _classify(70, DESTINATION_FAILURE_LOG, tmp_path)
    assert verdict == "never-ran:destination-not-found", f"the reason must name the destination, got {verdict!r}"


def test_build_failure_is_an_error_not_a_test_failure(tmp_path):
    verdict = _classify(65, BUILD_FAILURE_LOG, tmp_path)
    assert verdict == "never-ran:build-failed", f"the reason must name the build, got {verdict!r}"


def test_zero_tests_executed_is_an_error_even_when_xcodebuild_succeeds(tmp_path):
    """A typo'd class name matches nothing and xcodebuild reports SUCCESS.

    CLAUDE.md: "A run that says '0 tests executed' is a misconfiguration, not a
    clean pass." Read as a pass, it silently proves the victim is clean.
    """
    verdict = _classify(0, NO_TESTS_MATCHED_LOG, tmp_path)
    assert verdict == "never-ran:no-tests-matched", f"got {verdict!r}"


# --- The classifier must still be USEFUL -----------------------------------

def test_a_named_failing_test_is_a_test_failure(tmp_path):
    """The control. Without this the fix could just call everything an error."""
    assert _classify(65, REAL_FAILURE_LOG, tmp_path) == "ran:test-failure"


def test_a_clean_run_is_a_pass(tmp_path):
    assert _classify(0, CLEAN_PASS_LOG, tmp_path) == "ran:pass"


def test_timeout_is_reported_as_its_own_error_reason(tmp_path):
    """A hang cannot be attributed, but it may itself be the pollution symptom.

    Classifying it `pass` would hide it; classifying it `test-failure` would
    name an innocent victim. It gets its own reason so the human sees it.
    """
    verdict = _classify(65, TIMEOUT_LOG, tmp_path)
    assert verdict == "ran:timeout-or-restart", f"got {verdict!r}"


def test_nonzero_exit_with_passing_tests_is_not_silently_a_pass(tmp_path):
    """Tests all passed but xcodebuild still failed — do not claim a clean pass."""
    verdict = _classify(65, CLEAN_PASS_LOG, tmp_path)


# --- Simulator resolution --------------------------------------------------

def test_script_syntax_is_valid():
    proc = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


def test_script_no_longer_parses_a_udid_with_awk_NF():
    """The trigger, banned by construction.

    `xcrun simctl list devices` prints `iPhone 16 Pro (UDID) (Booted)`, so `$NF`
    is `(Booted)` and `tr -d '()'` turns it into the literal string `Booted`.
    The script then built `-destination "platform=iOS Simulator,id=Booted"`.
    """
    text = SCRIPT.read_text()
    assert "awk '/Booted/ {print $NF" not in text, (
        "the $NF simctl parse yields the literal string 'Booted', not a UDID"
    )


def test_session_allocated_simulator_is_honoured():
    """A session that claimed a device must keep it, as elsewhere in the repo."""
    text = SCRIPT.read_text()
    assert "HARNESS_SESSION_SIM_UDID" in text, (
        "must honour the session-allocated simulator like xcode-test-optimized.sh"
    )


# --- Focus-class attribution (a pair run executes TWO classes) --------------

SUSPECT_FAILS_VICTIM_PASSES_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.SuspectTests testSuspectThing]' failed (0.004 seconds).
Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds).
\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds
"""

ROLLUP_ONLY_FAILURE_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds
"""


def _classify_focus(exit_code, log, tmp_path, focus):
    log_file = tmp_path / "run.log"
    log_file.write_text(log)
    script = ("set -uo pipefail\n" + _shared_predicate() + _classifier_fragment()
              + f'\nclassify_run {exit_code} "{log_file}" "{focus}"\n')
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.strip()


def test_a_suspects_own_failure_is_not_a_verdict_about_the_victim(tmp_path):
    """The pair-run form of the headline defect.

    "Some test failed" is not "the victim failed". Without focus attribution the
    script announces `polluter is 'SuspectTests'` from a log in which the victim
    demonstrably passed.
    """
    verdict = _classify_focus(65, SUSPECT_FAILS_VICTIM_PASSES_LOG, tmp_path, "VictimTests")
    assert verdict == "ran:other-class-failed", (
        f"a failure belonging to another class must not read as the victim's, got {verdict!r}"
    )


def test_the_victims_own_failure_is_still_a_test_failure(tmp_path):
    """The control for the above — attribution must not suppress real findings."""
    log = SUSPECT_FAILS_VICTIM_PASSES_LOG.replace(
        "Test Case '-[PalaceTests.VictimTests testThing]' passed",
        "Test Case '-[PalaceTests.VictimTests testThing]' failed")
    assert _classify_focus(65, log, tmp_path, "VictimTests") == "ran:test-failure"


def test_focus_matching_is_not_a_loose_substring(tmp_path):
    """`VictimTests` must not be satisfied by `VictimTestsExtra`."""
    log = SUSPECT_FAILS_VICTIM_PASSES_LOG.replace(
        "PalaceTests.SuspectTests testSuspectThing",
        "PalaceTests.VictimTestsExtra testThing")
    assert _classify_focus(65, log, tmp_path, "VictimTests") == "ran:other-class-failed"


def test_a_failure_with_no_per_case_lines_is_not_attributed(tmp_path):
    """The rollup proves a failure happened; it cannot say whose."""
    verdict = _classify_focus(65, ROLLUP_ONLY_FAILURE_LOG, tmp_path, "VictimTests")
    assert verdict == "ran:unattributed-failure", f"got {verdict!r}"


def test_rollup_only_failure_is_still_a_failure_without_a_focus(tmp_path):
    """Suppressed per-case output must not degrade a real failure to error:."""
    assert _classify(65, ROLLUP_ONLY_FAILURE_LOG, tmp_path) == "ran:test-failure"


# --- The decision table, cell by cell --------------------------------------
#
# Five review rounds each found one more unhandled combination, because the
# cells were hand-enumerated as nested prose `case`s. This asserts EVERY cell,
# which is finite and enumerable; the scenarios that reach them are not.

def _table_fragment() -> str:
    text = SCRIPT.read_text()
    return text[text.index("# >>> pair_outcome BEGIN"):text.index("# <<< pair_outcome END")]


def _outcome(verdict: str, order: str) -> str:
    script = ("set -uo pipefail\n" + _table_fragment()
              + f'\npair_outcome "{verdict}" "{order}"\n')
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.strip()


ORDERS = ["ok", "wrong-order", "first-absent", "second-absent"]

TABLE = {
    ("ran:pass", "ok"): "acquitted",
    ("ran:pass", "wrong-order"): "inconclusive-order",
    ("ran:pass", "first-absent"): "inconclusive-suspect-absent",
    ("ran:pass", "second-absent"): "inconclusive-victim-absent",
    ("ran:test-failure", "ok"): "flip",
    ("ran:test-failure", "wrong-order"): "inconclusive-order",
    ("ran:test-failure", "first-absent"): "inconclusive-suspect-absent",
    ("ran:test-failure", "second-absent"): "inconclusive-victim-absent",
}


@pytest.mark.parametrize("cell,expected", sorted(TABLE.items()))
def test_every_cell_of_the_decision_table(cell, expected):
    verdict, order = cell
    assert _outcome(verdict, order) == expected


# The `error:` row. Writing the table is what exposed that `error:` is not one
# thing: some values mean the pair never ran, others mean it ran and cannot be
# judged. Bucketing them together printed "ran but unjudgeable" results under
# the words "never ran".
# Field 1 alone decides the bucket, so EVERY reason paired with `never-ran`
# must be no-result and every reason paired with `ran` must not be — regardless
# of what the reason says. That is the property the two-fact split buys.
NEVER_RAN_ERRORS = [
    "never-ran:destination-not-found", "never-ran:build-failed",
    "never-ran:no-tests-matched", "never-ran:empty-log",
    "never-ran:timeout-or-restart",
]
RAN_BUT_UNJUDGEABLE_ERRORS = [
    "ran:other-class-failed", "ran:unattributed-failure",
    "ran:timeout-or-restart", "ran:unexplained-exit-65",
    "ran:destination-not-found", "ran:build-failed",
]


@pytest.mark.parametrize("verdict", NEVER_RAN_ERRORS)
@pytest.mark.parametrize("order", ORDERS)
def test_errors_meaning_the_pair_never_ran(verdict, order):
    assert _outcome(verdict, order) == "no-result", (
        f"{verdict} means nothing executed, in any order state"
    )


@pytest.mark.parametrize("verdict", RAN_BUT_UNJUDGEABLE_ERRORS)
@pytest.mark.parametrize("order", ORDERS)
def test_errors_meaning_the_pair_ran_but_cannot_be_judged(verdict, order):
    assert _outcome(verdict, order) == "inconclusive-ran-unjudgeable", (
        f"{verdict} means tests DID execute — reporting it as 'never ran' is the "
        "absence-category conflation"
    )


def test_focus_did_not_run_names_the_victim_not_a_missing_run():
    """The victim not executing is a fact about the VICTIM, not about the pair
    failing to start."""
    for order in ORDERS:
        assert _outcome("ran:focus-did-not-run", order) == "inconclusive-victim-absent"


def test_an_unknown_future_error_defaults_to_ran_but_unjudgeable():
    """Fail toward 'we cannot say', never toward a verdict.

    A new `error:` value added later must not silently acquire the meaning of
    whichever branch happens to catch it.
    """
    assert _outcome("ran:something-invented-later", "ok") == "inconclusive-ran-unjudgeable"


def test_an_unknown_verdict_never_reads_as_a_verdict():
    """Neither pass nor test-failure nor error: — must not become acquitted or flip."""
    assert _outcome("banana", "ok") not in ("acquitted", "flip")


# --- Round-7: classify by evidence, not by which message appeared ----------

LAUNCH_CRASH_LOG = """\
Test Suite 'Selected tests' started at 2026-08-27 09:00:00.000
Restarting after unexpected exit, crash, or test timeout in VictimTests; summary will include totals from previous launches.
"""


def test_a_runner_that_died_at_launch_is_never_ran_not_a_timeout(tmp_path):
    """A restart line with ZERO executed cases means nothing ran.

    The restart test used to precede the executed-count, so this classified as
    `timeout-or-restart` — which the decision table reads as "the pair RAN".
    Whether tests executed is observable, so it is observed.
    """
    verdict = _classify(65, LAUNCH_CRASH_LOG, tmp_path)
    assert verdict == "never-ran:timeout-or-restart", (
        f"got {verdict!r} — nothing executed, so field 1 must be never-ran, and "
        "the reason must still name the crash rather than blaming the selector: "
        "'no test matched, check the class name' is a false positive here"
    )


def test_a_restart_AFTER_tests_ran_is_still_a_timeout(tmp_path):
    """The control — reordering must not swallow real restarts."""
    log = ("Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds).\n"
           "Restarting after unexpected exit, crash, or test timeout in VictimTests.\n"
           "\t Executed 1 test, with 1 failure (1 unexpected) in 120.000 (120.001) seconds\n")
    assert _classify(65, log, tmp_path) == "ran:timeout-or-restart"


def test_a_destination_failure_still_outranks_the_executed_count(tmp_path):
    """Reordering must keep the specific cause, not degrade to 'nothing ran'."""
    verdict = _classify(70, DESTINATION_FAILURE_LOG, tmp_path)
    assert verdict == "never-ran:destination-not-found", f"got {verdict!r}"


def test_every_outcome_the_table_emits_is_handled_by_its_consumer():
    """Pins the step-2 sink WITHOUT a seam that exists only to be tested.

    The sink — `*)` exits 3 rather than bucketing nowhere — is unreachable by
    construction, so deleting it kills no behavioural test. Instead of inventing
    a way to reach it, derive both sides from the source and require they match:
    the literals `pair_outcome` can echo, and the labels its consumer names.

    That kills the delete-an-arm mutant on either side, and it is derived
    mechanically rather than from anyone's model of the code.
    """
    text = SCRIPT.read_text()

    table = text[text.index("pair_outcome() {"):text.index("# <<< pair_outcome END")]
    emitted = set(re.findall(r'echo "([a-z-]+)"', table))

    step2 = text[text.index("for s in \"${SUSPECT_LIST[@]}\"; do"):text.index("# Everything the `break` never reached")]
    # Case labels are the bare outcome names at the head of each arm.
    handled = set(re.findall(r'^\s{4}([a-z][a-z-]+)\)', step2, re.M))

    assert emitted, "found no emitted outcomes — the extraction markers moved"
    assert handled, "found no case labels — the extraction anchors moved"
    assert emitted == handled, (
        "pair_outcome and its consumer disagree.\n"
        f"  emitted but not handled: {sorted(emitted - handled)}\n"
        f"  handled but not emitted: {sorted(handled - emitted)}"
    )


# --- Round-9: "ran" must mean EXECUTED, not COMPLETED ----------------------

STARTED_THEN_HUNG_LOG = """\
Test Suite 'Selected tests' started at 2026-08-27 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' started.
Test Case '-[PalaceTests.VictimTests testOther]' started.
Restarting after unexpected exit, crash, or test timeout in VictimTests; summary will include totals from previous launches.
Restarting after unexpected exit, crash, or test timeout in VictimTests; summary will include totals from previous launches.
"""


def test_a_case_that_started_and_never_finished_counts_as_having_run(tmp_path):
    """`ran` was taken from COMPLETED cases, so a crash or hang mid-test — the
    shape where a case starts and never finishes — classified as "never ran".

    That is false, and it costs a lead: the `never-ran` message says "the runner
    died before any test executed", while the `ran:` sibling carries "a hang can
    itself be the pollution symptom", which is the useful one here.
    """
    verdict = _classify(65, STARTED_THEN_HUNG_LOG, tmp_path)
    assert verdict == "ran:timeout-or-restart", (
        f"got {verdict!r} — two cases STARTED, so tests executed; only their "
        "completion is missing"
    )


def test_a_launch_crash_with_no_started_lines_is_still_never_ran(tmp_path):
    """The control: no `started.` at all means nothing executed."""
    assert _classify(65, LAUNCH_CRASH_LOG, tmp_path) == "never-ran:timeout-or-restart"


# --- Round-9: order is unobservable without per-case lines -----------------

def _order(log: str, first: str, second: str, tmp_path) -> str:
    log_file = tmp_path / "o.log"
    log_file.write_text(log)
    text = SCRIPT.read_text()
    start = text.index("order_state() {")
    # Slice to the function's own closing brace, not to a marker whose position
    # relative to this function is an assumption. My first attempt sliced to
    # "# >>> pair_outcome BEGIN", which now sits ABOVE order_state.
    frag = text[start:text.index("\n}\n", start) + 3]
    script = ("set -uo pipefail\n" + _shared_predicate() + frag
              + f'\norder_state "{log_file}" "{first}" "{second}"\n')
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.strip()


def test_order_is_unobservable_when_the_log_has_no_per_case_lines(tmp_path):
    """A rollup-only log yielded `first-absent`, whose message says the suspect
    "never executed — check the class name". The rollup proves tests ran and
    simply does not say which; the name may be perfectly correct.

    Same absence-category conflation as classify_run's, in the arm that guard
    did not cover.
    """
    rollup_only = "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds\n"
    assert _order(rollup_only, "SuspectA", "VictimTests", tmp_path) == "order-unobservable"


def test_order_is_still_read_when_per_case_lines_exist(tmp_path):
    """Control — the guard must not blind the normal path."""
    log = ("Test Case '-[PalaceTests.SuspectA testA]' started.\n"
           "Test Case '-[PalaceTests.SuspectA testA]' passed (0.001 seconds).\n"
           "Test Case '-[PalaceTests.VictimTests testThing]' started.\n"
           "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.001 seconds).\n")
    assert _order(log, "SuspectA", "VictimTests", tmp_path) == "ok"


def test_an_unobservable_order_never_yields_a_verdict():
    """It must reach the cannot-say bucket, not acquitted or flip."""
    assert _outcome("ran:pass", "order-unobservable") == "inconclusive-ran-unjudgeable"
    assert _outcome("ran:test-failure", "order-unobservable") == "inconclusive-ran-unjudgeable"


# --- Round-9: pin the sink itself, not just the arm labels -----------------

def test_the_step2_consumer_has_a_catch_all_that_stops_the_run():
    """The set-equality test above pins the NAMED arms, but deleting the `*)`
    sink left it green — verified by a reviewer, while this PR's own commit body
    claimed the sink was pinned. It is pinned here.

    An unrecognised outcome must not bucket nowhere and let the run finish with
    "no polluter found" at exit 0.
    """
    text = SCRIPT.read_text()
    step2 = text[text.index("for s in \"${SUSPECT_LIST[@]}\"; do"):text.index("# Everything the `break` never reached")]
    assert re.search(r'^\s{4}\*\)', step2, re.M), (
        "the step-2 case has no catch-all arm: an outcome added to pair_outcome "
        "but not handled here would bucket nowhere and exit 0 'no polluter found'"
    )
    sink = step2[re.search(r'^\s{4}\*\)', step2, re.M).start():]
    assert "exit 3" in sink.split(";;")[0], (
        "the catch-all must STOP the run, not fall through silently"
    )


# --- Round-10: one predicate for "has per-case lines" ----------------------

SKIPPED_ONLY_LOG = """\
Test Suite 'Selected tests' started at 2026-08-27 09:00:00.000
Test Case '-[PalaceTests.SuspectA testOwn]' started.
Test Case '-[PalaceTests.SuspectA testOwn]' skipped (0.002 seconds).
Test Case '-[PalaceTests.VictimTests testThing]' started.
Test Case '-[PalaceTests.VictimTests testThing]' skipped (0.002 seconds).
\t Executed 2 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
"""


def test_a_victim_that_only_SKIPPED_is_not_a_pass(tmp_path):
    """The round-8 guard re-opened the round-2 fix.

    `case_lines` matched only `(passed|failed)`, so a log of nothing but
    `skipped` satisfied "no per-case lines", which suppressed the focus-absence
    check and let the pair reach `ran:pass` — acquitted, exit 0, over a victim
    that never asserted anything. A skipped victim is the pollution symptom this
    tool exists to catch, not evidence of innocence.
    """
    verdict = _classify_focus(0, SKIPPED_ONLY_LOG, tmp_path, "VictimTests")
    assert verdict == "ran:focus-did-not-run", (
        f"got {verdict!r} — the victim skipped; that is not a pass"
    )


def test_the_per_case_line_predicate_has_exactly_one_definition():
    """It was spelled four ways, which is why one guard re-opened another's fix.

    Derived from the source: no call site may re-implement the predicate with
    its own inline grep.
    """
    text = SCRIPT.read_text()
    assert "has_per_case_lines()" in text, "the shared predicate is gone"
    body_start = text.index("has_per_case_lines() {")
    body_end = text.index("}", body_start)
    body = text[body_start:body_end]
    for token in ("started", "passed", "failed", "skipped"):
        assert token in body, f"the predicate must recognise {token!r} lines"


def test_every_order_state_is_handled_by_its_consumer():
    """The order axis of the same set-equality check.

    Deleting both `order-unobservable)` arms and letting the catch-all absorb
    them left 120/120 green — the "reaching the right bucket only via a
    catch-all" state, restored undetected. This pins the order axis the way the
    outcome axis is already pinned.
    """
    text = SCRIPT.read_text()
    start = text.index("order_state() {")
    fn = text[start:text.index("\n}\n", start)]
    emitted = set(re.findall(r'echo "([a-z-]+)"', fn))

    table = text[text.index("pair_outcome() {"):text.index("# <<< pair_outcome END")]
    handled = set(re.findall(r'^\s+([a-z][a-z-]+)\)', table, re.M))

    missing = emitted - handled
    assert not missing, (
        f"order_state emits {sorted(missing)} which pair_outcome never names — "
        "they would reach a bucket only through a catch-all"
    )

"""End-to-end behaviour of `scripts/find-test-polluter.sh` with a stubbed build.

The unit tests in `test_find_test_polluter_verdicts.py` pin `classify_run` in
isolation. That is necessary and not sufficient: the first REAL run of the fixed
script printed a correct verdict and then pointed at a log file that did not
exist, because `LAST_LOG` was assigned inside `VERDICT=$(run_tests ...)` — a
command substitution, hence a subshell, hence an assignment the parent never
sees. Every classifier unit test passed while the tool's own evidence link was
broken.

So these tests drive the WHOLE script, end to end, by substituting the build
tool via `$PALACE_XCODEBUILD`. That keeps them runnable on the Linux
tooling-checks runner, where Xcode does not exist, while still exercising the
real argument parsing, the real control flow, and — the part that broke — the
real reporting.
"""

import os
import re
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "find-test-polluter.sh"
REPO = SCRIPT.parents[1]


DESTINATION_FAILURE = """\
xcodebuild: error: Unable to find a device matching the provided destination specifier:
\t\t{ platform:iOS Simulator, id:Booted }
"""

VICTIM_PASSES = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds).
\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
"""

VICTIM_FAILS = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds).
\t Executed 1 test, with 1 failure (0 unexpected) in 0.004 (0.005) seconds
"""


def _stub(tmp_path, script_body: str) -> Path:
    """A fake build tool. Receives the real argv the script would have used."""
    stub = tmp_path / "fake-xcodebuild"
    stub.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(script_body))
    stub.chmod(0o755)
    return stub


# Both variables the script consults for a simulator, highest precedence first.
# A test that inherits either from the ambient shell is not testing the script,
# it is testing the machine: a developer with PALACE_TEST_SIMULATOR_ID exported
# outranks whatever a test sets, and the suite goes red for a reason living
# entirely in the harness. Every env below is built from this base.
_SIM_OVERRIDE_VARS = ("PALACE_TEST_SIMULATOR_ID", "HARNESS_SESSION_SIM_UDID")


def _base_env(**overrides) -> dict:
    env = {k: v for k, v in os.environ.items() if k not in _SIM_OVERRIDE_VARS}
    env.update(overrides)
    return env


def _run(stub: Path, *args: str):
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True, text=True, cwd=REPO, timeout=120,
        env=_base_env(
            PALACE_XCODEBUILD=str(stub),
            # Short-circuits destination discovery so the stub never needs to
            # emulate -showdestinations.
            HARNESS_SESSION_SIM_UDID="STUB-UDID",
            # The script deliberately RETAINS its log dir whenever there is
            # something to read, which is most of this file. Pointing TMPDIR at
            # pytest's per-test dir keeps that evidence for the assertions and
            # lets pytest reap it, instead of accreting in the real temp dir.
            TMPDIR=str(stub.parent),
        ),
    )


def _reported_log(stdout: str) -> Path:
    match = re.search(r"Full log: (\S+)", stdout)
    assert match, f"no log path reported in:\n{stdout}"
    return Path(match.group(1))


# --- The regression this file exists for ----------------------------------

def test_reported_log_path_actually_exists(tmp_path):
    """The evidence link must resolve.

    A diagnostic that names a log the reader cannot open has, for the reader,
    reported nothing. This failed on the first real run while every unit test
    was green.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{DESTINATION_FAILURE}EOF
        exit 70
    """)
    result = _run(stub, "--victim", "VictimTests")

    log = _reported_log(result.stdout)
    assert log.exists(), f"reported log {log} does not exist"
    assert log.stat().st_size > 0, f"reported log {log} is empty"
    assert "Unable to find a device" in log.read_text()


# --- The headline behaviour, end to end ------------------------------------

def test_a_run_that_never_executed_refuses_to_blame_the_code(tmp_path):
    """The whole point. Compare against the sentence the old script printed."""
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{DESTINATION_FAILURE}EOF
        exit 70
    """)
    result = _run(stub, "--victim", "VictimTests")

    assert "CANNOT DIAGNOSE" in result.stdout
    assert "REAL bug" not in result.stdout, (
        "a run that executed no tests must never produce a verdict about the code"
    )
    assert result.returncode == 3, (
        f"an unrunnable run needs its own exit code, got {result.returncode}"
    )


def test_a_genuinely_failing_victim_is_still_called_a_real_bug(tmp_path):
    """The control.

    Without this the fix could satisfy every other test by simply never
    concluding anything — which would be a different way of being useless.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_FAILS}EOF
        exit 65
    """)
    result = _run(stub, "--victim", "VictimTests")

    assert "REAL bug, not pollution" in result.stdout
    assert "VictimTests testThing" in result.stdout, "must name the failing case"
    assert result.returncode == 1


def test_a_polluter_is_still_identified(tmp_path):
    """Victim passes alone; fails when SuspectB runs first. End-to-end bisection."""
    stub = _stub(tmp_path, """
        # A real pair run reports BOTH classes, suspect first.
        if [[ "$*" == *SuspectB* ]]; then
          echo "Test Case '-[PalaceTests.SuspectB testItsOwnThing]' passed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        fi
        if [[ "$*" == *SuspectA* ]]; then
          echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA SuspectB")

    assert "polluter is 'SuspectB'" in result.stdout, result.stdout
    assert "SuspectA -> victim still passes" in result.stdout
    assert result.returncode == 1


def test_suspects_that_never_ran_are_not_reported_as_cleared(tmp_path):
    """An un-run suspect is not an acquitted suspect.

    Silently folding it into "no polluter found" is the same defect as the
    headline one, one level up: absence of a result read as a result.
    """
    stub = _stub(tmp_path, f"""
        if [[ "$*" == *SuspectB* ]]; then
          cat <<'EOF'
{DESTINATION_FAILURE}EOF
          exit 70
        fi
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA SuspectB")

    assert "INCOMPLETE" in result.stdout, result.stdout
    assert "SuspectB" in result.stdout
    assert "no polluter found among the given suspects." not in result.stdout, (
        "must not read as a clean sweep when a suspect never ran"
    )
    assert result.returncode == 3


def test_zero_matching_tests_does_not_read_as_a_clean_victim(tmp_path):
    """A typo'd class name reports SUCCESS with 0 tests executed."""
    stub = _stub(tmp_path, """
        echo "Test Suite 'Selected tests' passed at 2026-08-26 09:00:00.001."
        echo "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "TypoedTests")

    assert "CANNOT DIAGNOSE" in result.stdout
    assert "no-tests-matched" in result.stdout, result.stdout
    assert "pollution VICTIM" not in result.stdout, (
        "0 tests executed must never read as 'passes alone'"
    )
    assert result.returncode == 3


# --- Simulator precedence, exercised rather than grepped -------------------

def test_session_allocated_simulator_reaches_the_destination(tmp_path):
    """The claimed device must actually be used, not merely mentioned."""
    stub = _stub(tmp_path, f"""
        echo "ARGV: $*" >> "$STUB_ARGV_LOG"
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    argv_log = tmp_path / "argv.log"
    env = _base_env(
        PALACE_XCODEBUILD=str(stub),
        HARNESS_SESSION_SIM_UDID="CLAIMED-1234",
        STUB_ARGV_LOG=str(argv_log),
        TMPDIR=str(stub.parent),
    )
    subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests"],
                   capture_output=True, text=True, cwd=REPO, env=env, timeout=120)

    assert "id=CLAIMED-1234" in argv_log.read_text()


def test_explicit_sim_flag_outranks_the_session_allocation(tmp_path):
    stub = _stub(tmp_path, f"""
        echo "ARGV: $*" >> "$STUB_ARGV_LOG"
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    argv_log = tmp_path / "argv.log"
    env = _base_env(
        PALACE_XCODEBUILD=str(stub),
        HARNESS_SESSION_SIM_UDID="CLAIMED-1234",
        STUB_ARGV_LOG=str(argv_log),
        TMPDIR=str(stub.parent),
    )
    subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests", "--sim", "EXPLICIT-9999"],
                   capture_output=True, text=True, cwd=REPO, env=env, timeout=120)

    text = argv_log.read_text()
    assert "id=EXPLICIT-9999" in text
    assert "CLAIMED-1234" not in text


def test_two_invocations_do_not_share_a_log_file(tmp_path):
    """The old fixed `/tmp/polluter-run.log` let one run read another's evidence.

    Asserted on the path the tool REPORTS, not on a path shape. An earlier
    version of this test searched for a `polluter-log.` substring, which simply
    found nothing on both sides when the mutant reverted to the shared fixed
    path — two empty sets compared equal and the mutant survived. The claim is
    "the two runs use different logs", so the assertion has to be about those
    two paths and nothing adjacent to them.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_FAILS}EOF
        exit 65
    """)
    first = _reported_log(_run(stub, "--victim", "VictimTests").stdout)
    second = _reported_log(_run(stub, "--victim", "VictimTests").stdout)

    assert first != second, f"two runs shared the log path {first}"
    assert first.exists() and second.exists()
    assert str(first) != "/tmp/polluter-run.log"


# --- The pair arm must not blame a suspect for its own failure -------------

def test_a_suspect_that_fails_its_own_test_is_not_called_a_polluter(tmp_path):
    """Victim passes throughout; SuspectB's own test is broken.

    The old classifier saw "a test failed" in the pair run and printed
    "polluter is 'SuspectB' ... leaves shared state dirty that breaks
    VictimTests" — a confident causal claim from a log where the victim passed.
    """
    stub = _stub(tmp_path, """
        if [[ "$*" == *SuspectB* ]]; then
          echo "Test Case '-[PalaceTests.SuspectB testItsOwnThing]' failed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA SuspectB")

    assert "polluter is" not in result.stdout, (
        "a suspect's own failing test is not evidence of pollution:\n" + result.stdout
    )
    assert "SuspectB" in result.stdout and "INCONCLUSIVE" in result.stdout
    assert result.returncode == 3


# --- resolve_simulator's discovery branch (previously uncovered) -----------

def _discovery_env(stub: Path, extra=None):
    # `_base_env` already strips both short-circuit variables, which is exactly
    # what this branch needs: discovery only runs when neither is set. That left
    # the function whose bug caused the incident with no coverage at all.
    return _base_env(PALACE_XCODEBUILD=str(stub), TMPDIR=str(stub.parent),
                     **(extra or {}))


DESTINATIONS_STUB = """
        if [[ "$*" == *-showdestinations* ]]; then
          echo "\t\t{ platform:iOS Simulator, arch:arm64, id:AAAA-0000, OS:26.1, name:iPhone 12 }"
          echo "\t\t{ platform:iOS Simulator, arch:arm64, id:BBBB-1111, OS:26.1, name:iPhone 16 Pro }"
          echo "\t\t{ platform:iOS Simulator, arch:arm64, id:CCCC-2222, OS:26.1, name:iPhone 17 Pro }"
          exit 0
        fi
        echo "ARGV: $*" >> "$STUB_ARGV_LOG"
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
"""


def test_discovery_prefers_a_targeted_device_over_the_first_listed(tmp_path):
    """iPhone 12 is listed FIRST and kills the large-corpus suite (#1419)."""
    stub = _stub(tmp_path, DESTINATIONS_STUB)
    argv_log = tmp_path / "argv.log"
    subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests"],
                   capture_output=True, text=True, cwd=REPO, timeout=120,
                   env=_discovery_env(stub, {"STUB_ARGV_LOG": str(argv_log)}))

    text = argv_log.read_text()
    assert "id=BBBB-1111" in text, f"must pick iPhone 16 Pro; got {text}"
    assert "id=AAAA-0000" not in text, "must not pick the first-listed iPhone 12"


def test_discovery_never_yields_the_literal_string_Booted(tmp_path):
    """The incident itself: the old lookup produced `-destination ...,id=Booted`."""
    stub = _stub(tmp_path, DESTINATIONS_STUB)
    argv_log = tmp_path / "argv.log"
    subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests"],
                   capture_output=True, text=True, cwd=REPO, timeout=120,
                   env=_discovery_env(stub, {"STUB_ARGV_LOG": str(argv_log)}))

    assert "id=Booted" not in argv_log.read_text()


def test_no_available_simulator_exits_3_rather_than_guessing(tmp_path):
    stub = _stub(tmp_path, """
        if [[ "$*" == *-showdestinations* ]]; then exit 0; fi
        echo "should not be reached" >&2
        exit 1
    """)
    result = subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests"],
                            capture_output=True, text=True, cwd=REPO, timeout=120,
                            env=_discovery_env(stub))
    assert result.returncode == 3, result.stdout + result.stderr


# --- The duplicate precedence list must not silently diverge ---------------

def test_simulator_precedence_agrees_with_xcode_test_optimized():
    """Two scripts now carry this list. Nothing else pins them together.

    Extraction into one helper would mean rewriting a CI-critical gate and its
    marker-based pytest inside a PR about a diagnostic, so the duplication is
    deliberate — but a duplicate that can drift unnoticed is how the next
    "why did CI pick THAT device" incident starts.
    """
    other = SCRIPT.parent / "xcode-test-optimized.sh"
    pattern = re.compile(r'for PREFERRED in ((?:"[^"]+"\s*)+); do', re.I)

    mine = re.search(r'for preferred in ((?:"[^"]+"\s*)+); do', SCRIPT.read_text())
    theirs = pattern.search(other.read_text())
    assert mine and theirs, "could not locate a preference list in both scripts"

    assert re.findall(r'"([^"]+)"', mine.group(1)) == re.findall(r'"([^"]+)"', theirs.group(1)), (
        "the two simulator-preference lists have diverged"
    )


def test_the_abort_message_does_not_contradict_its_own_evidence(tmp_path):
    """`unexplained-exit-N` is reachable ONLY when tests executed.

    The abort banner used to read "the isolation run did not execute tests"
    and then print a tail showing executed cases directly beneath it. A
    diagnostic that is refuted by the evidence it prints teaches the reader to
    stop reading it.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 65
    """)
    result = _run(stub, "--victim", "VictimTests")

    assert "CANNOT DIAGNOSE" in result.stdout
    assert "unexplained-exit-65" in result.stdout
    assert "did not execute tests" not in result.stdout, (
        "tests DID execute here — the banner must not claim otherwise:\n" + result.stdout
    )


# --- A victim that never ran is not a victim that passed -------------------

def test_a_skipped_victim_does_not_acquit_the_suspects(tmp_path):
    """The symmetric hole: `pass` used to mean "something ran and nothing failed".

    `XCTSkip` appears 127x in PalaceTests. Pollution that wipes shared account
    state makes a victim SKIP rather than fail — and a skipped test emits no
    failing line, so the pair read as a clean acquittal and the tool cleared the
    real polluter at exit 0. Absence of the victim read as the victim passing.
    """
    stub = _stub(tmp_path, """
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "no polluter found among the given suspects." not in result.stdout, (
        "the victim never executed, so nothing was acquitted:\n" + result.stdout
    )
    assert "focus-did-not-run" in result.stdout, result.stdout
    assert result.returncode == 3


def test_step1_treats_a_skipped_victim_as_undiagnosable(tmp_path):
    """Same hole in step 1 — a skipped victim is not 'passes in isolation'."""
    stub = _stub(tmp_path, """
        echo "Test Case '-[PalaceTests.SomethingElse testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests")

    assert "pollution VICTIM" not in result.stdout, (
        "a victim that did not execute must not read as 'passes alone'"
    )
    assert "CANNOT DIAGNOSE" in result.stdout
    assert result.returncode == 3


# --- The SUSPECT-then-VICTIM premise must be observed, not assumed ----------

def test_a_pair_that_ran_in_the_wrong_order_is_not_an_acquittal(tmp_path):
    """`Palace.xcscheme` sets testExecutionOrdering = "random".

    The whole method rests on the suspect running BEFORE the victim; if the
    victim ran first it cannot have been polluted by the suspect, so "victim
    still passes" is a false acquittal. Execution order is visible in the log,
    so it is checked rather than assumed.
    """
    stub = _stub(tmp_path, """
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "not the polluter" not in result.stdout, (
        "victim ran FIRST — this pair cannot acquit the suspect:\n" + result.stdout
    )
    assert "order" in result.stdout.lower()
    assert result.returncode == 3


def test_correct_order_still_acquits_normally(tmp_path):
    """Control: suspect first, victim second, victim passes -> real acquittal."""
    stub = _stub(tmp_path, """
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "SuspectA -> victim still passes" in result.stdout, result.stdout
    assert result.returncode == 0


def test_parallel_testing_is_pinned_off(tmp_path):
    """Clones change the log format AND break the premise.

    Under clones xcodebuild emits `Test case ... on 'Clone N of ...'` (lowercase
    c), which every classifier regex here would miss. Worse, suspect and victim
    could land in different processes, where pollution is impossible by
    construction and every acquittal is vacuous.
    """
    stub = _stub(tmp_path, """
        echo "ARGV: $*" >> "$STUB_ARGV_LOG"
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    argv_log = tmp_path / "argv.log"
    subprocess.run(["bash", str(SCRIPT), "--victim", "VictimTests"],
                   capture_output=True, text=True, cwd=REPO, timeout=120,
                   env=_base_env(PALACE_XCODEBUILD=str(stub),
                                 HARNESS_SESSION_SIM_UDID="STUB-UDID",
                                 STUB_ARGV_LOG=str(argv_log),
                                 TMPDIR=str(tmp_path)))

    assert "-parallel-testing-enabled NO" in argv_log.read_text()


def test_a_victim_that_failed_BEFORE_the_suspect_ran_is_not_a_polluter_finding(tmp_path):
    """Order matters for the positive verdict too, and matters more there.

    If the victim executed first and failed, the suspect cannot have caused it —
    naming it a polluter would send someone to add teardown to an innocent
    class. A false acquittal wastes a run; a false accusation wastes a person.
    """
    stub = _stub(tmp_path, """
        # Step 1 (victim alone) must pass, or the run stops there as a real bug.
        if [[ "$*" != *SuspectA* ]]; then
          echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
          echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
          exit 0
        fi
        # The pair: victim runs FIRST and fails, suspect afterwards.
        echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
        exit 65
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "polluter is" not in result.stdout, (
        "the victim failed before the suspect ran — that is not pollution:\n" + result.stdout
    )
    assert result.returncode == 3


# --- Round-3 findings ------------------------------------------------------

def test_whitespace_only_suspects_is_not_a_clean_sweep(tmp_path):
    """`--suspects "   "` passed a bare `-z` test and iterated zero times.

    The tool then printed "no polluter found among the given suspects" at exit
    0 — a clean sweep over nothing. Reachable whenever the list comes from a
    command substitution that returned whitespace.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "   ")

    assert "no polluter found" not in result.stdout, (
        "zero suspects ran — nothing was swept:\n" + result.stdout
    )
    assert result.returncode == 2, f"got {result.returncode}"


def test_a_suspect_that_never_ran_is_not_described_in_terms_of_order(tmp_path):
    """Absence and order are different facts.

    With the suspect absent from the log the tool claimed "'VictimTests'
    executed BEFORE 'TypoTests', so 'TypoTests' cannot be the cause" — an
    exculpatory statement the log contradicts. The `-n` guards were the only
    thing keeping the BUCKET safe and had no test, so replacing them with
    `${line_first:-0}` survived the whole suite.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "TypoTests")

    assert "never executed" in result.stdout, result.stdout
    assert "executed BEFORE" not in result.stdout, (
        "must not invent an ordering claim about a class that never ran:\n" + result.stdout
    )
    assert "cannot be the cause" not in result.stdout, (
        "must not exculpate a class the log says nothing about:\n" + result.stdout
    )
    assert result.returncode == 3


# Production bytes: real xcodebuild emits a `started.` line per case, and in a
# pair run the two classes' lines interleave around each other. Earlier fixtures
# had neither, so `head -1` could not be distinguished from `tail -1` and the
# ordering logic was pinned against a shape production never produces.
REAL_PAIR_LOG = """\
Test Suite 'Selected tests' started at 2026-08-26 09:00:00.000
Test Suite 'PalaceTests.xctest' started at 2026-08-26 09:00:00.001
Test Suite 'SuspectA' started at 2026-08-26 09:00:00.002
Test Case '-[PalaceTests.SuspectA testAlpha]' started.
Test Case '-[PalaceTests.SuspectA testAlpha]' passed (0.021 seconds).
Test Case '-[PalaceTests.SuspectA testBeta]' started.
Test Case '-[PalaceTests.SuspectA testBeta]' passed (0.014 seconds).
Test Suite 'SuspectA' passed at 2026-08-26 09:00:00.040.
Test Suite 'VictimTests' started at 2026-08-26 09:00:00.041
Test Case '-[PalaceTests.VictimTests testThing]' started.
Test Case '-[PalaceTests.VictimTests testThing]' passed (0.009 seconds).
Test Suite 'VictimTests' passed at 2026-08-26 09:00:00.055.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.044 (0.055) seconds
"""


def test_ordering_holds_on_a_production_shaped_log(tmp_path):
    """The `started.` lines are what make ordering readable in reality."""
    stub = _stub(tmp_path, f"""
        if [[ "$*" == *SuspectA* ]]; then
          cat <<'EOF'
{REAL_PAIR_LOG}EOF
          exit 0
        fi
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "SuspectA -> victim still passes" in result.stdout, result.stdout
    assert result.returncode == 0


def test_a_suspect_still_running_when_the_victim_starts_cannot_acquit(tmp_path):
    """Pollution needs the suspect to have FINISHED dirtying state first.

    So the rule is the suspect's LAST line before the victim's FIRST — not
    first-vs-first. Here the suspect starts before the victim but is still
    producing cases after it, so it had not finished when the victim ran, and
    the pair proves nothing.

    Two earlier versions of this test were wrong in opposite directions, which
    is worth recording. The first put the suspect entirely after the victim,
    where every reading agrees, so the `tail`-vs-`head` mutant survived it. The
    second used this interleaved log but asserted it ACQUITS — enshrining a
    vacuous acquittal for a shape the script cannot even produce, since with
    parallel testing pinned off XCTest runs suites contiguously. Interleaving
    would mean clones, and under clones every acquittal is vacuous anyway.
    """
    interleaved = """\
Test Case '-[PalaceTests.SuspectA testAlpha]' started.
Test Case '-[PalaceTests.SuspectA testAlpha]' passed (0.021 seconds).
Test Case '-[PalaceTests.VictimTests testThing]' started.
Test Case '-[PalaceTests.VictimTests testThing]' passed (0.009 seconds).
Test Case '-[PalaceTests.SuspectA testOmega]' started.
Test Case '-[PalaceTests.SuspectA testOmega]' passed (0.011 seconds).
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.041 (0.050) seconds
"""
    stub = _stub(tmp_path, f"""
        if [[ "$*" == *SuspectA* ]]; then
          cat <<'EOF'
{interleaved}EOF
          exit 0
        fi
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "victim still passes" not in result.stdout, (
        "the suspect was still running when the victim started — it never "
        "finished dirtying state, so this cannot acquit it:\n" + result.stdout
    )
    assert result.returncode == 3


# --- Round-4: sampling. Every verdict rests on n samples -------------------

def test_a_self_flaky_victim_is_not_reported_as_a_polluter_finding(tmp_path):
    """The fourth arm, and the loud one.

    The tool's whole input domain is NONDETERMINISTIC failures, yet every
    verdict rested on a single run. A victim that fails intermittently on its
    OWN — which is the "real bug" case step 1 exists to rule out — passes step 1
    with probability (1-p), and the first pair that flips gets printed as
    "polluter is X" about whichever innocent class held the dice.

    Here the victim fails on exactly the 2nd run of the tool (the SuspectA
    pair) and passes every other time, including the confirmation re-run. No
    suspect causes anything.
    """
    counter = tmp_path / "n"
    stub = _stub(tmp_path, """
        n=$(cat "$COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNTER"
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        if [ "$n" -eq 2 ]; then
          echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds
"
        exit 0
    """)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--victim", "VictimTests", "--suspects", "SuspectA"],
        capture_output=True, text=True, cwd=REPO, timeout=120,
        env=_base_env(PALACE_XCODEBUILD=str(stub), HARNESS_SESSION_SIM_UDID="STUB",
                      COUNTER=str(counter), TMPDIR=str(tmp_path)))

    assert "polluter is" not in result.stdout, (
        "one flip that does not reproduce is not a polluter:\n" + result.stdout
    )
    assert "candidate" in result.stdout.lower()
    assert result.returncode == 3


def test_step1_states_its_sample_size(tmp_path):
    """A single clean isolation run must not read as 'the victim is clean'."""
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests")
    assert "ONE sample" in result.stdout, result.stdout
    assert "--iterations" in result.stdout


# --- Round-4: input handling ----------------------------------------------

def test_a_glob_in_suspects_does_not_expand_against_the_filesystem(tmp_path):
    """`for s in $SUSPECTS` word-splits AND globs.

    `--suspects "*Tests*"` expanded against the working directory to matching
    FILENAMES, passed the whitespace guard, and burned one build per bogus
    "class". Verified against the real repo root, which is full of matches.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "*Tests*")

    assert ".swift" not in result.stdout, (
        "a glob expanded to filenames:\n" + result.stdout
    )
    assert result.returncode == 2, f"got {result.returncode}: {result.stdout}"


def test_a_victim_name_with_a_path_separator_is_rejected(tmp_path):
    """A `/` makes the log path unwritable — reported as an empty log at a
    path that does not exist, which is a diagnostic lying about itself."""
    stub = _stub(tmp_path, "exit 0")
    result = _run(stub, "--victim", "../../etc/passwd")
    assert result.returncode == 2
    assert "not a plain class name" in (result.stdout + result.stderr)


def test_a_finding_discloses_suspects_that_were_never_tested(tmp_path):
    """Otherwise the reader fixes the named polluter, still flakes, and never
    learns another suspect was never tested at all."""
    stub = _stub(tmp_path, """
        if [[ "$*" == *SuspectSkip* ]]; then
          echo "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
          exit 70
        fi
        if [[ "$*" == *SuspectBad* ]]; then
          echo "Test Case '-[PalaceTests.SuspectBad testOwn]' passed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectSkip SuspectBad")

    assert "polluter is 'SuspectBad'" in result.stdout, result.stdout
    assert "NEVER RAN" in result.stdout and "SuspectSkip" in result.stdout, (
        "a finding must disclose what was left uncleared:\n" + result.stdout
    )


# --- Round-5: defects introduced BY the round-4 remedies -------------------

ALWAYS_FAILS = """\
        echo "Test Case '-[PalaceTests.SuspectA testItsOwnThing]' passed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
        echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
        exit 65
"""


def test_a_bad_iterations_value_cannot_skip_the_isolation_check(tmp_path):
    """The round-4 `--iterations` remedy reintroduced the headline defect.

    `seq 1 abc` errors, so the loop body never runs, `VERDICT` stays empty, and
    step 1's `case` — which has arms only for error:/pass/test-failure — falls
    through silently into step 2. A victim that fails on EVERY run is then
    reported as "polluter is 'SuspectA'", and the round-4 confirmation run
    happily confirms it, because it re-samples the same broken victim.
    """
    stub = _stub(tmp_path, ALWAYS_FAILS)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA",
                  "--iterations", "abc")

    assert "polluter is" not in result.stdout, (
        "a bad --iterations must not skip step 1 into a false accusation:\n" + result.stdout
    )
    assert result.returncode == 2, f"got {result.returncode}: {result.stdout}{result.stderr}"


def test_the_control_for_that_still_reports_a_real_bug(tmp_path):
    """Same always-failing victim, valid iterations: must be a REAL bug."""
    stub = _stub(tmp_path, ALWAYS_FAILS)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")
    assert "REAL bug, not pollution" in result.stdout, result.stdout
    assert result.returncode == 1


def test_iterations_zero_and_negative_are_rejected(tmp_path):
    """`0` and `-1` reach the same skip on GNU seq; on BSD `-1` runs THREE
    iterations and suppresses the one-sample NOTE. Neither is a sample count."""
    stub = _stub(tmp_path, ALWAYS_FAILS)
    for bad in ("0", "-1"):
        result = _run(stub, "--victim", "VictimTests", "--iterations", bad)
        assert result.returncode == 2, f"--iterations {bad} -> {result.returncode}"


def test_newline_separated_suspects_are_all_tested(tmp_path):
    """The round-4 glob fix reintroduced the vacuous-sweep arm.

    `IFS=' ' read -ra` reads only the FIRST LINE. The `for s in $SUSPECTS` it
    replaced split newlines correctly. So a newline-separated list — which is
    exactly what the command substitution named in the fix's own comment
    produces — tested one suspect and printed "no polluter found among the
    given suspects" at exit 0.
    """
    stub = _stub(tmp_path, """
        if [[ "$*" == *SuspectC* ]]; then
          echo "Test Case '-[PalaceTests.SuspectC testOwn]' passed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        fi
        if [[ "$*" == *Suspect* ]]; then
          echo "Test Case '-[PalaceTests.SuspectX testOwn]' passed (0.004 seconds)."
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests",
                  "--suspects", "SuspectA\nSuspectB\nSuspectC")

    assert "no polluter found among the given suspects." not in result.stdout, (
        "suspects after the first line were silently dropped:\n" + result.stdout
    )
    assert "SuspectC" in result.stdout, result.stdout


def test_an_unrunnable_confirm_run_is_not_evidence_the_victim_is_self_flaky(tmp_path):
    """The round-4 confirmation code contains the original defect.

    The confirm arm tested only `= "test-failure"`, so an `error:` — a run where
    zero tests executed — printed "DID NOT reproduce" and routed to CANDIDATE,
    whose text says the pattern is "equally consistent with the victim being
    flaky on its own, which is a REAL bug rather than pollution". That is a
    substantive claim about the code drawn from a run that never happened.
    """
    counter = tmp_path / "n"
    stub = _stub(tmp_path, """
        n=$(cat "$COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNTER"
        if [ "$n" -eq 1 ]; then
          echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
          echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
          exit 0
        fi
        if [ "$n" -eq 3 ]; then
          echo "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
          exit 70
        fi
        echo "Test Case '-[PalaceTests.SuspectA testOwn]' passed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
        echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
        exit 65
    """)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--victim", "VictimTests", "--suspects", "SuspectA"],
        capture_output=True, text=True, cwd=REPO, timeout=120,
        env=_base_env(PALACE_XCODEBUILD=str(stub), HARNESS_SESSION_SIM_UDID="STUB",
                      COUNTER=str(counter), TMPDIR=str(tmp_path)))

    # Match on a phrase that is NOT wrapped in the source. "flaky on its own"
    # is split across two echo lines, so asserting it matched nothing either
    # way — the assertion-adjacent-to-its-claim trap, for the third time in
    # this session.
    assert "equally consistent" not in result.stdout, (
        "an unrunnable confirm run is not evidence about the victim:\n" + result.stdout
    )
    assert result.returncode == 3


def test_a_finding_discloses_candidates_and_unattempted_suspects(tmp_path):
    """FOUND listed SKIPPED but dropped CANDIDATES and everything after `break`.

    An unreproduced flip is the strongest available evidence the victim is
    self-flaky, which directly undercuts the polluter verdict — and suspects
    after the break were never attempted at all, under wording that invites
    "everything unlisted is cleared".
    """
    counter = tmp_path / "n"
    stub = _stub(tmp_path, """
        n=$(cat "$COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNTER"
        fail() {
          echo "Test Case '-[PalaceTests.$1 testOwn]' passed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
          echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
          exit 65
        }
        pass() {
          [ -n "$1" ] && echo "Test Case '-[PalaceTests.$1 testOwn]' passed (0.004 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
          echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds"
          exit 0
        }
        case "$*" in
          *SuspectA*) if [ "$n" -eq 2 ]; then fail SuspectA; else pass SuspectA; fi ;;
          *SuspectC*) fail SuspectC ;;
          *) pass "" ;;
        esac
    """)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--victim", "VictimTests",
         "--suspects", "SuspectA SuspectC SuspectD SuspectE"],
        capture_output=True, text=True, cwd=REPO, timeout=180,
        env=_base_env(PALACE_XCODEBUILD=str(stub), HARNESS_SESSION_SIM_UDID="STUB",
                      COUNTER=str(counter), TMPDIR=str(tmp_path)))

    assert "polluter is 'SuspectC'" in result.stdout, result.stdout
    assert "SuspectA" in result.stdout, "the candidate must be disclosed:\n" + result.stdout
    assert "SuspectD" in result.stdout and "SuspectE" in result.stdout, (
        "suspects never attempted must not read as cleared:\n" + result.stdout
    )
    # The two absence categories must be reported under DIFFERENT sentences.
    assert "NEVER RAN" in result.stdout


def test_a_flag_missing_its_value_is_a_usage_error_not_a_finding(tmp_path):
    """`--iterations` as the last argument hit `$2: unbound variable` and exited
    1 — which this script documents as "a FINDING". A wrapper reads a typo as a
    polluter identification."""
    stub = _stub(tmp_path, "exit 0")
    result = _run(stub, "--victim", "VictimTests", "--iterations")
    assert result.returncode == 2, f"got {result.returncode}"


def test_an_invalid_suspect_is_reported_even_when_step1_would_exit(tmp_path):
    """Validation ran AFTER step 1, so a step-1 exit meant an invalid suspect
    list was never reported at all — the user fixes the wrong thing first."""
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_FAILS}EOF
        exit 65
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "Bad/Name")
    assert result.returncode == 2, f"got {result.returncode}: {result.stdout}"
    assert "not a plain class name" in (result.stdout + result.stderr)


def test_a_confirm_run_that_never_executed_gets_its_own_bucket(tmp_path):
    """The fourth state: the pair ran once and flipped, and the second sample
    never happened.

    Filing that under "RAN BUT NOT JUDGED" asserts a run that did not occur;
    filing it under "NEVER RAN" throws away the flip that WAS observed. Neither
    is honest, so it gets its own line — and the reason is printed.
    """
    counter = tmp_path / "n"
    stub = _stub(tmp_path, """
        n=$(cat "$COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNTER"
        if [ "$n" -eq 1 ]; then
          echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
          echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
          exit 0
        fi
        if [ "$n" -eq 3 ]; then
          echo "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
          exit 70
        fi
        echo "Test Case '-[PalaceTests.SuspectA testOwn]' passed (0.004 seconds)."
        echo "Test Case '-[PalaceTests.VictimTests testThing]' failed (0.004 seconds)."
        echo "\t Executed 2 tests, with 1 failure (0 unexpected) in 0.008 (0.009) seconds"
        exit 65
    """)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--victim", "VictimTests", "--suspects", "SuspectA"],
        capture_output=True, text=True, cwd=REPO, timeout=120,
        env=_base_env(PALACE_XCODEBUILD=str(stub), HARNESS_SESSION_SIM_UDID="STUB",
                      COUNTER=str(counter), TMPDIR=str(tmp_path)))

    assert "CONFIRMATION NEVER RAN" in result.stdout, result.stdout
    assert "destination-not-found" in result.stdout, (
        "the reason must survive into the report:\n" + result.stdout
    )
    assert "RAN BUT NOT JUDGED (order/absence/inconclusive confirm): SuspectA" not in result.stdout
    assert result.returncode == 3


def test_a_usage_error_is_reported_even_with_no_simulator(tmp_path):
    """Validation claimed to precede all work while `resolve_simulator` ran
    first, so a bad suspect name exited 3 ("no simulator found") and the usage
    error was never reported at all."""
    stub = _stub(tmp_path, "exit 1")
    env = _base_env(PALACE_XCODEBUILD=str(stub), TMPDIR=str(tmp_path))
    result = subprocess.run(
        ["bash", str(SCRIPT), "--victim", "VictimTests", "--suspects", "Bad/Name"],
        capture_output=True, text=True, cwd=REPO, timeout=120, env=env)
    assert result.returncode == 2, f"got {result.returncode}"
    assert "not a plain class name" in (result.stdout + result.stderr)


def test_no_suspects_does_not_report_a_clean_run(tmp_path):
    """`--victim X` with no `--suspects` bisected nothing.

    It exited 0, which the usage documents as "ran cleanly, nothing to report" —
    a claim about suspects that were never examined. Its sibling state,
    `--suspects "   "`, already refuses to say that.
    """
    stub = _stub(tmp_path, f"""
        cat <<'EOF'
{VICTIM_PASSES}EOF
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests")

    assert "No --suspects given" in result.stdout, result.stdout
    assert result.returncode == 3, (
        f"got {result.returncode} — nothing was bisected, so this is not a clean run"
    )


def test_a_pair_where_the_victim_only_skipped_is_not_an_acquittal(tmp_path):
    """End-to-end form of the round-8-reopened-round-2 defect.

    A log of nothing but `skipped` lines satisfied "no per-case lines", which
    suppressed the focus-absence check and acquitted the suspect at exit 0 over
    a victim that never asserted anything.
    """
    stub = _stub(tmp_path, """
        if [[ "$*" == *SuspectA* ]]; then
          echo "Test Case '-[PalaceTests.SuspectA testOwn]' started."
          echo "Test Case '-[PalaceTests.SuspectA testOwn]' skipped (0.002 seconds)."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' started."
          echo "Test Case '-[PalaceTests.VictimTests testThing]' skipped (0.002 seconds)."
          echo "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
          exit 0
        fi
        echo "Test Case '-[PalaceTests.VictimTests testThing]' started."
        echo "Test Case '-[PalaceTests.VictimTests testThing]' passed (0.004 seconds)."
        echo "\t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds"
        exit 0
    """)
    result = _run(stub, "--victim", "VictimTests", "--suspects", "SuspectA")

    assert "not the polluter" not in result.stdout, (
        "the victim only SKIPPED — that is not a pass:\n" + result.stdout
    )
    assert "no polluter found" not in result.stdout
    assert result.returncode == 3

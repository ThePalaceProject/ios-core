#!/usr/bin/env python3
"""Pytest for the whole-run scan mode of scripts/ci-test-history.py.

WHY THIS MODE EXISTS. `ci-test-history.py <TestName>` answers "is THIS failure
ours?" — it needs the name first. That is a lookup, and it only helps once
someone already suspects a test. The failures that matter most are the ones
nobody suspects, because the run they live in reported GREEN:
`-retry-tests-on-failure -test-iterations 3` relaunches the plan on a failure
and reports success if a later iteration is clean. Nothing in the verdict, the
check name, or the job summary says a test failed on the way there.

Measured on run 32508244803 (PR #1404, conclusion=success): NINE distinct tests
failed an iteration, two of them on the borrow/auth critical path, and one —
TPPNetworkResponderAuthCoordinatorTests.testResponder_401_completion_fires… —
failed only on iteration THREE after passing 1 and 2. Any scan that reads early
iterations and stops never sees it, so the tests below pin the final-iteration
case specifically.

THE GUARD IS THE POINT OF HALF THIS FILE. A detector that answers "0 tests
failed" for an empty log is worse than no detector: its all-clear is
indistinguishable from its I-have-no-data. That is not hypothetical — the first
run of this logic scanned a log that had silently downloaded as zero bytes
(`gh run view --log` needs `--repo` outside a checkout) and cheerfully reported
a clean run. `scan_run` must REFUSE input it cannot have measured.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-test-history.py"

spec = importlib.util.spec_from_file_location("ci_test_history", SCRIPT)
cth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cth)


def line(cls: str, method: str, verdict: str, clone: int = 1, secs: str = "0.004") -> str:
    return (f"Test case '{cls}.{method}()' {verdict} on "
            f"'Clone {clone} of iPhone 16 Pro - Palace (37115)' ({secs} seconds)")


def clean_log(n_tests: int = 60, iterations: int = 1) -> str:
    out = []
    for it in range(iterations):
        for i in range(n_tests):
            out.append(line("QuietTests", f"testQuiet{i}", "passed", clone=it + 1))
    return "\n".join(out)


# ---------------------------------------------------------------- finding

def test_scan_findsTestThatFailedOneOfThreeIterations():
    log = clean_log(60, iterations=3) + "\n" + "\n".join([
        line("BookReturnCleverReauthTests", "testReturn_MarksStale", "passed"),
        line("BookReturnCleverReauthTests", "testReturn_MarksStale", "failed", secs="30.1"),
        line("BookReturnCleverReauthTests", "testReturn_MarksStale", "passed"),
    ])
    found = cth.scan_log(log)
    assert "BookReturnCleverReauthTests.testReturn_MarksStale" in found
    assert found["BookReturnCleverReauthTests.testReturn_MarksStale"] == ["passed", "failed", "passed"]


def test_scan_findsFailureOnTheFINALIteration():
    """The #1404 case a naive early-iteration read misses entirely."""
    log = clean_log(60, iterations=3) + "\n" + "\n".join([
        line("TPPNetworkResponderAuthCoordinatorTests", "testResponder_401", "passed"),
        line("TPPNetworkResponderAuthCoordinatorTests", "testResponder_401", "passed"),
        line("TPPNetworkResponderAuthCoordinatorTests", "testResponder_401", "failed", secs="62.0"),
    ])
    assert "TPPNetworkResponderAuthCoordinatorTests.testResponder_401" in cth.scan_log(log)


def test_scan_omitsTestsThatPassedEveryIteration():
    assert cth.scan_log(clean_log(60, iterations=3)) == {}


def test_scan_recognisesSerialXcodebuildForm():
    log = clean_log(60) + "\n" + (
        "Test Case '-[PalaceTests.AdobeActivationDedupTests test_ensureDeviceActivated]' "
        "failed (120.003 seconds).")
    assert "AdobeActivationDedupTests.test_ensureDeviceActivated" in cth.scan_log(log)


def test_scan_doesNotTreatAnExpectedFailureAsAFailure():
    """XCTExpectFailure is a passing outcome; counting it would cry wolf forever."""
    log = clean_log(60) + "\n" + (
        "Test case 'HermeticityTests.testExpected()' recorded an expected failure on "
        "'Clone 1 of iPhone 16 Pro - Palace (37115)'")
    assert cth.scan_log(log) == {}


# ---------------------------------------------------------------- shape

def test_logShape_distinguishesAOneIterationRunFromAThreeIterationOne():
    """Why it matters: both print the same green verdict, but the clean run
    sampled every test ONCE. Identical argv, one third the flake-detection
    power — so 'zero failures' from a 1x run is not evidence of health."""
    assert cth.log_shape(clean_log(60, iterations=1)) == (60, 60)
    assert cth.log_shape(clean_log(60, iterations=3)) == (180, 60)


# ---------------------------------------------------------------- the guard

@pytest.mark.parametrize("junk", ["", "   \n\n", "##[group]Run actions/checkout@v4\nnothing here\n"])
def test_scan_run_REFUSES_a_logWithNoTestResults(junk):
    with pytest.raises(cth.NotATestLog):
        cth.scan_run(junk)


def test_scan_run_refusalIsDistinguishableFromACleanRun():
    """The whole failure mode in one assertion: an empty log and a healthy log
    must not produce the same answer."""
    healthy = cth.scan_run(clean_log(200, iterations=3))
    assert healthy == {}
    with pytest.raises(cth.NotATestLog):
        cth.scan_run("")


def test_scan_run_acceptsARealSizedLogAndStillFindsTheFailure():
    log = clean_log(200, iterations=3) + "\n" + "\n".join([
        line("TPPAlertUtilsTests", "testPresentAlert", "failed", secs="5.0"),
        line("TPPAlertUtilsTests", "testPresentAlert", "passed"),
        line("TPPAlertUtilsTests", "testPresentAlert", "passed"),
    ])
    assert list(cth.scan_run(log)) == ["TPPAlertUtilsTests.testPresentAlert"]


# ------------------------------------------------- depth is per test, not per run

def test_depthHistogram_showsMixedDepthsInsteadOfAveragingThem():
    """A single mean hides the thing you need to see.

    Raised by a peer against the first version of this output, and true of the
    very run it was built on: 32508244803 prints 2.9x on average while a handful
    of its tests were sampled ONCE. `-test-iterations` relaunches the plan, but
    which tests a relaunch actually re-runs is not uniform — so one number for a
    whole run averages a 1x-sampled test into a 3x-sampled crowd and reports the
    crowd. That is the same defect as a regex that returns a plausible smaller
    number instead of an error: an answer whose shape hides its own gap.
    """
    log = "\n".join(
        [line("DeepTests", f"testDeep{i}", "passed", clone=it + 1)
         for it in range(3) for i in range(50)]
        + [line("ShallowTests", f"testShallow{i}", "passed") for i in range(4)]
    )
    assert cth.depth_histogram(log) == {3: 50, 1: 4}


def test_depthHistogram_isEmptyForAnEmptyLog():
    assert cth.depth_histogram("") == {}


def test_scan_run_reportsThinlySampledTestsEvenWhenTheMeanLooksHealthy():
    """The mean here is 2.85x — comfortably 'deep' — yet 4 tests got one sample."""
    log = "\n".join(
        [line("DeepTests", f"testDeep{i}", "passed", clone=it + 1)
         for it in range(3) for i in range(50)]
        + [line("ShallowTests", f"testShallow{i}", "passed") for i in range(4)]
    )
    execs, distinct = cth.log_shape(log)
    assert execs / distinct > 2.8
    assert cth.depth_histogram(log)[1] == 4


# ------------------------------------------- the same hole, in LOOKUP mode

def test_lookup_distinguishesAnUnreadableLogFromAMissingTest():
    """Raised by a peer against the lookup half after the scan half was fixed.

    `gh` failing returns an empty string, `results_for` finds nothing, and the
    run line prints "(test not in this run)" — which is also what a renamed or
    never-registered test looks like, and this tool's own docstring warns that
    such a test "silently runs nowhere, which looks identical to passing". So
    the failure mode the tool exists to name was reachable through its own
    error path. The refusal floor belongs on both halves.
    """
    assert cth.log_is_readable(clean_log(200, iterations=3)) is True
    for junk in ("", "   \n", "##[group]Run actions/checkout@v4\n"):
        assert cth.log_is_readable(junk) is False


def test_lookup_readableCheckDoesNotDependOnFindingTheTest():
    """A readable log with none of THIS test in it is a real 'not in this run'."""
    assert cth.log_is_readable(clean_log(200)) is True
    assert cth.results_for(clean_log(200), "SomeOtherTests", None) == []

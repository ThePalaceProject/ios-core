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

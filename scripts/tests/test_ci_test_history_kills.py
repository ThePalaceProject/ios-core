#!/usr/bin/env python3
"""Pytest for allowance-kill labelling in scripts/ci-test-history.py (PP-5273).

WHY. A test that runs past its execution-time allowance is killed by XCTest and
reported as an ordinary `failed` iteration whose duration is exactly the
allowance (120.000 s by default, a whole number of minutes when a test raises
its own). On 2026-09-29 almost every CI run lost one or two DIFFERENT tests
that way. The spindumps showed the killed test was usually not the cause: a
log pipe that stopped draining blocked every clone that logged, or a clone's
app sat suspended at launch. Reported as "FAILED AN ITERATION", each kill reads
as the named test's own defect and invites a fix in the wrong place.

So the scan labels a kill as `killed`, keeps counting it as a failure, and
reports it under its own heading.

prior-art-checked: extends the existing scan in scripts/ci-test-history.py and
its pytest suite; no harness capability parses xcodebuild result lines.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-test-history.py"

spec = importlib.util.spec_from_file_location("ci_test_history", SCRIPT)
cth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cth)


def line(cls: str, method: str, verdict: str, secs: str) -> str:
    return (f"Test case '{cls}.{method}()' {verdict} on "
            f"'Clone 1 of iPhone 16 Pro - Palace (37115)' ({secs} seconds)")


def serial_line(cls: str, method: str, verdict: str, secs: str) -> str:
    return f"Test Case '-[PalaceTests.{cls} {method}]' {verdict} ({secs} seconds)."


# ------------------------------------------------------- the per-iteration rule

def test_iterationVerdict_failureAtTheDefaultAllowance_isAKill():
    assert cth.iteration_verdict("failed", "120.000") == "killed"


def test_iterationVerdict_failureAtARaisedAllowance_isAKill():
    # A test may raise its own allowance; the kill then lands on that whole minute.
    assert cth.iteration_verdict("failed", "180.000") == "killed"


def test_iterationVerdict_ordinaryFailure_staysAFailure():
    assert cth.iteration_verdict("failed", "30.100") == "failed"


def test_iterationVerdict_failureJustUnderTheAllowance_staysAFailure():
    assert cth.iteration_verdict("failed", "119.999") == "failed"


def test_iterationVerdict_slowFailureOffTheMinute_staysAFailure():
    # Past 120 s but not on a whole minute: the test failed on its own, slowly.
    assert cth.iteration_verdict("failed", "125.400") == "failed"


def test_iterationVerdict_passAtTheAllowance_isStillAPass():
    assert cth.iteration_verdict("passed", "120.000") == "passed"


# ------------------------------------------------------------------ the scan

def test_scan_labelsAKillInTheParallelForm():
    log = "\n".join([
        line("MockBackendIntegrationTests", "testBorrow_Returns201", "failed", "120.000"),
        line("MockBackendIntegrationTests", "testBorrow_Returns201", "passed", "0.020"),
    ])
    assert cth.scan_log(log) == {"MockBackendIntegrationTests.testBorrow_Returns201": ["killed", "passed"]}


def test_scan_labelsAKillInTheSerialForm():
    log = serial_line("RuntimeQuiescenceGateTests", "testProbe", "failed", "120.000")
    assert cth.scan_log(log) == {"RuntimeQuiescenceGateTests.testProbe": ["killed"]}


def test_scan_stillReportsATestWhoseOnlyBadIterationIsAKill():
    # A kill is still a failed iteration; dropping it would turn a red run green.
    log = line("OPDSParsingTests", "testFeedParsingPerformance", "failed", "120.000")
    assert "OPDSParsingTests.testFeedParsingPerformance" in cth.scan_log(log)


def test_scan_keepsAnOrdinaryFailureAsAFailure():
    log = line("LCPFulfillmentHandlerTests", "testHeartbeat", "failed", "0.195")
    assert cth.scan_log(log) == {"LCPFulfillmentHandlerTests.testHeartbeat": ["failed"]}


# ----------------------------------------------------------------- the label

def test_failureLabel_allKills_isReportedAsKilledAtTheTimeLimit():
    assert cth.failure_label(["killed", "passed"]) == "KILLED AT THE TIME LIMIT"


def test_failureLabel_anyOrdinaryFailure_isReportedAsFailedAnIteration():
    # A real failure outranks a kill: the test has at least one failure of its own.
    assert cth.failure_label(["killed", "failed"]) == "FAILED AN ITERATION"
    assert cth.failure_label(["failed", "passed"]) == "FAILED AN ITERATION"


# ------------------------------------------------------------- the log cache

def test_logCachePath_differsBetweenAttemptsOfTheSameRun():
    # A re-run replaces a run's log. Keyed on the run id alone, the cache kept
    # serving attempt 1 after attempt 2 finished: on 2026-09-30 a scan of run
    # 36596835929 reported attempt 1's single debouncer failure and missed the
    # two allowance kills attempt 2 contained.
    first = cth.log_cache_path("ThePalaceProject/ios-core", 36596835929, 1)
    second = cth.log_cache_path("ThePalaceProject/ios-core", 36596835929, 2)
    assert first != second


def test_logCachePath_isStableForTheSameAttempt():
    a = cth.log_cache_path("ThePalaceProject/ios-core", 1, 3)
    b = cth.log_cache_path("ThePalaceProject/ios-core", 1, 3)
    assert a == b

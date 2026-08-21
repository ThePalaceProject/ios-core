#!/usr/bin/env python3
"""Pytest for the node walker in scripts/parse-xcresult.py.

WHAT THIS FILE IS ANCHORED ON. Every node literal below is copied verbatim from
`xcrun xcresulttool get test-results tests` against a real Palace
TestResults.xcresult, and every claimed consequence was read out of the
`test-data.json` this parser actually published for CI run 32508244803 (PR
#1404). Nothing here is a reconstruction of what the API "probably" emits — a
fixture that does not match production bytes turns a green test into a vacuous
one, and the first defect below is precisely a case-sensitivity mismatch that
only real bytes reveal.

THE DEFECTS, as published on that run:

1. `nodeType` is **"Unit test bundle"** — lowercase t, lowercase b. The walker's
   container-exclusion list said "Unit Test Bundle", so bundle nodes fell
   through to the is-this-a-test check, which accepts anything carrying a
   result. The published report therefore contained a class named "Palace" with
   two "tests" called PalaceTests and TenPrintCoverTests. A bundle's result is
   the rollup of everything under it, so PalaceTests was marked **Failure** and
   counted in `summary.failed`. `ci-parity-local.sh` gates on
   `summary.failed > 0` and would name `Palace/PalaceTests` as a failing test.

2. Retry repetitions are emitted as test METHODS. The same run reported
   failures for `TPPNetworkResponderAuthCoordinatorTests.Retry 2`,
   `AccountsManagerCatalogLoadJoinTests.Retry 1` and
   `AccountsManagerStateMachineWiringTests.First Run` — names that identify no
   test, cannot be re-run, and cannot be handed to find-test-polluter.sh. Four
   of that run's five "failed tests" named nothing runnable.

3. Meanwhile the REAL methods whose iterations failed were published as ✅.
   AdobeActivationDedupTests showed 8 passed / 0 failed while
   test_ensureDeviceActivated_whenRMSDKNeverCallsBack failed its third
   iteration; BookReturnCleverReauthTests showed 1/1/0 with a failed second.
   The retry contract deliberately treats those runs as passes — that is not in
   dispute and `summary.failed` keeps that meaning here — but a reader is told
   nothing happened at all.

4. `result: "Expected Failure"` is a real value the result map did not know.
   Such a test is neither passed nor failed, so it lands in the total and in no
   other bucket: 8215 + 5 + 140 = 8360 against a published total of 8361.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "parse-xcresult.py"

spec = importlib.util.spec_from_file_location("parse_xcresult", SCRIPT)
pxr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pxr)


def case(name, result, children=None, duration=0.001):
    node = {"name": name, "nodeType": "Test Case", "result": result,
            "duration": f"{duration}s", "durationInSeconds": duration,
            "nodeIdentifier": f"SomeTests/{name}"}
    if children:
        node["children"] = children
    return node


def tree(*suite_children, bundle_result="Passed"):
    """The real shape: Test Plan -> Unit test bundle -> Test Suite -> Test Case."""
    return {
        "name": "Palace", "nodeType": "Test Plan", "result": "Passed",
        "children": [{
            "name": "PalaceTests", "nodeType": "Unit test bundle",
            "result": bundle_result,
            "children": [{
                "name": "SomeTests", "nodeType": "Test Suite", "result": bundle_result,
                "children": list(suite_children),
            }],
        }],
    }


def methods(tests):
    return {t["method"] for t in tests}


# ------------------------------------------------------- 1. the bundle node

def test_unitTestBundleNode_isNotEmittedAsATest():
    tests = pxr.parse_test_node_new_api(tree(case("testReal()", "Passed")))
    assert methods(tests) == {"testReal"}, "bundle/plan nodes must not become tests"


def test_bundleRollupFailure_isNotCountedAsAFailingTest():
    """A bundle whose rollup is Failed made `summary.failed` name a non-test."""
    tests = pxr.parse_test_node_new_api(
        tree(case("testReal()", "Passed"), bundle_result="Failed"))
    assert [t for t in tests if t["status"] == "Failure"] == []
    assert "PalaceTests" not in methods(tests)


# ------------------------------------------------------- 2/3. repetitions

REPETITIONS = [
    {"name": "First Run", "nodeType": "Test Case Run", "result": "Passed"},
    {"name": "Retry 1", "nodeType": "Test Case Run", "result": "Passed"},
    {"name": "Retry 2", "nodeType": "Test Case Run", "result": "Failed"},
]


def test_repetitionNodes_areNotEmittedAsTestMethods():
    tests = pxr.parse_test_node_new_api(
        tree(case("testResponder_401()", "Passed", children=REPETITIONS)))
    assert methods(tests) == {"testResponder_401"}
    assert not any(m in methods(tests) for m in ("First Run", "Retry 1", "Retry 2"))


def test_aTestWhoseRetryFailed_keepsItsRealNameAndIsMarkedFlaky():
    tests = pxr.parse_test_node_new_api(
        tree(case("testResponder_401()", "Passed", children=REPETITIONS)))
    t = tests[0]
    assert t["method"] == "testResponder_401"
    assert t["iterations"] == ["Success", "Success", "Failure"]
    assert t["flaky"] is True


def test_flakyDoesNotChangeTheGateStatus():
    """`ci-parity-local.sh` exits on summary.failed; a retried-then-passed test
    is a pass by that contract and must stay one. Visibility, not a new gate."""
    tests = pxr.parse_test_node_new_api(
        tree(case("testResponder_401()", "Passed", children=REPETITIONS)))
    assert tests[0]["status"] == "Success"


def test_aTestThatFailedEveryIteration_isStillAFailure():
    allfail = [dict(r, result="Failed") for r in REPETITIONS]
    tests = pxr.parse_test_node_new_api(
        tree(case("testAlwaysBroken()", "Failed", children=allfail)))
    assert tests[0]["status"] == "Failure"
    assert tests[0]["flaky"] is False, "failing every time is broken, not flaky"


def test_aCleanTestIsNotMarkedFlaky():
    tests = pxr.parse_test_node_new_api(tree(case("testQuiet()", "Passed")))
    assert tests[0]["flaky"] is False


# ------------------------------------------------------- 4. failure messages

REAL_FAILURE_CHILD = {"name": "awaitCondition is driven to timeout by design here",
                      "nodeType": "Failure Message"}


def test_failureMessages_areAttachedToTheirTest():
    """Verbatim from a real bundle. Without this the report can say WHICH test
    failed and never WHY — the 20MB CI log carries no failure text either, so
    the message existed in the xcresult and reached no reader."""
    tests = pxr.parse_test_node_new_api(
        tree(case("testAwaitCondition()", "Failed", children=[REAL_FAILURE_CHILD])))
    assert tests[0]["failures"] == [{"message": "awaitCondition is driven to timeout by design here"}]


def test_failureMessageNodes_areNotThemselvesTests():
    tests = pxr.parse_test_node_new_api(
        tree(case("testAwaitCondition()", "Failed", children=[REAL_FAILURE_CHILD])))
    assert methods(tests) == {"testAwaitCondition"}


# ------------------------------------------------------- 5. expected failure

def test_expectedFailure_isNormalisedAndNotSilentlyUncounted():
    """8215 passed + 5 failed + 140 skipped = 8360 against a published total of
    8361. The missing one is an Expected Failure the result map did not know."""
    tests = pxr.parse_test_node_new_api(tree(case("testExpected()", "Expected Failure")))
    assert tests[0]["status"] == "ExpectedFailure"
    counted = pxr.count_by_status(tests)
    assert counted["expected_failures"] == 1
    assert counted["passed"] + counted["failed"] + counted["skipped"] \
        + counted["expected_failures"] == len(tests)


def test_countByStatus_addsUpForAMixedTree():
    tests = pxr.parse_test_node_new_api(tree(
        case("testA()", "Passed"), case("testB()", "Failed"),
        case("testC()", "Skipped"), case("testD()", "Expected Failure")))
    c = pxr.count_by_status(tests)
    assert (c["passed"], c["failed"], c["skipped"], c["expected_failures"]) == (1, 1, 1, 1)


def test_repetitionsAreRecognisedByNAME_evenWhenTheNodeTypeIsUnknown():
    """The names are the evidenced half; the nodeType is the inferred half.

    `Retry 2`, `Retry 1` and `First Run` were read out of the test-data.json
    this parser published for run 32508244803 — that is production evidence.
    The nodeType those nodes carry is NOT: no local bundle here contains a
    retry, so "Test Case Run" is an educated guess. A first pass tested only
    the guess, and a mutant that disabled name matching survived: the branch
    resting on real evidence was the untested one. If Apple's nodeType differs
    from the guess, name matching is the whole defence.
    """
    reps = [{"name": n, "nodeType": "Something Else Entirely", "result": r}
            for n, r in (("First Run", "Passed"), ("Retry 1", "Passed"), ("Retry 2", "Failed"))]
    tests = pxr.parse_test_node_new_api(tree(case("testResponder_401()", "Passed", children=reps)))
    assert methods(tests) == {"testResponder_401"}
    assert tests[0]["iterations"] == ["Success", "Success", "Failure"]
    assert tests[0]["flaky"] is True

"""Tests for scripts/xcresult_summary.py.

THE FIXTURES HERE ARE COPIED FROM A REAL XCRESULT, NOT INVENTED. The first
version of this file was hand-written from an assumed shape, passed eight
tests, and guarded a `failing_classes` that returned an empty list against
every real bundle — because a FAILED test case is not a leaf (its children are
`Failure Message` nodes) and the passing result string is `Passed`, not
`Success`. Anything added here should be checked against
`xcrun xcresulttool get test-results tests --path <bundle> --format json`
before being trusted.

Shape, verified against Xcode 26:
  root                       {testNodes: [...]}          (no nodeType)
    Test Plan                {children: [...]}
      Unit test bundle       {children: [...]}
        Test Suite           {children: [...]}   <- the class
          Test Case          {children: [...]}   <- the test; children only when failed
            Failure Message  {}
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from xcresult_summary import (  # noqa: E402
    failing_classes,
    failing_test_names,
    tally,
    tally_label,
    totals,
)


def _case(name, result, failures=()):
    node = {"name": name, "nodeType": "Test Case", "result": result}
    if failures:
        node["children"] = [
            {"name": m, "nodeType": "Failure Message"} for m in failures
        ]
    return node


def _tree(*suites):
    return {
        "testNodes": [{
            "name": "Palace", "nodeType": "Test Plan", "result": "Failed",
            "children": [{
                "name": "PalaceTests", "nodeType": "Unit test bundle", "result": "Failed",
                "children": list(suites),
            }],
        }],
    }


def _suite(name, *cases):
    result = "Failed" if any(c["result"] == "Failed" for c in cases) else "Passed"
    return {"name": name, "nodeType": "Test Suite", "result": result, "children": list(cases)}


# MARK: - tally

def test_tally_reads_the_authoritative_counts():
    assert tally({"passedTests": 8246, "failedTests": 7}) == (8246, 7)


def test_tally_treats_missing_counts_as_zero_rather_than_crashing():
    assert tally({}) == (0, 0)


def test_failing_test_names_are_reported_in_order():
    assert failing_test_names({"testFailures": [{"testName": "b()"}, {"testName": "a()"}]}) == ["b()", "a()"]


# MARK: - failing_classes

def test_a_failed_case_with_failure_message_children_still_names_its_class():
    """The regression this module exists for: failed cases are NOT leaves."""
    tree = _tree(_suite(
        "NotificationServiceTokenTests",
        _case("testRegistrationClaims_releaseAllowsARetry()", "Failed",
              failures=["NotificationServiceTokenTests.swift:249: XCTAssertTrue failed",
                        "NotificationServiceTokenTests.swift:252: XCTAssertTrue failed"]),
        _case("testTokenData_tokenType_isAlwaysFCMiOS()", "Passed"),
    ))
    assert failing_classes(tree) == ["NotificationServiceTokenTests"]


def test_the_containing_bundle_is_never_reported_as_a_class():
    """`PalaceTests` and `Palace` are Failed too, but neither is -only-testable."""
    tree = _tree(_suite("GeneralCacheTests", _case("testSet()", "Failed", failures=["x"])))
    assert failing_classes(tree) == ["GeneralCacheTests"]


def test_a_fully_passing_run_names_no_classes():
    tree = _tree(_suite("OKTests", _case("testFine()", "Passed")))
    assert failing_classes(tree) == []


def test_classes_are_deduplicated_and_sorted():
    tree = _tree(
        _suite("ZTests", _case("t1()", "Failed", failures=["x"]), _case("t2()", "Failed", failures=["y"])),
        _suite("ATests", _case("t3()", "Failed", failures=["z"])),
    )
    assert failing_classes(tree) == ["ATests", "ZTests"]


def test_a_class_whose_name_does_not_end_in_Tests_is_still_found_via_nodeType():
    """Keying on nodeType rather than a name regex is what makes this work."""
    tree = _tree(_suite("LegacyRegistrySpec", _case("testThing()", "Failed", failures=["x"])))
    assert failing_classes(tree) == ["LegacyRegistrySpec"]


def test_without_nodeType_it_degrades_to_a_path_guess_rather_than_silence():
    tree = {"testNodes": [{
        "name": "Palace",
        "children": [{
            "name": "PalaceTests",
            "children": [{
                "name": "BookRegistrySyncTests",
                "children": [{"name": "test_a()", "nodeType": "Test Case", "result": "Failed"}],
            }],
        }],
    }]}
    assert failing_classes(tree) == ["BookRegistrySyncTests"]


# --- totals / tally_label -----------------------------------------------------
#
# These exist because `verify-pr.sh` printed `tally`'s FIRST number under the
# word "tests", i.e. reported the passed count as the suite size. The numbers
# below are copied from a real bundle (verify-pr-38813.xcresult, PP-4951): the
# gate said "8454 tests" while the suite held 8471.

REAL_SUMMARY = {
    "totalTestCount": 8471,
    "passedTests": 8454,
    "failedTests": 1,
    "skippedTests": 14,
    "expectedFailures": 2,
}


def test_totals_reports_the_suite_size_not_the_passed_count():
    total, passed, failed, skipped, xfail = totals(REAL_SUMMARY)
    assert total == 8471, "the suite size must come from totalTestCount"
    assert passed == 8454
    assert (failed, skipped, xfail) == (1, 14, 2)
    assert total != passed, (
        "the whole defect is that these two were conflated; a fixture where they "
        "coincide would pass while the bug was reinstated"
    )


def test_tally_label_names_every_count_it_prints():
    label = tally_label(REAL_SUMMARY)
    assert label == "8471 tests (8454 passed, 1 failed, 14 skipped, 2 expected-failure)"
    assert "8471 tests" in label, "the number next to 'tests' must be the total"
    assert not label.startswith("8454"), (
        "regression guard: the passed count must never lead the label, which is "
        "what made a local run look smaller than CI's and read as a lost target"
    )


def test_tally_label_omits_zero_skips_and_expected_failures():
    # A clean run should not carry noise, but must still name passed and failed.
    assert tally_label(
        {"totalTestCount": 10, "passedTests": 10, "failedTests": 0}
    ) == "10 tests (10 passed, 0 failed)"


def test_totals_survives_a_summary_missing_the_optional_keys():
    # Older bundles omit skippedTests/expectedFailures entirely.
    assert totals({"totalTestCount": 3, "passedTests": 3}) == (3, 3, 0, 0, 0)


def test_tally_is_unchanged_for_existing_callers():
    # `tally` is still the (passed, failed) pair; totals() was added beside it
    # rather than changing its arity, because other call sites read $1 and $2.
    assert tally(REAL_SUMMARY) == (8454, 1)

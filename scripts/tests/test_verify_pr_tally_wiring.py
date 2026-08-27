"""verify-pr.sh must actually USE the labelled tally, not merely have it available.

WHY THIS FILE EXISTS. `xcresult_summary.tally()` returns (passed, failed).
`verify-pr.sh` printed its first number under the word "tests", so the gate
reported the PASSED count as the suite size — on one real bundle, "8493 tests"
for a suite of 8512 (8493 passed, 1 failed, 16 skipped, 2 expected failures).

A local figure BELOW CI's is the wrong direction: it reads as an excluded test
target, and it cost a reviewer round chasing one that did not exist.

`test_xcresult_summary.py` pins the label FUNCTION. This file pins the WIRING,
because a correct function the gate never calls is inert — the repository has a
standing wall entry for exactly that shape.
"""
import os
import re

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_VERIFY_PR = os.path.join(_ROOT, "scripts", "verify-pr.sh")


def _source() -> str:
    with open(_VERIFY_PR, encoding="utf-8") as fh:
        return fh.read()


def test_verify_pr_invokes_the_label_mode():
    assert "--mode label" in _source(), (
        "verify-pr.sh must ask xcresult_summary.py for the labelled tally; "
        "without this call the label function exists and changes nothing"
    )


def test_no_unit_test_record_prints_the_passed_count_as_the_suite_size():
    # The original defect, in every form it appeared: "$TEST_PASS tests".
    offenders = [
        line.strip()
        for line in _source().splitlines()
        if re.search(r"\$TEST_PASS tests", line)
    ]
    assert not offenders, (
        "these lines report the passed count under the word 'tests':\n  "
        + "\n  ".join(offenders)
    )


def test_every_unit_tests_record_uses_the_labelled_tally():
    # There were ten record sites and the fix had to reach all of them; a single
    # missed site is a gate that misreports on exactly one branch of its logic.
    records = [
        line.strip()
        for line in _source().splitlines()
        if 'record "unit_tests"' in line and "skip" not in line
    ]
    assert records, "expected to find unit_tests record sites"
    missing = [r for r in records if "$TEST_TALLY" not in r]
    assert not missing, (
        "these unit_tests records do not use the labelled tally:\n  "
        + "\n  ".join(missing)
    )


def test_there_is_a_fallback_when_the_xcresult_is_absent():
    # The stdout-scrape path knows passed and failed but NOT the suite size, so
    # it must say so rather than imply a total it cannot know.
    src = _source()
    assert 'if [ -z "$TEST_TALLY" ]' in src, "no fallback guard for a missing xcresult"
    assert "suite size unknown" in src, (
        "the fallback must state that the suite size is unknown rather than "
        "silently presenting passed+failed as though they were the whole suite"
    )

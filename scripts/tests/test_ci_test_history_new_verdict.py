#!/usr/bin/env python3
"""
test_ci_test_history_new_verdict.py — the NEW verdict must not accuse a diff of
a failure the runner caused.

prior-art-checked: a repo-local pytest in the established `scripts/tests/test_*.py`
family, testing `scripts/ci-test-history.py`, which has no other test. The
harness tools surfaced at capture time (memory files, glyphs push, SoD checks)
solve unrelated problems and none of them can assert a verdict this script
prints to a developer.

WHY THIS EXISTS. `ci-test-history.py` is the instrument used to decide whether a
red board is the branch's fault or someone else's — the CI contract in CLAUDE.md
routes every flake-vs-regression call through it. Its NEW verdict does not
merely report; it instructs: "This branch introduced it. Fix the change, not the
environment."

Measured 2026-09-11: it gave that instruction to a branch containing two files,
a shell script and a pytest, with zero Swift. The test it named,
`RemoteFeatureFlagsTests.testWithTimeout_boundsANonCancellableHangingOperation`,
had 46 passing samples at a 0.217s median and ONE failure at 4.851s — 22x the
median — against a 2.0s wall-clock assertion. The diff could not reach Swift
execution at all. The verdict was literally true (it did fail only there) and
its conclusion pointed the reader at their own diff for an hour.

Branch-exclusivity is not causation. These assert the qualification in BOTH
directions: a real branch signature must still be named plainly, or the fix
would trade a false accusation for a false acquittal — which is worse, since an
unaccused regression ships.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "ci-test-history.py"


def _load():
    spec = importlib.util.spec_from_file_location("ci_test_history", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = _load()
classify = MOD.classify_new_failure


# --------------------------------------------------------------- the incident
def test_the_measured_incident_is_not_called_a_branch_signature():
    """46 passes at 0.217s, one failure at 4.851s — the real numbers."""
    assert classify([0.217] * 46, [4.851]) == "duration-outlier"


def test_a_wall_clock_outlier_is_named_even_with_several_failures():
    """Repetition of a load event is still a load event, not a signature."""
    assert classify([0.2] * 20, [4.0, 5.0, 6.0]) == "duration-outlier"


# ------------------------------------------------------- the opposite error
# A qualification that fires on everything would trade a false accusation for a
# false acquittal. An unaccused regression ships; a wrongly accused diff costs
# an hour. The second is the cheaper mistake, so these matter more.


def test_a_same_speed_failure_is_still_a_branch_signature():
    """The defining case: it fails FAST, so the machine is not the suspect."""
    assert classify([0.20] * 20, [0.21] * 3) == "branch-signature"


def test_repeated_slightly_slower_failures_are_still_accused():
    """
    Ordinary variance must not buy an acquittal: 2x is under the 5x threshold,
    and three failures are not a single unlucky sample.

    (A SINGLE 2x failure is `thin-evidence` instead — see below. That is the
    honest reading: one sample is thin whatever its duration, and the thin
    message says "widen with --limit", not "this branch introduced it".)
    """
    assert classify([0.20] * 20, [0.40, 0.38, 0.41]) == "branch-signature"


def test_a_single_slightly_slower_failure_is_thin_not_a_signature():
    """One sample is thin regardless of duration — neither accuse nor excuse."""
    assert classify([0.20] * 20, [0.40]) == "thin-evidence"


def test_a_crash_that_fails_faster_than_it_passes_is_accused():
    """An early throw runs quicker than the real work — must not read as load."""
    assert classify([1.0] * 15, [0.01] * 4) == "branch-signature"


# ------------------------------------------------------------ thin evidence
def test_one_failure_against_many_passes_is_called_thin():
    """One loss in a large sample is not a branch signature, even if fast."""
    assert classify([0.20] * 30, [0.22]) == "thin-evidence"


def test_one_failure_against_a_small_sample_is_not_excused():
    """With few passes there is no basis to call a single failure noise."""
    assert classify([0.20] * 3, [0.22]) == "branch-signature"


# ----------------------------------------------------------------- degenerate
# Absence must not render as either verdict. A missing duration is not evidence
# of load, and not evidence of a signature.


@pytest.mark.parametrize(
    "passes,failures",
    [([], [1.0]), ([1.0], []), ([], [])],
)
def test_missing_durations_fall_through_to_the_plain_verdict(passes, failures):
    assert classify(passes, failures) == "branch-signature"


def test_zero_passing_median_cannot_divide_by_zero():
    """A 0.000s median must not raise, nor manufacture an infinite ratio."""
    assert classify([0.0, 0.0], [5.0]) == "branch-signature"


# ------------------------------------------------------------------- wiring
def test_the_verdict_text_actually_consults_the_classifier():
    """
    A classifier nothing calls is indistinguishable from one that always agrees.
    Pin that the NEW branch routes through it rather than re-deriving the rule.
    """
    source = _SCRIPT.read_text()
    assert "classify_new_failure(pass_secs, fail_secs)" in source
    assert "DURATION OUTLIER" in source


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))

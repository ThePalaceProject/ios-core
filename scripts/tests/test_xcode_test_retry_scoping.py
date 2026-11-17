"""Retry scoping in `scripts/xcode-test-optimized.sh`.

`-retry-tests-on-failure` is meant to re-run the tests that FAILED. Adding
`-test-repetition-relaunch-enabled YES` silently converts it into repetition of
the WHOLE plan, so one flaky test re-runs all ~9,100.

MEASURED 2026-09-15, four configurations against one prebuilt bundle, a plan of
one always-failing and three always-passing tests:

    flags                                              failing  passing
    retry + iterations 3 + relaunch YES  (was CI)         3x       3x
    retry + relaunch YES                                  3x       3x
    retry + iterations 3                                  3x       1x
    retry                                                 3x       1x

The retry CAP is 3 in every one of them; only the passing-test count moves. So
`relaunch` is the multiplier and `-test-iterations` is not — the opposite of the
first guess. In CI that difference was 30 minutes vs 53, and a 60-minute step
bound that PR #1472 died against twice.

These tests read the committed flag list rather than running Xcode.
"""

from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "xcode-test-optimized.sh"


def _retry_args_line() -> str:
    for line in SCRIPT.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("RETRY_ITER_ARGS=(-retry-tests-on-failure"):
            return stripped
    raise AssertionError("RETRY_ITER_ARGS assignment not found — did the script move?")


def test_retry_does_not_relaunch_the_whole_plan():
    # The one that costs 23-30 minutes per flaking run.
    assert "-test-repetition-relaunch-enabled" not in _retry_args_line(), (
        "relaunch turns a per-test retry into a whole-plan repetition; "
        "measured 3x on tests that never failed")


def test_retry_on_failure_is_still_requested():
    # The guard must not be satisfiable by deleting the retry safety net.
    assert "-retry-tests-on-failure" in _retry_args_line()


def test_the_iteration_cap_is_still_explicit():
    # `-retry-tests-on-failure` alone assumes a maximum of 3 (man xcodebuild),
    # so this is equivalent — kept because it states the cap and because the
    # CI_TEST_ITERATIONS=1 single-pass path keys off it.
    assert "-test-iterations" in _retry_args_line()


def test_no_other_site_reintroduces_relaunch():
    # Both the parallel leg and the serial isolated leg expand the SAME
    # variable. A second, hand-rolled invocation would reintroduce the cost
    # while the assertions above still passed.
    #
    # Comments are excluded on purpose: the script documents the flag by name
    # and the measurement that removed it, and a guard that forbade NAMING it
    # would force the rationale out of the file it belongs in.
    code = [ln for ln in SCRIPT.read_text(encoding="utf-8").splitlines()
            if not ln.strip().startswith("#")]
    offenders = [ln.strip() for ln in code if "-test-repetition-relaunch-enabled" in ln]
    assert offenders == [], offenders

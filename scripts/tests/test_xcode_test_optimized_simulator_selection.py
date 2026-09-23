"""Simulator selection in `scripts/xcode-test-optimized.sh`.

The local path used to be `head -1` of `-showdestinations` and nothing else.
That is not a cosmetic choice: on this project the first listed device is an
iPhone 12, and the 5000-book `TPPBookRegistryLargeCorpusTests` suite kills an
iPhone 12 clone outright (`Invalid device state` / `Mach error -308 (ipc/mig)
server died`) about ten test cases in, at any load. The same commit and suite
fails on iPhone 12 at load 2.8 and passes on iPhone 17 Pro at load 25 — so the
red was a property of the device the script chose, not of the branch under test,
and it surfaced as a whole-suite failure with no failing assertion.

It also ignored an already-allocated simulator, so concurrent sessions were
handed the same device and collided.

These tests drive the extracted selection logic as a shell fragment with a
stubbed destination list, so they assert the DECISION without launching Xcode.
"""

import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "xcode-test-optimized.sh"

# A destinations list shaped like the real `-showdestinations` output, with the
# problem device deliberately first — which is the actual ordering on this
# project and the reason the old code picked it.
FAKE_DESTINATIONS = """\
{ platform:iOS Simulator, id:AAAA-0000, OS:26.1, name:iPhone 12 }
{ platform:iOS Simulator, id:BBBB-1111, OS:26.1, name:iPhone 16 Pro }
{ platform:iOS Simulator, id:CCCC-2222, OS:26.1, name:iPhone 17 Pro }
"""


def _selection_fragment() -> str:
    """The simulator-selection block, lifted from the script by its markers.

    Read from the real file rather than duplicated, so the test cannot drift
    into asserting a copy that no longer matches what ships.
    """
    text = SCRIPT.read_text()
    start = text.index('SIMULATOR_ID="${PALACE_TEST_SIMULATOR_ID:')
    end = text.index('if [ -z "$SIMULATOR_ID" ]; then\n        echo "❌ No available')
    fragment = text[start:end]
    # Replace the real destinations query with the stub; everything else runs
    # verbatim, including the preference loop and the fallback.
    fragment = re.sub(
        r"DESTINATIONS=\$\(xcodebuild.*?grep -v \"error:\"\)",
        'DESTINATIONS="$FAKE_DESTINATIONS"',
        fragment,
        flags=re.S,
    )
    return fragment


def _run(env: dict, destinations: str = FAKE_DESTINATIONS) -> str:
    # The fixture goes through the ENVIRONMENT, not through the script text.
    # Interpolating it with repr() embeds a literal backslash-n, which bash
    # single-quotes do not expand — the whole list collapses onto one line, the
    # greedy `sed 's/.*id:...'` then matches the LAST id on it, and the test
    # reports a selection the script would never make. That produced a red on
    # the one assertion that matters here, for a reason living entirely in the
    # harness.
    script = (
        "set -u\n"
        + _selection_fragment()
        + '\necho "SELECTED=$SIMULATOR_ID"\n'
    )
    proc = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_DESTINATIONS": destinations,
            **env,
        },
    )
    assert proc.returncode == 0, proc.stderr
    match = re.search(r"SELECTED=(\S*)", proc.stdout)
    assert match, f"no selection emitted: {proc.stdout!r} {proc.stderr!r}"
    return match.group(1)


def test_syntax_is_valid():
    """The whole script must parse — it is committed shell and CI runs bash -n."""
    proc = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


def test_explicit_simulator_id_wins():
    assert _run({"PALACE_TEST_SIMULATOR_ID": "EXPLICIT-9999"}) == "EXPLICIT-9999"


def test_session_allocated_simulator_is_honoured():
    """The collision fix. A session that claimed a device must keep it."""
    assert _run({"HARNESS_SESSION_SIM_UDID": "CLAIMED-1234"}) == "CLAIMED-1234"


def test_explicit_id_outranks_session_allocation():
    selected = _run(
        {"PALACE_TEST_SIMULATOR_ID": "EXPLICIT-9999", "HARNESS_SESSION_SIM_UDID": "CLAIMED-1234"}
    )
    assert selected == "EXPLICIT-9999"


def test_prefers_a_targeted_device_over_the_first_listed():
    """The defect itself. iPhone 12 is listed FIRST and must not be chosen."""
    selected = _run({})
    assert selected == "BBBB-1111", "must pick iPhone 16 Pro, the device CLAUDE.md names"
    assert selected != "AAAA-0000", "must not pick the first-listed iPhone 12"


def test_falls_back_through_the_preference_order():
    """With no iPhone 16 Pro present, the next targeted device is taken."""
    destinations = FAKE_DESTINATIONS.replace(
        "{ platform:iOS Simulator, id:BBBB-1111, OS:26.1, name:iPhone 16 Pro }\n", ""
    )
    assert _run({}, destinations=destinations) == "CCCC-2222"


def test_falls_back_to_first_available_when_no_preferred_device_exists():
    """A contributor with an unusual device set must still get a run, not a crash.

    This is the arm that keeps the change safe for anyone outside this project's
    simulator layout — it reproduces the OLD behaviour exactly.
    """
    destinations = "{ platform:iOS Simulator, id:ZZZZ-8888, OS:26.1, name:iPhone SE (3rd generation) }\n"
    assert _run({}, destinations=destinations) == "ZZZZ-8888"


def test_empty_destination_list_selects_nothing_rather_than_erroring():
    """Selecting nothing is what triggers the script's own fallback block."""
    assert _run({}, destinations="") == ""


@pytest.mark.parametrize("preferred", ["iPhone 16 Pro", "iPhone 17 Pro", "iPhone 16", "iPhone 17"])
def test_preference_list_is_matched_whole_word(preferred):
    """`iPhone 16` must not match `iPhone 16 Pro` and steal its slot.

    Guards the substring bug the trailing space in the grep pattern prevents:
    without it, the `iPhone 16` pass would match the `iPhone 16 Pro` line.
    """
    destinations = f"{{ platform:iOS Simulator, id:MATCH-0001, OS:26.1, name:{preferred} }}\n"
    assert _run({}, destinations=destinations) == "MATCH-0001"

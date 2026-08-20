"""Tests for scripts/sim_tap_on_event.py.

The load-bearing behaviour is not the tap — it is the REFUSAL to let a missed
window look like a negative result. A run where the trigger never fired must be
distinguishable, by exit code and by output, from a run where it fired and the
tap landed. These tests pin that distinction, plus the latency reporting that
tells the operator whether the tap was fast enough to be inside the window at
all.

The event source is injected via --stream-cmd, so no simulator is involved.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "sim_tap_on_event.py"


def run(*extra: str, stream_cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--udid", "TEST-UDID", "--x", "100", "--y", "200",
         "--dry-run", "--stream-cmd", stream_cmd, *extra],
        capture_output=True, text=True,
    )


TRIGGER = ("2026-08-20 11:11:21.135 Df Palace[1:2] [com.apple.CFNetwork:Default] "
           "Task <5848D9C1-33C8-4050-882C-CF807643D0BB>.<1> is for "
           "<org.thepalaceproject.palace>.<org.thepalaceproject.palace.downloadCenterBackgroundIdentifier>")


def test_trigger_fires_and_reports_latency():
    r = run(stream_cmd=f"printf '%s\\n' {json.dumps(TRIGGER)}")
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["triggered"] is True
    # The operator needs this to judge whether the tap could have been inside a
    # window of known width. Reporting the tap without it is not enough.
    assert "latency_s" in out and out["latency_s"] >= 0


def test_trigger_never_fires_is_not_a_negative_result():
    """The whole point: a missed window must not read as 'behaviour absent'."""
    r = run("--timeout", "1", stream_cmd="printf 'unrelated chatter\\n'")
    assert r.returncode == 4, "a missed trigger must not share exit 0 with a real tap"
    out = json.loads(r.stdout)
    assert out["triggered"] is False
    assert "says NOTHING" in out["note"]
    assert "refuted" in r.stderr, "stderr must warn against recording a refutation"


def test_noise_before_the_trigger_does_not_false_fire():
    stream = ("printf '%s\\n' 'noise one' 'Task <X>.<1> is for <com.apple.something>' "
              + json.dumps(TRIGGER))
    r = run(stream_cmd=stream)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    # It must trigger on the app's session, not on any task line that drifts by.
    assert "org.thepalaceproject.palace" in out["trigger_line"]


def test_pattern_is_overridable():
    r = run("--pattern", "MARKER-XYZ", stream_cmd="printf '%s\\n' 'a line with MARKER-XYZ in it'")
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["triggered"] is True


def test_default_pattern_ignores_a_different_bundle():
    # The UUID here must be REAL hex: an obviously-fake `<X>` fails the pattern
    # on the UUID alone, so the test would pass even if the bundle-id half of
    # the pattern were deleted — a fixture that cannot discriminate.
    other = ("2026-08-20 11:11:21.135 Df Other[1:2] [com.apple.CFNetwork:Default] "
             "Task <5848D9C1-33C8-4050-882C-CF807643D0BB>.<1> is for "
             "<com.example.other>.<com.example.other.session>")
    r = run("--timeout", "1", stream_cmd=f"printf '%s\\n' {json.dumps(other)}")
    assert r.returncode == 4, "a different app's download must not trigger the tap"


def test_dry_run_does_not_claim_a_tap():
    r = run(stream_cmd=f"printf '%s\\n' {json.dumps(TRIGGER)}")
    assert json.loads(r.stdout)["tapped"] is False

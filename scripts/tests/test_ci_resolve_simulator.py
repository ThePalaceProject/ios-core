"""Tests for scripts/ci-resolve-simulator.py and for the CI jobs that call it.

The resolver is run as a subprocess against a stub `xcrun` that prints the
JSON `simctl list -j` would print, so the tests exercise the real argument
handling, the exit status and the stdout/stderr split the workflows rely on.

prior-art-checked: tests for a new CI script; the local simulator pool tools
manage developer machines and do not run on GitHub runners.
"""

import json
import os
import pathlib
import subprocess
import textwrap

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci-resolve-simulator.py"

UDID_17_PRO_265 = "AAAAAAAA-0000-0000-0000-000000000265"
UDID_17_PRO_264 = "AAAAAAAA-0000-0000-0000-000000000264"
UDID_16E_262 = "BBBBBBBB-0000-0000-0000-000000000262"


def _runtime(version, available=True, platform="iOS"):
    ident = f"rt.{platform}-{version.replace('.', '-')}"
    return {"identifier": ident, "version": version, "platform": platform,
            "isAvailable": available, "buildversion": "23X1"}


def _device(name, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available}


# Ordered the way simctl orders them: lowest runtime first. The first iPhone
# here is the 16e on 26.2, which is what the old "first iPhone" selection took.
RUNNER_26 = {
    "runtimes": [_runtime("26.2"), _runtime("26.4.1"), _runtime("26.5")],
    "devices": {
        "rt.iOS-26-2": [_device("iPhone 16e", UDID_16E_262)],
        "rt.iOS-26-4-1": [_device("iPhone 17 Pro", UDID_17_PRO_264)],
        "rt.iOS-26-5": [_device("iPhone 17 Pro Max", "CCCCCCCC-0000-0000-0000-000000000001"),
                        _device("iPhone 17 Pro", UDID_17_PRO_265)],
    },
}


def _run(tmp_path, sim, env=None):
    (tmp_path / "runtimes.json").write_text(json.dumps({"runtimes": sim["runtimes"]}))
    (tmp_path / "devices.json").write_text(json.dumps({"devices": sim["devices"]}))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    xcrun = bin_dir / "xcrun"
    xcrun.write_text(textwrap.dedent(f"""\
        #!/bin/bash
        [ "$1 $2 $3" = "simctl list -j" ] || {{ echo "unexpected xcrun $*" >&2; exit 2; }}
        cat "{tmp_path}/$4.json"
        """))
    xcrun.chmod(0o755)
    full_env = {k: v for k, v in os.environ.items() if k not in ("CI_SIM_DEVICE", "CI_SIM_OS")}
    full_env["PATH"] = f"{bin_dir}:{full_env['PATH']}"
    full_env.update(env or {})
    return subprocess.run(["python3", str(SCRIPT)], env=full_env, capture_output=True, text=True)


def test_resolves_the_pinned_device_on_the_pinned_os_not_the_first_iphone(tmp_path):
    result = _run(tmp_path, RUNNER_26)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == UDID_17_PRO_265
    assert "iPhone 17 Pro, iOS 26.5" in result.stderr


def test_the_same_device_on_another_os_is_not_accepted(tmp_path):
    sim = {"runtimes": RUNNER_26["runtimes"][:2],
           "devices": {k: v for k, v in RUNNER_26["devices"].items() if k != "rt.iOS-26-5"}}
    result = _run(tmp_path, sim)
    assert result.returncode == 1
    assert result.stdout == ""
    assert "::error::no available 'iPhone 17 Pro' simulator on iOS 26.5" in result.stderr
    # The failure lists what the runner has, so the next choice is informed.
    assert "iOS 26.4.1: iPhone 17 Pro" in result.stderr
    assert "iOS 26.2: iPhone 16e" in result.stderr


def test_the_os_matches_a_point_release_but_not_a_longer_version(tmp_path):
    ok = _run(tmp_path, RUNNER_26, {"CI_SIM_OS": "26.4"})
    assert ok.returncode == 0 and ok.stdout.strip() == UDID_17_PRO_264
    sim = {"runtimes": [_runtime("26.50")],
           "devices": {"rt.iOS-26-50": [_device("iPhone 17 Pro", "DDDDDDDD-0000-0000-0000-000000000000")]}}
    assert _run(tmp_path, sim).returncode == 1


def test_the_device_name_must_match_exactly(tmp_path):
    sim = {"runtimes": [_runtime("26.5")],
           "devices": {"rt.iOS-26-5": [_device("iPhone 17 Pro Max", UDID_17_PRO_265)]}}
    assert _run(tmp_path, sim).returncode == 1


def test_unavailable_runtimes_and_devices_are_skipped(tmp_path):
    sim = {"runtimes": [_runtime("26.5", available=False)],
           "devices": {"rt.iOS-26-5": [_device("iPhone 17 Pro", UDID_17_PRO_265)]}}
    assert _run(tmp_path, sim).returncode == 1
    sim = {"runtimes": [_runtime("26.5")],
           "devices": {"rt.iOS-26-5": [_device("iPhone 17 Pro", UDID_17_PRO_265, available=False)]}}
    assert _run(tmp_path, sim).returncode == 1


def test_a_non_ios_runtime_with_the_same_version_is_ignored(tmp_path):
    sim = {"runtimes": [_runtime("26.5", platform="tvOS")],
           "devices": {"rt.tvOS-26-5": [_device("iPhone 17 Pro", UDID_17_PRO_265)]}}
    assert _run(tmp_path, sim).returncode == 1


def test_env_overrides_pick_a_different_device(tmp_path):
    result = _run(tmp_path, RUNNER_26, {"CI_SIM_DEVICE": "iPhone 16e", "CI_SIM_OS": "26.2"})
    assert result.returncode == 0 and result.stdout.strip() == UDID_16E_262


CALLERS = [
    ".github/workflows/unit-testing.yml",
    ".github/workflows/tsan.yml",
    ".github/workflows/audiobook-toolkit-tests.yml",
    "scripts/ci-run-test-shard.sh",
]


@pytest.mark.parametrize("path", CALLERS)
def test_every_ci_test_job_resolves_its_simulator_through_the_resolver(path):
    text = (ROOT / path).read_text()
    assert "ci-resolve-simulator.py" in text
    # The "first iPhone in simctl's list" selection is what this replaced.
    assert 'grep "iPhone"' not in text and "grep iPhone" not in text
    for line in text.splitlines():
        if "ci-resolve-simulator.py" in line and "SIMULATOR_ID=" in line:
            assert line.rstrip().endswith("|| exit 1"), line

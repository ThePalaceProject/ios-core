"""Simulator selection in `scripts/xcode-test-optimized.sh`.

The local path used to take the first destination listed. On this project that
was an iPhone 12, and the 5000-book `TPPBookRegistryLargeCorpusTests` suite
kills an iPhone 12 clone outright (`Invalid device state` / `Mach error -308
(ipc/mig) server died`) about ten test cases in, at any load, so the red was a
property of the device the script chose rather than of the branch under test.
It also ignored an already-allocated simulator, so concurrent sessions were
handed the same device and collided.

The local path now takes an explicit id, then a session-allocated one, then the
reference profile's device on its runtime (scripts/reference-toolchain.ini).
These tests run the selection block lifted from the script against a stubbed
`xcrun simctl list -j`, so they assert the decision without launching Xcode.
"""

import json
import re
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "xcode-test-optimized.sh"
HELPER = Path(__file__).resolve().parents[1] / "reference_toolchain.py"


_PROFILE = (
    "[reference]\nrunner_image = test\nxcode_version = 26.3\nxcode_build = 17C529\n"
    "sdk = iphonesimulator26.2\nruntime = iOS 18.5\ndevice = iPhone 16 Pro\n"
    "arch = arm64\nconfiguration = Debug\n")


def _listing(devices_by_runtime: dict) -> str:
    runtimes, devices = [], {}
    for name, devs in devices_by_runtime.items():
        version = name.split()[1]
        ident = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
        runtimes.append({"name": name, "identifier": ident, "version": version, "isAvailable": True})
        devices[ident] = [{"name": n, "udid": u, "state": "Shutdown", "isAvailable": True} for n, u in devs]
    return json.dumps({"runtimes": runtimes, "devices": devices})


# The problem device first, as the real listing orders it; the reference device
# on its runtime; and the same name on a newer runtime.
LISTING = _listing({
    "iOS 18.5": [("iPhone 12", "AAAA-0000"), ("iPhone 16 Pro", "BBBB-1111")],
    "iOS 26.1": [("iPhone 16 Pro", "CCCC-2222"), ("iPhone 17 Pro", "DDDD-3333")],
})


def _selection_fragment() -> str:
    """The simulator-selection block, lifted from the script by its markers.

    Read from the real file rather than duplicated, so the test cannot drift
    into asserting a copy that no longer matches what ships.
    """
    text = SCRIPT.read_text()
    start = text.index('SIMULATOR_ID="${PALACE_TEST_SIMULATOR_ID:')
    end = text.index('if [ -z "$SIMULATOR_ID" ]; then\n        echo "❌ No available')
    return text[start:end]


def _run(env: dict, listing: str = LISTING, tmp_path: Path | None = None):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    xcrun = bin_dir / "xcrun"
    # The fixture goes through the environment, not the script text, so its
    # newlines survive.
    xcrun.write_text('#!/bin/bash\n[ "$1 $2 $3" = "simctl list -j" ] && printf \'%s\' "$STUB_JSON"\n')
    xcrun.chmod(0o755)
    profile = tmp_path / "toolchain.ini"
    profile.write_text(_PROFILE)
    script = "set -u\n" + _selection_fragment() + '\necho "SELECTED=$SIMULATOR_ID"\n'
    proc = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env={"PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
             "STUB_JSON": listing, "TOOLCHAIN_HELPER": str(HELPER),
             "REFERENCE_TOOLCHAIN_CONFIG": str(profile), **env},
    )
    assert proc.returncode == 0, proc.stderr
    match = re.search(r"SELECTED=(\S*)", proc.stdout)
    assert match, f"no selection emitted: {proc.stdout!r} {proc.stderr!r}"
    return match.group(1), proc.stderr


def test_syntax_is_valid():
    proc = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


def test_explicit_simulator_id_wins(tmp_path):
    assert _run({"PALACE_TEST_SIMULATOR_ID": "EXPLICIT-9999"}, tmp_path=tmp_path)[0] == "EXPLICIT-9999"


def test_session_allocated_simulator_is_honoured(tmp_path):
    assert _run({"HARNESS_SESSION_SIM_UDID": "CLAIMED-1234"}, tmp_path=tmp_path)[0] == "CLAIMED-1234"


def test_explicit_id_outranks_session_allocation(tmp_path):
    selected, _ = _run({"PALACE_TEST_SIMULATOR_ID": "EXPLICIT-9999",
                        "HARNESS_SESSION_SIM_UDID": "CLAIMED-1234"}, tmp_path=tmp_path)
    assert selected == "EXPLICIT-9999"


def test_picks_the_reference_device_over_the_first_listed(tmp_path):
    selected, stderr = _run({}, tmp_path=tmp_path)
    assert selected == "BBBB-1111", "must pick iPhone 16 Pro on iOS 18.5, the reference device"
    assert stderr == ""


def test_without_the_reference_runtime_uses_the_same_device_on_the_newest_runtime(tmp_path):
    listing = _listing({"iOS 26.1": [("iPhone 12", "AAAA-0000"), ("iPhone 16 Pro", "CCCC-2222")],
                        "iOS 26.0": [("iPhone 16 Pro", "EEEE-4444")]})
    selected, stderr = _run({}, listing=listing, tmp_path=tmp_path)
    assert selected == "CCCC-2222"
    assert "-downloadPlatform iOS -buildVersion 18.5" in stderr
    assert "not on the reference setup" in stderr


def test_no_iphone_at_all_selects_nothing_rather_than_erroring(tmp_path):
    selected, _ = _run({}, listing=_listing({"iOS 26.1": [("iPad Air", "FFFF-5555")]}), tmp_path=tmp_path)
    assert selected == ""

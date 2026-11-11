"""scripts/reference_toolchain.py, scripts/reference-toolchain.ini, and their wiring.

A test result is only comparable across runs when the Xcode build and the
simulator are the same. These tests pin three things:

  * `select-sim` picks the profile's device on the profile's runtime by exact
    name, never the first simulator listed, and fails with an install hint
    when it is missing (a fallback is allowed only when asked for).
  * `report --strict` fails a job whose Xcode build, SDK, runtime, device,
    arch or configuration differs from the profile.
  * Every setup-xcode step names the exact version of the profile for its
    runner, no lane picks a simulator with `head -1`, and the CI lanes and the
    local runners call the selector.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "reference_toolchain.py"
_CONFIG = _REPO / "scripts" / "reference-toolchain.ini"
_WORKFLOWS = _REPO / ".github" / "workflows"

sys.path.insert(0, str(_REPO / "scripts"))
import reference_toolchain as rt  # noqa: E402

_R185 = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
_R186 = "com.apple.CoreSimulator.SimRuntime.iOS-18-6"
_R262 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
_REF_UDID = "4A57FB15-6E7C-49CC-BE93-450B18BD286E"


def _dev(name: str, udid: str, state: str = "Shutdown", available: bool = True) -> dict:
    return {"name": name, "udid": udid, "state": state, "isAvailable": available}


def _rt(name: str, ident: str, version: str) -> dict:
    return {"name": name, "identifier": ident, "version": version, "isAvailable": True}


# The macos-15 image as simctl lists it: the first iPhone listed is an
# iPhone 16 on iOS 18.5, which is what `head -1` used to pick, and iPhone 16 Pro
# exists on three runtimes.
_MACOS15 = {
    "runtimes": [_rt("iOS 18.5", _R185, "18.5"), _rt("iOS 18.6", _R186, "18.6"),
                 _rt("iOS 26.2", _R262, "26.2")],
    "devices": {
        _R185: [_dev("iPhone 16", "341D689A-78F6-4171-9723-8609B5394AD8"),
                _dev("iPhone 16 Pro (a11y)", "00000000-0000-0000-0000-000000000001"),
                _dev("iPhone 16 Pro", "11111111-0000-0000-0000-000000000000", available=False),
                _dev("iPhone 16 Pro", _REF_UDID)],
        _R186: [_dev("iPhone 16 Pro", "22222222-0000-0000-0000-000000000000")],
        _R262: [_dev("iPhone 16 Pro", "33333333-0000-0000-0000-000000000000"),
                _dev("iPhone 17 Pro", "44444444-0000-0000-0000-000000000000")],
    },
}


def _run(*args: str, tmp_path: Path, simctl: dict | None = None, env: dict | None = None):
    argv = [sys.executable, str(_SCRIPT), *args]
    if simctl is not None:
        p = tmp_path / "simctl.json"
        p.write_text(json.dumps(simctl))
        argv += ["--simctl-json", str(p)]
    return subprocess.run(argv, capture_output=True, text=True, env=env)


# --- the committed profiles -------------------------------------------------

def test_profiles_pin_exact_builds_not_major_versions():
    profiles = rt.load_profiles(_CONFIG)
    # One profile: the test lanes and the release builds share it (PP-5523).
    assert set(profiles) == {"reference"}
    for name, p in profiles.items():
        assert re.fullmatch(r"\d+\.\d+(\.\d+)?", p["xcode_version"]), name
        assert re.fullmatch(r"\d+[A-Z]\d+[a-z]?", p["xcode_build"]), name
        assert p["sdk"].startswith("iphonesimulator"), name
        assert p["runtime"].startswith("iOS "), name


def test_get_prints_a_profile_value(tmp_path):
    out = _run("get", "reference", "device", tmp_path=tmp_path)
    assert out.returncode == 0
    assert out.stdout.strip() == rt.load_profile("reference")["device"]


def test_unknown_profile_exits_2(tmp_path):
    out = _run("get", "nightly", "device", tmp_path=tmp_path)
    assert out.returncode == 2
    assert "no profile [nightly]" in out.stderr


def test_profile_missing_a_key_is_rejected(tmp_path):
    cfg = tmp_path / "t.ini"
    cfg.write_text("[reference]\nxcode_version = 26.3\n")
    with pytest.raises(rt.ConfigError, match="lacks"):
        rt.load_profile("reference", cfg)


# --- select-sim ---------------------------------------------------------------

def _profile_ini(tmp_path: Path, runtime="iOS 18.5", device="iPhone 16 Pro") -> Path:
    cfg = tmp_path / "t.ini"
    cfg.write_text(
        "[reference]\nrunner_image = macos-15-arm64\nxcode_version = 26.3\n"
        "xcode_build = 17C529\nsdk = iphonesimulator26.2\n"
        f"runtime = {runtime}\ndevice = {device}\narch = arm64\nconfiguration = Debug\n")
    return cfg


def test_select_sim_picks_named_device_on_named_runtime(tmp_path):
    cfg = _profile_ini(tmp_path)
    out = _run("--config", str(cfg), "select-sim", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == 0, out.stderr
    # Not the first iPhone listed, not the a11y-named copy, not the unavailable
    # one, and not iPhone 16 Pro on 18.6 or 26.2.
    assert out.stdout.split() == [_REF_UDID]


def test_select_sim_prefers_a_booted_device(tmp_path):
    simctl = json.loads(json.dumps(_MACOS15))
    simctl["devices"][_R185].append(_dev("iPhone 16 Pro", "FFFFFFFF-0000-0000-0000-000000000000", state="Booted"))
    cfg = _profile_ini(tmp_path)
    out = _run("--config", str(cfg), "select-sim", "--all", tmp_path=tmp_path, simctl=simctl)
    assert out.stdout.split() == ["FFFFFFFF-0000-0000-0000-000000000000", _REF_UDID]


def test_select_sim_missing_runtime_fails_with_install_hint(tmp_path):
    cfg = _profile_ini(tmp_path, runtime="iOS 18.4")
    out = _run("--config", str(cfg), "select-sim", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == rt.EXIT_NOT_FOUND
    assert out.stdout == ""
    assert "iPhone 16 Pro on iOS 18.4, is not installed" in out.stderr
    assert "-downloadPlatform iOS -buildVersion 18.4" in out.stderr


def test_select_sim_missing_device_names_the_create_command(tmp_path):
    cfg = _profile_ini(tmp_path, device="iPhone 16 Pro Max")
    out = _run("--config", str(cfg), "select-sim", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == rt.EXIT_NOT_FOUND
    assert ('simctl create "iPhone 16 Pro Max" '
            f"com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max {_R185}") in out.stderr


def test_fallback_uses_same_device_on_newest_runtime_and_warns(tmp_path):
    cfg = _profile_ini(tmp_path, runtime="iOS 18.4")
    out = _run("--config", str(cfg), "select-sim", "--allow-fallback", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == 0
    assert out.stdout.split() == ["33333333-0000-0000-0000-000000000000"]
    assert "not on the reference setup" in out.stderr


def test_fallback_without_the_device_takes_an_iphone_on_newest_runtime(tmp_path):
    cfg = _profile_ini(tmp_path, device="iPhone 99")
    out = _run("--config", str(cfg), "select-sim", "--allow-fallback", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == 0
    # iPhone 16 Pro sorts before iPhone 17 Pro on iOS 26.2.
    assert out.stdout.split() == ["33333333-0000-0000-0000-000000000000"]


def test_all_with_fallback_lists_reference_devices_then_every_other_iphone(tmp_path):
    # verify-pr drops devices another checkout holds; with every reference
    # device held it must still have one left.
    cfg = _profile_ini(tmp_path)
    out = _run("--config", str(cfg), "select-sim", "--all", "--allow-fallback", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.returncode == 0
    assert out.stdout.split() == [
        _REF_UDID,                                   # iPhone 16 Pro, iOS 18.5
        "33333333-0000-0000-0000-000000000000",      # iPhone 16 Pro, iOS 26.2
        "22222222-0000-0000-0000-000000000000",      # iPhone 16 Pro, iOS 18.6
        "44444444-0000-0000-0000-000000000000",      # iPhone 17 Pro, iOS 26.2
        "341D689A-78F6-4171-9723-8609B5394AD8",      # iPhone 16, iOS 18.5
        "00000000-0000-0000-0000-000000000001",      # iPhone 16 Pro (a11y), iOS 18.5
    ]
    assert out.stderr == ""


def test_all_without_fallback_lists_only_reference_devices(tmp_path):
    cfg = _profile_ini(tmp_path)
    out = _run("--config", str(cfg), "select-sim", "--all", tmp_path=tmp_path, simctl=_MACOS15)
    assert out.stdout.split() == [_REF_UDID]


def test_a_unix_host_without_simctl_reads_as_not_installed(tmp_path):
    cfg = _profile_ini(tmp_path)
    out = subprocess.run([sys.executable, str(_SCRIPT), "--config", str(cfg), "select-sim"],
                         capture_output=True, text=True, env={"PATH": str(tmp_path)})
    assert out.returncode == rt.EXIT_NOT_FOUND
    assert "is not installed" in out.stderr


def test_fallback_with_no_iphone_still_fails(tmp_path):
    cfg = _profile_ini(tmp_path)
    simctl = {"runtimes": [_rt("iOS 26.2", _R262, "26.2")], "devices": {_R262: [_dev("iPad Air", "AAAA")]}}
    out = _run("--config", str(cfg), "select-sim", "--allow-fallback", tmp_path=tmp_path, simctl=simctl)
    assert out.returncode == rt.EXIT_NOT_FOUND
    assert out.stdout == ""


# --- report -------------------------------------------------------------------

def _report(tmp_path, *extra, xcode="Xcode 26.3\nBuild version 17C529\n", sdk="26.2",
            udid=_REF_UDID, env=None):
    cfg = _profile_ini(tmp_path)
    vt = tmp_path / "xcode-version.txt"
    vt.write_text(xcode)
    return _run("--config", str(cfg), "report", "--udid", udid, "--xcode-version-text", str(vt),
                "--sdk-version", sdk, "--arch", "arm64", "--configuration", "Debug", *extra,
                tmp_path=tmp_path, simctl=_MACOS15, env=env)


def test_report_strict_passes_and_records_every_field(tmp_path):
    env = {"PATH": "/usr/bin:/bin", "ImageOS": "macos26", "ImageVersion": "20261103.629"}
    out = _report(tmp_path, "--strict", env=env)
    assert out.returncode == 0, out.stdout
    line = next(l for l in out.stdout.splitlines() if l.startswith("TOOLCHAIN "))
    assert line == ("TOOLCHAIN xcode_version=26.3 xcode_build=17C529 sdk=iphonesimulator26.2 "
                    "runtime=iOS_18.5 device=iPhone_16_Pro arch=arm64 configuration=Debug "
                    "image=macos26_20261103.629")


def test_report_off_ci_names_the_image_local(tmp_path):
    out = _report(tmp_path, env={"PATH": "/usr/bin:/bin"})
    assert "image=local" in out.stdout


def test_a_different_runner_image_alone_does_not_fail_strict(tmp_path):
    # The image is recorded, not compared: an image update with the same
    # Xcode and simulator is not a toolchain change.
    env = {"PATH": "/usr/bin:/bin", "ImageOS": "macos26", "ImageVersion": "20991231.1"}
    assert _report(tmp_path, "--strict", env=env).returncode == 0


@pytest.mark.parametrize("kwargs,field", [
    ({"xcode": "Xcode 26.3\nBuild version 17C530\n"}, "xcode_build"),
    ({"sdk": "26.5"}, "sdk"),
    ({"udid": "22222222-0000-0000-0000-000000000000"}, "runtime"),
    ({"udid": "44444444-0000-0000-0000-000000000000"}, "device"),
    ({"udid": "NOT-A-UDID"}, "device"),
])
def test_report_strict_fails_on_each_difference(tmp_path, kwargs, field):
    out = _report(tmp_path, "--strict", **kwargs)
    assert out.returncode == 1
    assert f"::error title=Toolchain differs from the reference profile::{field} is" in out.stdout


def test_report_without_strict_marks_a_local_xcode_27_run_off_reference_and_passes(tmp_path):
    # A workstation with only Xcode 27.2 and the iOS 26.2 SDK must still run
    # verify-pr; the record says how it differs from the reference.
    out = _report(tmp_path, xcode="Xcode 27.2\nBuild version 27B52\n", sdk="27.2",
                  udid="44444444-0000-0000-0000-000000000000")
    assert out.returncode == 0
    for field, seen, want in (("xcode_build", "27B52", "17C529"), ("sdk", "iphonesimulator27.2", "iphonesimulator26.2"),
                              ("device", "iPhone 17 Pro", "iPhone 16 Pro")):
        assert f"::warning title=Toolchain differs from the reference profile::{field} is {seen}, " \
               f"the profile names {want}" in out.stdout
    assert "::error" not in out.stdout
    assert "off-reference run" in out.stderr


def test_report_appends_to_the_step_summary(tmp_path):
    summary = tmp_path / "summary.md"
    env = {"PATH": "/usr/bin:/bin", "GITHUB_STEP_SUMMARY": str(summary)}
    out = _report(tmp_path, "--strict", env=env)
    assert out.returncode == 0
    text = summary.read_text()
    assert "| xcode_build | 17C529 | 17C529 |" in text
    assert "| runtime | iOS 18.5 | iOS 18.5 |" in text


# --- wiring -------------------------------------------------------------------

# Which profile each macOS runner label runs. A lane that changes runner must
# change profile with it.
_PROFILE_FOR_RUNNER = {"macos-26": "reference"}


def _setup_xcode_steps():
    for wf in sorted(_WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(wf.read_text())
        for job_name, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).startswith("maxim-lobanov/setup-xcode"):
                    yield (wf.name, job_name, job.get("runs-on"),
                           str((step.get("with") or {}).get("xcode-version")))


def test_there_are_setup_xcode_steps_to_check():
    assert len(list(_setup_xcode_steps())) >= 10


@pytest.mark.parametrize("wf,job,runner,version", list(_setup_xcode_steps()), ids=str)
def test_setup_xcode_names_the_profile_version_for_its_runner(wf, job, runner, version):
    assert runner in _PROFILE_FOR_RUNNER, f"{wf}:{job} runs on {runner}, which has no profile"
    want = rt.load_profile(_PROFILE_FOR_RUNNER[runner])["xcode_version"]
    # Shards reuse the build job's recorded version, so they cannot drift from it.
    allowed = {want, "${{ needs.build.outputs.xcode }}",
               f"${{{{ needs.build.outputs.xcode || '{want}' }}}}"}
    assert version in allowed, f"{wf}:{job} asks setup-xcode for {version!r}; the profile names {want}"


_SELECTION_FILES = sorted(_WORKFLOWS.glob("*.yml")) + sorted((_REPO / "scripts").glob("ci-*.sh")) + [
    _REPO / "scripts" / "verify-pr.sh", _REPO / "scripts" / "xcode-test-optimized.sh"]
_FIRST_AVAILABLE = re.compile(r"(simctl list devices|-showdestinations)[^\n]*\|\s*head -(n\s*)?1\b")


def _logical_lines(text: str) -> str:
    return re.sub(r"\\\n\s*", " ", text)


@pytest.mark.parametrize("path", _SELECTION_FILES, ids=lambda p: p.name)
def test_no_simulator_is_picked_by_first_availability(path):
    hits = _FIRST_AVAILABLE.findall(_logical_lines(path.read_text()))
    assert not hits, f"{path.name} picks a simulator with head -1 over the device list"


def test_first_availability_pattern_matches_the_old_selection():
    old = ('SIMULATOR_ID=$(xcrun simctl list devices available | grep "iPhone" \\\n'
           "    | grep -oE '[0-9A-F-]{36}' | head -1)\n")
    assert _FIRST_AVAILABLE.search(_logical_lines(old))


# Workflows call the script by path; the shell scripts through a variable that
# must point at it.
_CALL = r'(?:reference_toolchain\.py|"\$(?:TOOLCHAIN_HELPER|HERE/reference_toolchain\.py)")"?'
_SELECT = _CALL + r" select-sim --profile {p}\b"
_REPORT = _CALL + r" report --profile {p}\b[^\n]*"
_WIRING = {
    ".github/workflows/unit-testing.yml": ("reference", True),
    ".github/workflows/ui-journeys.yml": ("reference", True),
    ".github/workflows/audiobook-toolkit-tests.yml": ("reference", True),
    ".github/workflows/tsan.yml": ("reference", True),
    "scripts/ci-run-test-shard.sh": ("reference", True),
    "scripts/verify-pr.sh": ("reference", False),
    "scripts/xcode-test-optimized.sh": ("reference", False),
    "scripts/ci-parity-local.sh": ("reference", False),
}


@pytest.mark.parametrize("rel", sorted(_WIRING))
def test_lane_selects_and_records_its_profile(rel):
    profile, strict = _WIRING[rel]
    text = _logical_lines((_REPO / rel).read_text())
    if "TOOLCHAIN_HELPER" in text:
        assert re.search(r'TOOLCHAIN_HELPER=[^\n]*/reference_toolchain\.py"', text), rel
    assert re.search(_SELECT.format(p=profile), text), f"{rel} does not select the {profile} simulator"
    if rel == "scripts/ci-parity-local.sh":
        return  # its test phase runs xcode-test-optimized.sh, which records the toolchain
    report = re.search(_REPORT.format(p=profile), text)
    assert report, f"{rel} does not record its toolchain"
    if strict:
        assert "--strict" in report.group(0), f"{rel} records its toolchain without failing on a difference"


def test_unit_test_on_leg_selects_its_own_reference_simulator():
    text = _logical_lines((_WORKFLOWS / "unit-testing.yml").read_text())
    assert len(re.findall(_SELECT.format(p="reference"), text)) >= 2


def test_a_profile_only_change_runs_the_unit_tests():
    # The shard simulator comes from the profile, so editing it alone changes
    # what the unit-test lane runs on.
    import importlib.util
    spec = importlib.util.spec_from_file_location("relevance", _REPO / "scripts" / "ci-unit-test-relevance.py")
    relevance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relevance)
    run, _ = relevance.classify(["scripts/reference-toolchain.ini"], relevance.relevant_scripts(_REPO))
    assert run is True


# --- check-available ----------------------------------------------------------

_MACOS26 = {
    "runtimes": [_rt("iOS 26.2", _R262, "26.2"),
                 _rt("iOS 26.5", "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
    "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
        _dev("iPhone 17 Pro", "55555555-0000-0000-0000-000000000000")]},
}


def _available(tmp_path, *, build="17F113", sdk="26.5", simctl=_MACOS26, xcode="26.6", install=True):
    cfg = tmp_path / "t.ini"
    cfg.write_text("[reference]\nrunner_image = macos-26-arm64\nxcode_version = 26.6\n"
                   "xcode_build = 17F113\nsdk = iphonesimulator26.5\nruntime = iOS 26.5\n"
                   "device = iPhone 17 Pro\narch = arm64\nconfiguration = Debug\n")
    apps = tmp_path / "Applications"
    if install:
        contents = apps / f"Xcode_{xcode}.app" / "Contents"
        contents.mkdir(parents=True)
        import plistlib
        (contents / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": build}))
    else:
        apps.mkdir()
    return _run("--config", str(cfg), "check-available", "--applications", str(apps),
                "--sdk-version", sdk, tmp_path=tmp_path, simctl=simctl)


def test_check_available_passes_when_everything_is_present(tmp_path):
    out = _available(tmp_path)
    assert out.returncode == 0, out.stdout
    assert "all present" in out.stdout
    assert "::error" not in out.stdout


def test_check_available_names_a_missing_xcode(tmp_path):
    out = _available(tmp_path, xcode="26.7")
    assert out.returncode == 1
    assert "::error title=Reference toolchain missing from the runner image::Xcode 26.6 is not installed" in out.stdout


def test_check_available_names_a_different_xcode_build(tmp_path):
    out = _available(tmp_path, build="17F200")
    assert out.returncode == 1
    assert "Xcode_26.6.app is build 17F200, the profile names 17F113." in out.stdout


def test_check_available_names_a_missing_sdk(tmp_path):
    out = _available(tmp_path, sdk="26.4")
    assert out.returncode == 1
    assert "provides iphonesimulator26.4, the profile names iphonesimulator26.5." in out.stdout


def test_check_available_names_a_missing_runtime(tmp_path):
    simctl = {"runtimes": [_rt("iOS 26.2", _R262, "26.2")], "devices": {}}
    out = _available(tmp_path, simctl=simctl)
    assert out.returncode == 1
    assert "Simulator runtime iOS 26.5 is not installed; installed: iOS 26.2." in out.stdout


def test_check_available_names_a_missing_device(tmp_path):
    simctl = json.loads(json.dumps(_MACOS26))
    simctl["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-5"] = [_dev("iPhone Air", "6666")]
    out = _available(tmp_path, simctl=simctl)
    assert out.returncode == 1
    assert "No available iPhone 17 Pro simulator on iOS 26.5." in out.stdout


def test_check_available_reports_every_missing_item_not_just_the_first(tmp_path):
    simctl = {"runtimes": [], "devices": {}}
    out = _available(tmp_path, build="17F200", sdk="26.4", simctl=simctl)
    assert out.stdout.count("::error") == 3


_AVAILABILITY = _WORKFLOWS / "toolchain-availability.yml"


def test_availability_workflow_runs_weekly_and_on_demand_on_the_profile_runner():
    doc = yaml.safe_load(_AVAILABILITY.read_text())
    triggers = doc.get("on") or doc.get(True)  # PyYAML reads a bare `on:` key as True
    assert "workflow_dispatch" in triggers
    assert [s["cron"] for s in triggers["schedule"]], "no weekly schedule"
    jobs = list(doc["jobs"].values())
    assert len(jobs) == 1
    job = jobs[0]
    profile = rt.load_profile("reference")
    assert profile["runner_image"].startswith(job["runs-on"] + "-")
    runs = " ".join(str(s.get("run", "")) for s in job["steps"])
    assert "reference_toolchain.py check-available --profile reference" in runs
    # It checks the image as shipped; selecting an Xcode first would hide a missing one.
    assert not any(str(s.get("uses", "")).startswith("maxim-lobanov/setup-xcode") for s in job["steps"])

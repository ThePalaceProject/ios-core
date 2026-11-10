#!/usr/bin/env python3
"""Read the reference toolchain, pick its simulator, and record what a job used.

The profiles live in scripts/reference-toolchain.ini. Update procedure:
docs/Testing/reference-toolchain.md.

  get <profile> <key>
      Print one value from a profile.
  select-sim --profile P [--all] [--allow-fallback] [--simctl-json FILE]
      Print the UDID of an available simulator with the profile's device name
      on the profile's runtime. Exit 3, naming what is missing and how to
      install it, when there is none. With --allow-fallback (local runs only)
      a missing reference device falls back to the same device on the newest
      installed runtime, then to any iPhone on it, with a warning that the run
      is not on the reference setup.
  report --profile P --udid U [--configuration C] [--strict]
      Print the Xcode build, SDK, runtime, device, arch and configuration the
      job uses, compared with the profile, and append them to
      $GITHUB_STEP_SUMMARY when set. --strict exits 1 on any difference.
      The --simctl-json, --xcode-version-text, --sdk-version and --arch flags
      replace the live readings (used by the tests). The runner image
      ($ImageOS $ImageVersion on GitHub Actions) is printed, not compared.
  check-available --profile P [--applications DIR]
      Check that this host provides the profile's Xcode build, SDK, runtime
      and device, without selecting that Xcode first. Exit 1, naming each
      missing item, when it does not. The weekly toolchain-availability
      workflow runs it on the profile's runner image.

prior-art-checked: the simulator lock helper filters by lock only, and the
local runners' old selection matched a device name on any runtime; neither
reads a pinned runtime or records the Xcode build. (Script names are left out
of this text on purpose: ci-unit-test-relevance.py follows them.)
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import platform
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# REFERENCE_TOOLCHAIN_CONFIG lets a test of a calling script supply profiles
# that match its stubbed tools.
DEFAULT_CONFIG = Path(os.environ.get("REFERENCE_TOOLCHAIN_CONFIG")
                      or Path(__file__).resolve().parent / "reference-toolchain.ini")
KEYS = ("runner_image", "xcode_version", "xcode_build", "sdk", "runtime",
        "device", "arch", "configuration")
REPORTED = ("xcode_version", "xcode_build", "sdk", "runtime", "device", "arch", "configuration")
EXIT_NOT_FOUND = 3


class ConfigError(Exception):
    pass


def load_profiles(path: Path = DEFAULT_CONFIG) -> dict[str, dict[str, str]]:
    parser = configparser.ConfigParser(interpolation=None)
    if not parser.read(path):
        raise ConfigError(f"cannot read {path}")
    profiles = {}
    for name in parser.sections():
        values = dict(parser[name])
        missing = [k for k in KEYS if not values.get(k)]
        if missing:
            raise ConfigError(f"profile [{name}] in {path} lacks {', '.join(missing)}")
        profiles[name] = values
    return profiles


def load_profile(name: str, path: Path = DEFAULT_CONFIG) -> dict[str, str]:
    profiles = load_profiles(path)
    if name not in profiles:
        raise ConfigError(f"no profile [{name}] in {path}; have {', '.join(sorted(profiles))}")
    return profiles[name]


def read_simctl(path: str | None, developer_dir: str | None = None) -> dict:
    if path:
        return json.loads(Path(path).read_text())
    env = {**os.environ, "DEVELOPER_DIR": developer_dir} if developer_dir else None
    # No simctl (a Linux host, a broken Xcode) reads as an empty listing, which
    # the callers report as "not installed".
    try:
        out = subprocess.run(["xcrun", "simctl", "list", "-j"],
                             capture_output=True, text=True, check=True, env=env).stdout
        return json.loads(out)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return {"runtimes": [], "devices": {}}


def _runtimes(simctl: dict) -> list[dict]:
    return [r for r in simctl.get("runtimes", [])
            if r.get("isAvailable", True) and r.get("name", "").startswith("iOS ")]


def _version_key(runtime: dict) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", runtime.get("version", "")))


def _devices_on(simctl: dict, runtime: dict) -> list[dict]:
    return [d for d in simctl.get("devices", {}).get(runtime["identifier"], [])
            if d.get("isAvailable", True)]


def _ordered(devices: list[dict]) -> list[str]:
    # Booted first, then by UDID, so repeated calls on one host agree.
    return [d["udid"] for d in sorted(devices, key=lambda d: (d.get("state") != "Booted", d["udid"]))]


def select_devices(simctl: dict, runtime_name: str, device_name: str) -> list[str]:
    """UDIDs of available `device_name` simulators on `runtime_name`, exact names only."""
    for runtime in _runtimes(simctl):
        if runtime["name"] == runtime_name:
            return _ordered([d for d in _devices_on(simctl, runtime) if d["name"] == device_name])
    return []


def fallback_devices(simctl: dict, device_name: str) -> list[tuple[str, str]]:
    """Every available iPhone as (udid, "name on runtime"), best first: the
    profile's device on the newest runtime that has it, then the other iPhones,
    newest runtime first and by name. A caller that filters out held devices
    still has the rest to choose from."""
    runtimes = sorted(_runtimes(simctl), key=_version_key, reverse=True)
    same, other = [], []
    for runtime in runtimes:
        devs = _devices_on(simctl, runtime)
        for udid in _ordered([d for d in devs if d["name"] == device_name]):
            same.append((udid, f"{device_name} on {runtime['name']}"))
        phones = sorted((d for d in devs if d["name"].startswith("iPhone") and d["name"] != device_name),
                        key=lambda d: (d["name"], d.get("state") != "Booted", d["udid"]))
        other.extend((d["udid"], f"{d['name']} on {runtime['name']}") for d in phones)
    return same + other


def missing_message(simctl: dict, profile: dict[str, str]) -> str:
    runtime, device = profile["runtime"], profile["device"]
    installed = _runtimes(simctl)
    names = [r["name"] for r in installed]
    lines = [f"The reference simulator, {device} on {runtime}, is not installed."]
    if runtime in names:
        ident = next(r["identifier"] for r in installed if r["name"] == runtime)
        type_id = "com.apple.CoreSimulator.SimDeviceType." + re.sub(r"[^A-Za-z0-9]+", "-", device).strip("-")
        lines.append("  The runtime is installed; create the device with:")
        lines.append(f"    xcrun simctl create \"{device}\" {type_id} {ident}")
    else:
        version = runtime.split(" ", 1)[-1]
        lines.append(f"  Installed iOS runtimes: {', '.join(names) or 'none'}.")
        lines.append(f"  Install the runtime with: xcodebuild -downloadPlatform iOS -buildVersion {version}")
    lines.append("  The reference setup is defined in scripts/reference-toolchain.ini.")
    return "\n".join(lines)


def describe_device(simctl: dict, udid: str) -> tuple[str, str] | None:
    names = {r["identifier"]: r["name"] for r in simctl.get("runtimes", [])}
    for ident, devices in simctl.get("devices", {}).items():
        for d in devices:
            if d.get("udid") == udid:
                return names.get(ident, ident), d.get("name", "")
    return None


def parse_xcode_version(text: str) -> tuple[str, str]:
    version = re.search(r"^Xcode\s+(\S+)", text, re.M)
    build = re.search(r"^Build version\s+(\S+)", text, re.M)
    return (version.group(1) if version else "unknown", build.group(1) if build else "unknown")


def _live(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""


def observe(args: argparse.Namespace, profile: dict[str, str]) -> dict[str, str]:
    if args.xcode_version_text is not None:
        version_text = Path(args.xcode_version_text).read_text()
    else:
        version_text = _live(["xcodebuild", "-version"])
    xcode_version, xcode_build = parse_xcode_version(version_text)
    sdk_version = args.sdk_version
    if sdk_version is None:
        sdk_version = _live(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip()
    described = describe_device(read_simctl(args.simctl_json), args.udid)
    runtime, device = described if described else ("not found", "not found")
    return {
        "xcode_version": xcode_version,
        "xcode_build": xcode_build,
        "sdk": f"iphonesimulator{sdk_version}" if sdk_version else "unknown",
        "runtime": runtime,
        "device": device,
        "arch": args.arch or platform.machine(),
        "configuration": args.configuration or profile["configuration"],
    }


def runner_image() -> str:
    """The GitHub Actions image name and version, or "local" off CI."""
    parts = [os.environ.get("ImageOS", ""), os.environ.get("ImageVersion", "")]
    return " ".join(p for p in parts if p) or "local"


def cmd_report(args: argparse.Namespace) -> int:
    profile = load_profile(args.profile, Path(args.config))
    seen = observe(args, profile)
    diffs = [k for k in REPORTED if seen[k] != profile[k]]
    image = runner_image()
    print(f"Toolchain for this job (profile '{args.profile}' in scripts/reference-toolchain.ini):")
    for k in REPORTED:
        mark = "ok" if k not in diffs else f"DIFFERS, expected {profile[k]}"
        print(f"  {k:<14} {seen[k]:<24} {mark}")
    print(f"  {'simulator':<14} {args.udid}")
    print(f"  {'image':<14} {image}")
    print("TOOLCHAIN " + " ".join(f"{k}={seen[k].replace(' ', '_')}" for k in REPORTED)
          + f" image={image.replace(' ', '_')}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(f"### Toolchain (profile `{args.profile}`)\n\n"
                     "| Item | Used | Expected |\n|---|---|---|\n")
            for k in REPORTED:
                fh.write(f"| {k} | {seen[k]} | {profile[k]} |\n")
            fh.write(f"| image | {image} | {profile['runner_image']} |\n\n")
    level = "error" if args.strict else "warning"
    for k in diffs:
        print(f"::{level} title=Toolchain differs from the {args.profile} profile::"
              f"{k} is {seen[k]}, the profile names {profile[k]}")
    if diffs and not args.strict:
        print(f"note: off-reference run. The installed toolchain is not the {args.profile} "
              "setup, so results may differ from CI.", file=sys.stderr)
    return 1 if diffs and args.strict else 0


def check_available(profile: dict[str, str], applications: Path, simctl: dict,
                    sdk_version: str | None) -> list[str]:
    """What the host lacks of the profile, one message per missing item."""
    app = applications / f"Xcode_{profile['xcode_version']}.app"
    plist = app / "Contents" / "version.plist"
    if not plist.is_file():
        return [f"Xcode {profile['xcode_version']} is not installed ({app} is missing)."]
    problems = []
    build = plistlib.loads(plist.read_bytes()).get("ProductBuildVersion", "unknown")
    if build != profile["xcode_build"]:
        problems.append(f"{app.name} is build {build}, the profile names {profile['xcode_build']}.")
    if sdk_version is None:
        sdk_version = _live(["env", f"DEVELOPER_DIR={app}/Contents/Developer",
                             "xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip()
    sdk = f"iphonesimulator{sdk_version}" if sdk_version else "no simulator SDK"
    if sdk != profile["sdk"]:
        problems.append(f"{app.name} provides {sdk}, the profile names {profile['sdk']}.")
    names = [r["name"] for r in _runtimes(simctl)]
    if profile["runtime"] not in names:
        problems.append(f"Simulator runtime {profile['runtime']} is not installed; "
                        f"installed: {', '.join(names) or 'none'}.")
    elif not select_devices(simctl, profile["runtime"], profile["device"]):
        problems.append(f"No available {profile['device']} simulator on {profile['runtime']}.")
    return problems


def cmd_check_available(args: argparse.Namespace) -> int:
    profile = load_profile(args.profile, Path(args.config))
    app = Path(args.applications) / f"Xcode_{profile['xcode_version']}.app"
    simctl = read_simctl(args.simctl_json, developer_dir=str(app / "Contents" / "Developer"))
    problems = check_available(profile, Path(args.applications), simctl, args.sdk_version)
    print(f"Profile '{args.profile}' on image {runner_image()} (profile names {profile['runner_image']}):")
    for p in problems:
        print(f"::error title=Reference toolchain missing from the runner image::{p}")
    if problems:
        print("Update scripts/reference-toolchain.ini; see docs/Testing/reference-toolchain.md.")
        return 1
    print(f"  Xcode {profile['xcode_version']} ({profile['xcode_build']}), {profile['sdk']}, "
          f"{profile['device']} on {profile['runtime']}: all present.")
    return 0


def cmd_select_sim(args: argparse.Namespace) -> int:
    profile = load_profile(args.profile, Path(args.config))
    simctl = read_simctl(args.simctl_json)
    udids = select_devices(simctl, profile["runtime"], profile["device"])
    if not udids:
        print(missing_message(simctl, profile), file=sys.stderr)
        if not args.allow_fallback:
            return EXIT_NOT_FOUND
    if args.allow_fallback:
        fallback = [c for c in fallback_devices(simctl, profile["device"]) if c[0] not in udids]
        if not udids:
            if not fallback:
                print("  No iPhone simulator is available at all.", file=sys.stderr)
                return EXIT_NOT_FOUND
            print(f"warning: using {fallback[0][1]} instead. This run is not on the reference setup.",
                  file=sys.stderr)
        # After the reference devices, so a caller that skips held devices
        # still finds one.
        udids = udids + [u for u, _ in fallback]
    print("\n".join(udids if args.all else udids[:1]))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("get")
    g.add_argument("profile")
    g.add_argument("key", choices=KEYS)

    s = sub.add_parser("select-sim")
    s.add_argument("--profile", default="reference")
    s.add_argument("--all", action="store_true")
    s.add_argument("--allow-fallback", action="store_true")
    s.add_argument("--simctl-json")

    r = sub.add_parser("report")
    r.add_argument("--profile", default="reference")
    r.add_argument("--udid", required=True)
    r.add_argument("--configuration")
    r.add_argument("--strict", action="store_true")
    r.add_argument("--simctl-json")
    r.add_argument("--xcode-version-text")
    r.add_argument("--sdk-version")
    r.add_argument("--arch")

    c = sub.add_parser("check-available")
    c.add_argument("--profile", default="reference")
    c.add_argument("--applications", default="/Applications")
    c.add_argument("--simctl-json")
    c.add_argument("--sdk-version")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "get":
            print(load_profile(args.profile, Path(args.config))[args.key])
            return 0
        if args.cmd == "select-sim":
            return cmd_select_sim(args)
        if args.cmd == "check-available":
            return cmd_check_available(args)
        return cmd_report(args)
    except ConfigError as exc:
        print(f"reference_toolchain: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

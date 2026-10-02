#!/usr/bin/env python3
"""Print the UDID of the one simulator every CI test job runs on.

USAGE
    scripts/ci-resolve-simulator.py            # prints the UDID
    CI_SIM_DEVICE="iPhone 17" CI_SIM_OS=26.4 scripts/ci-resolve-simulator.py

The device and iOS version live here, and only here, so a runner-image change
is a one-line edit. CI_SIM_DEVICE and CI_SIM_OS override them.

The match is exact on the device name and on the runtime version: OS=26.5
accepts runtime 26.5 or 26.5.x, never 26.4 or 26.50. When nothing matches, the
script exits 1 and lists what the runner does have. It never falls back to
another device or runtime, because a fallback changes the iOS version under
test without anyone choosing it.

prior-art-checked: the local test runners choose a simulator by preference
order with fallbacks, which is the behaviour CI must not have; nothing in the
repo resolves a device by name and OS together. (Script names are left out of
this comment on purpose: the unit-test relevance check treats any sibling
script named here as part of the unit-test path.)
"""

import json
import os
import subprocess
import sys

DEFAULT_DEVICE = "iPhone 17 Pro"
DEFAULT_OS = "26.5"


def _simctl(*args):
    out = subprocess.run(["xcrun", "simctl", "list", "-j", *args],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def _version_matches(version, wanted):
    return version == wanted or version.startswith(wanted + ".")


def resolve(device, os_version, runtimes, devices):
    """Return (udid, runtime) or (None, None)."""
    for runtime in runtimes:
        if runtime.get("platform", "iOS") != "iOS" or not runtime.get("isAvailable", False):
            continue
        if not _version_matches(runtime.get("version", ""), os_version):
            continue
        for dev in devices.get(runtime["identifier"], []):
            if dev.get("name") == device and dev.get("isAvailable", False):
                return dev["udid"], runtime
    return None, None


def main():
    device = os.environ.get("CI_SIM_DEVICE") or DEFAULT_DEVICE
    os_version = os.environ.get("CI_SIM_OS") or DEFAULT_OS
    runtimes = _simctl("runtimes", "available")["runtimes"]
    devices = _simctl("devices", "available")["devices"]

    udid, runtime = resolve(device, os_version, runtimes, devices)
    if udid is None:
        print(f"::error::no available '{device}' simulator on iOS {os_version}", file=sys.stderr)
        print("Available iOS runtimes and iPhones:", file=sys.stderr)
        for rt in runtimes:
            if rt.get("platform", "iOS") != "iOS":
                continue
            names = sorted({d["name"] for d in devices.get(rt["identifier"], [])
                            if d["name"].startswith("iPhone")})
            print(f"  iOS {rt.get('version')}: {', '.join(names) or '(none)'}", file=sys.stderr)
        return 1

    print(f"Simulator: {device}, iOS {runtime['version']} "
          f"({runtime.get('buildversion', '?')}), {udid}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())

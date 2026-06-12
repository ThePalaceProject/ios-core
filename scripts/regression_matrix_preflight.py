#!/usr/bin/env python3
"""regression_matrix_preflight.py — gate the regression device/OS matrix.

For each matrix cell, check that its required simulator runtime + device type
(or, for the Mac-native cell, the host architecture) is present on THIS machine.
A cell whose requirement is missing is reported `skip` with a reason — it never
fails the campaign (skip-with-warning per the BUILD-PLAN). Cells that are ready
get a concrete, resolved `xcodebuild` destination string the campaign driver and
per-cell harnesses consume verbatim.

Matrix cells (REGRESSION-BUILD-PLAN.md §host-constraint resolutions):
  C-iphone-26    iPhone 16 Pro / newest iOS 26.x sim        baseline parity
  C-ipad-26      iPad / newest iPadOS 26.x sim              iPad layout parity
  C-ios18        iPhone 16 Pro / iOS 18.0 (floor)           back-compat (iOS-16
                                                            unavailable on Xcode 26
                                                            → 18.0 substitute)
  C-ipad-on-mac  Designed-for-iPad build, Mac-native        device-divergence
                 (isiOSAppOnMac==true), Apple-Silicon host  crashes (WS-4 Adobe)
  C-carplay      headless XCTest cell (no interactive sim   CarPlay regression
                 drive — see CARPLAY-FEASIBILITY verdict)   (template/scene logic)

Usage:
  scripts/regression_matrix_preflight.py                 # table, all cells
  scripts/regression_matrix_preflight.py --json          # machine-readable JSON
  scripts/regression_matrix_preflight.py --cell C-ios18  # one cell
  scripts/regression_matrix_preflight.py --out <file>    # write JSON to file
  scripts/regression_matrix_preflight.py --ready-only    # exit 1 if ANY cell skipped

Exit code:
  0  — preflight ran; every requested cell is either ready or skip-with-warning
  1  — --ready-only was set AND at least one cell is skipped
  2  — config error (simctl unavailable / unparseable)
"""
from __future__ import annotations

import argparse
import json
import platform
import re
import subprocess
import sys
from typing import Optional

# --- Cell contract -----------------------------------------------------------
# kind:
#   "sim"            — a booted simulator of (device_type, runtime). Gated on both.
#   "mac-native"     — the Designed-for-iPad binary run natively on the Mac host
#                      (isiOSAppOnMac==true). Gated on Apple-Silicon arch.
#   "headless-xctest"— a test bundle exercising headless logic (CarPlay). Gated on
#                      the base iPhone sim runtime only (the bundle runs there).
#
# runtime_pref: how to resolve the concrete runtime from what's installed.
#   ("major", N)   — newest installed iOS N.x  (e.g. newest 26.x)
#   ("exact", "X.Y") with floor fallback to the lowest installed same-major.
CELLS = [
    {
        "cell": "C-iphone-26",
        "kind": "sim",
        "device_type": "iPhone 16 Pro",
        "runtime_pref": ("major", 26),
        "signal": "baseline parity (today's coverage)",
    },
    {
        "cell": "C-ipad-26",
        "kind": "sim",
        # any iPad device type; resolved to the first installed match below.
        "device_type": "iPad",
        "runtime_pref": ("major", 26),
        "signal": "iPad layout parity (X1)",
    },
    {
        "cell": "C-ios18",
        "kind": "sim",
        "device_type": "iPhone 16 Pro",
        # iOS-16 is unavailable on Xcode 26; 18.0 is the back-compat floor.
        "runtime_pref": ("exact", "18.0"),
        "signal": "back-compat / deprecated-API divergence (iOS-16 floor substitute)",
    },
    {
        "cell": "C-ipad-on-mac",
        "kind": "mac-native",
        "device_type": None,
        "runtime_pref": None,
        "signal": "device-divergence crashes (Adobe recursive_mutex-at-exit, WS-4)",
    },
    {
        "cell": "C-carplay",
        "kind": "headless-xctest",
        # CarPlay headless bundle runs on the baseline iPhone sim.
        "device_type": "iPhone 16 Pro",
        "runtime_pref": ("major", 26),
        "signal": "CarPlay template/scene regression (headless — see verdict)",
    },
]


def _simctl_json(*args: str) -> dict:
    out = subprocess.run(
        ["xcrun", "simctl", "list", "-j", *args],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def load_environment() -> dict:
    """Snapshot installed runtimes + device types once."""
    try:
        runtimes_raw = _simctl_json("runtimes")["runtimes"]
        devicetypes_raw = _simctl_json("devicetypes")["devicetypes"]
    except (subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not query simctl: {exc}", file=sys.stderr)
        sys.exit(2)

    runtimes = []
    for rt in runtimes_raw:
        # Only usable iOS runtimes.
        if rt.get("platform") != "iOS" and "iOS" not in rt.get("name", ""):
            continue
        if not rt.get("isAvailable", rt.get("availability", "") == "(available)"):
            continue
        ver = rt.get("version", "")
        m = re.match(r"(\d+)\.(\d+)", ver)
        if not m:
            continue
        runtimes.append({
            "name": rt.get("name", ""),
            "version": ver,
            "major": int(m.group(1)),
            "minor": int(m.group(2)),
            "identifier": rt.get("identifier", ""),
        })

    devicetypes = [
        {"name": dt.get("name", ""), "identifier": dt.get("identifier", "")}
        for dt in devicetypes_raw
    ]
    return {"runtimes": runtimes, "devicetypes": devicetypes}


def resolve_runtime(pref, runtimes) -> Optional[dict]:
    """Resolve a runtime_pref against installed runtimes; None if unsatisfiable."""
    if pref is None:
        return None
    kind, val = pref
    if kind == "major":
        candidates = [r for r in runtimes if r["major"] == val]
        # newest minor wins
        return max(candidates, key=lambda r: r["minor"], default=None)
    if kind == "exact":
        major = int(val.split(".")[0])
        exact = [r for r in runtimes if r["version"] == val]
        if exact:
            return exact[0]
        # floor fallback: lowest installed runtime of the same major
        same_major = [r for r in runtimes if r["major"] == major]
        return min(same_major, key=lambda r: r["minor"], default=None)
    return None


def resolve_device_type(name, devicetypes) -> Optional[dict]:
    """Exact-name match, else first device type whose name starts with `name`."""
    if name is None:
        return None
    exact = [d for d in devicetypes if d["name"] == name]
    if exact:
        return exact[0]
    prefix = [d for d in devicetypes if d["name"].startswith(name)]
    return prefix[0] if prefix else None


def destination_for(cell_kind, device_type, runtime) -> Optional[str]:
    """xcodebuild -destination string for a ready cell."""
    if cell_kind == "mac-native":
        # Designed-for-iPad app run natively on Apple Silicon.
        return "platform=macOS,variant=Designed for iPad"
    if cell_kind in ("sim", "headless-xctest") and device_type and runtime:
        return (
            f"platform=iOS Simulator,name={device_type['name']},"
            f"OS={runtime['version']}"
        )
    return None


def evaluate_cell(cfg, env) -> dict:
    cell = cfg["cell"]
    kind = cfg["kind"]
    result = {
        "cell": cell,
        "kind": kind,
        "signal": cfg["signal"],
        "status": "ready",
        "reason": "",
        "device_type": None,
        "runtime": None,
        "destination": None,
    }

    if kind == "mac-native":
        is_apple_silicon = platform.machine() == "arm64"
        if not is_apple_silicon:
            result["status"] = "skip"
            result["reason"] = (
                f"host arch is {platform.machine()}, not arm64 — Designed-for-iPad "
                "native run requires an Apple-Silicon Mac"
            )
            return result
        result["reason"] = (
            "Apple-Silicon host; runs Designed-for-iPad binary natively "
            "(isiOSAppOnMac==true) + crash-log harvest at exit"
        )
        result["destination"] = destination_for(kind, None, None)
        return result

    # sim / headless-xctest cells: need a device type + runtime
    rt = resolve_runtime(cfg["runtime_pref"], env["runtimes"])
    dt = resolve_device_type(cfg["device_type"], env["devicetypes"])

    if rt is None:
        result["status"] = "skip"
        pref = cfg["runtime_pref"]
        want = f"{pref[1]}.x" if pref[0] == "major" else pref[1]
        result["reason"] = f"no installed iOS {want} runtime"
        return result
    if dt is None:
        result["status"] = "skip"
        result["reason"] = f"no installed '{cfg['device_type']}' device type"
        return result

    result["device_type"] = dt["name"]
    result["runtime"] = rt["version"]
    result["destination"] = destination_for(kind, dt, rt)

    # Floor-substitution note for the iOS-18 cell.
    if cfg["runtime_pref"][0] == "exact" and rt["version"] != cfg["runtime_pref"][1]:
        result["reason"] = (
            f"requested iOS {cfg['runtime_pref'][1]} absent; using floor "
            f"iOS {rt['version']}"
        )
    elif kind == "headless-xctest":
        result["reason"] = (
            "headless XCTest cell — CarPlay logic exercised via test bundle, "
            "no interactive CarPlay-display drive (per feasibility verdict)"
        )
    else:
        result["reason"] = "runtime + device type present"
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Regression device/OS matrix preflight")
    ap.add_argument("--json", action="store_true", help="emit JSON to stdout")
    ap.add_argument("--cell", help="preflight a single cell by name")
    ap.add_argument("--out", help="write JSON report to this file")
    ap.add_argument("--ready-only", action="store_true",
                    help="exit 1 if any requested cell is skipped")
    args = ap.parse_args()

    env = load_environment()

    cells = CELLS
    if args.cell:
        cells = [c for c in CELLS if c["cell"] == args.cell]
        if not cells:
            print(f"ERROR: unknown cell '{args.cell}'. Known: "
                  f"{', '.join(c['cell'] for c in CELLS)}", file=sys.stderr)
            return 2

    results = [evaluate_cell(c, env) for c in cells]
    report = {
        "host": {
            "arch": platform.machine(),
            "model": platform.platform(),
        },
        "cells": results,
        "ready": [r["cell"] for r in results if r["status"] == "ready"],
        "skipped": [r["cell"] for r in results if r["status"] == "skip"],
    }

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=2)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("=== regression matrix preflight ===")
        print(f"host: {platform.machine()}\n")
        width = max(len(r["cell"]) for r in results)
        for r in results:
            badge = "READY" if r["status"] == "ready" else "SKIP "
            dest = r["destination"] or "—"
            print(f"  [{badge}] {r['cell']:<{width}}  {dest}")
            print(f"          {r['reason']}")
        print(f"\nready:   {', '.join(report['ready']) or '(none)'}")
        print(f"skipped: {', '.join(report['skipped']) or '(none)'}")

    if args.ready_only and report["skipped"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
test_regression_matrix_preflight.py — pytest harness for
scripts/regression_matrix_preflight.py.

The preflight gates each regression-matrix cell on installed runtimes / device
types / host arch. Its core contract (REGRESSION-BUILD-PLAN.md) is
**skip-with-warning, never fail** when a requirement is missing, plus an
iOS-18.0 *floor* substitution for the unavailable iOS-16 cell.

These tests drive `evaluate_cell` / `resolve_runtime` / `resolve_device_type`
against SYNTHETIC environments (no dependency on what's installed on the runner),
so they assert the gating logic deterministically in CI.
"""
from __future__ import annotations

import importlib.util
import platform
from pathlib import Path

import pytest

_SCRIPTS = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "regression_matrix_preflight", _SCRIPTS / "regression_matrix_preflight.py"
)
preflight = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preflight)


def _rt(version):
    major, minor = (int(x) for x in version.split("."))
    return {"name": f"iOS {version}", "version": version, "major": major,
            "minor": minor, "identifier": f"id{version.replace('.', '')}"}


def _dt(name):
    return {"name": name, "identifier": "dt-" + name.replace(" ", "-")}


IPHONE = _dt("iPhone 16 Pro")
IPAD = _dt("iPad Pro 11-inch (M4)")


def _cell(name):
    return next(c for c in preflight.CELLS if c["cell"] == name)


# --- runtime resolution ------------------------------------------------------

def test_major_pref_picks_newest_minor():
    rts = [_rt("26.0"), _rt("26.2"), _rt("26.1")]
    got = preflight.resolve_runtime(("major", 26), rts)
    assert got["version"] == "26.2"


def test_exact_pref_prefers_exact_match():
    rts = [_rt("18.0"), _rt("18.2")]
    got = preflight.resolve_runtime(("exact", "18.0"), rts)
    assert got["version"] == "18.0"


def test_exact_pref_floor_fallback_to_lowest_same_major():
    # 18.0 absent → floor to the LOWEST installed 18.x (18.2 here, the only one).
    rts = [_rt("18.2"), _rt("18.4"), _rt("26.2")]
    got = preflight.resolve_runtime(("exact", "18.0"), rts)
    assert got["version"] == "18.2"


def test_runtime_pref_unsatisfiable_returns_none():
    rts = [_rt("26.2")]
    assert preflight.resolve_runtime(("exact", "18.0"), rts) is None
    assert preflight.resolve_runtime(("major", 18), rts) is None


# --- device-type resolution --------------------------------------------------

def test_device_type_exact_then_prefix():
    dts = [IPHONE, IPAD]
    assert preflight.resolve_device_type("iPhone 16 Pro", dts)["name"] == "iPhone 16 Pro"
    # "iPad" is a prefix match against the installed iPad Pro
    assert preflight.resolve_device_type("iPad", dts)["name"].startswith("iPad")
    assert preflight.resolve_device_type("Apple Watch", dts) is None


# --- cell evaluation: ready ---------------------------------------------------

def test_iphone26_ready_with_destination():
    env = {"runtimes": [_rt("26.2")], "devicetypes": [IPHONE]}
    r = preflight.evaluate_cell(_cell("C-iphone-26"), env)
    assert r["status"] == "ready"
    assert r["runtime"] == "26.2"
    assert r["destination"] == "platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2"


def test_ios18_floor_substitution_is_ready_with_note():
    # 18.0 absent, 18.2 present → ready on the floor, with a substitution reason.
    env = {"runtimes": [_rt("18.2"), _rt("26.2")], "devicetypes": [IPHONE]}
    r = preflight.evaluate_cell(_cell("C-ios18"), env)
    assert r["status"] == "ready"
    assert r["runtime"] == "18.2"
    assert "floor" in r["reason"]


def test_carplay_is_headless_with_destination():
    env = {"runtimes": [_rt("26.2")], "devicetypes": [IPHONE]}
    r = preflight.evaluate_cell(_cell("C-carplay"), env)
    assert r["status"] == "ready"
    assert r["kind"] == "headless-xctest"
    assert "headless" in r["reason"].lower()


# --- cell evaluation: skip-with-warning (the contract) -----------------------

def test_ios18_skips_when_no_18x_runtime():
    env = {"runtimes": [_rt("26.2")], "devicetypes": [IPHONE]}
    r = preflight.evaluate_cell(_cell("C-ios18"), env)
    assert r["status"] == "skip"
    assert "18.0" in r["reason"]
    assert r["destination"] is None


def test_ipad_skips_when_no_ipad_device_type():
    env = {"runtimes": [_rt("26.2")], "devicetypes": [IPHONE]}
    r = preflight.evaluate_cell(_cell("C-ipad-26"), env)
    assert r["status"] == "skip"
    assert "iPad" in r["reason"]


def test_mac_native_skips_on_non_apple_silicon(monkeypatch):
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    env = {"runtimes": [_rt("26.2")], "devicetypes": [IPHONE, IPAD]}
    r = preflight.evaluate_cell(_cell("C-ipad-on-mac"), env)
    assert r["status"] == "skip"
    assert "arm64" in r["reason"]


def test_mac_native_ready_on_apple_silicon(monkeypatch):
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    env = {"runtimes": [], "devicetypes": []}  # mac-native needs neither
    r = preflight.evaluate_cell(_cell("C-ipad-on-mac"), env)
    assert r["status"] == "ready"
    assert r["destination"] == "platform=macOS,variant=Designed for iPad"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))

"""palace_mutate simulator resolution.

The bug this pins: `SIM_ID` was a hardcoded UDID present on exactly one
machine. An unresolvable `-destination id=...` makes xcodebuild exit having
run no tests, which palace_mutate scores as every mutant ERRORED — a result
that looks like a mutation measurement and is really a missing simulator.
Measured 2026-09-16 on release/3.3.0, where the same constant in verify-pr.sh
reported "Build did not complete" and reddened four legs against an innocent
diff.

Resolution must therefore VALIDATE the wanted UDID against devices that exist,
and must fail loudly (exit 2) rather than hand back something unusable.
"""
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import palace_mutate as pm  # noqa: E402


# A realistic `xcrun simctl list devices available` excerpt.
AVAILABLE = """== Devices ==
-- iOS 18.0 --
    iPhone 12 (31CF5C43-DD55-4889-B3B2-9A6810B4E98F) (Shutdown)
-- iOS 26.1 --
    iPhone 17 Pro Max (B7EEED61-B0B2-45B7-A2E7-6F8DF12FEEA1) (Booted)
    iPad Air 11-inch (M3) (50DF78E7-1544-4886-A3AF-65B4E6C0FE3F) (Shutdown)
"""

DEAD_UDID = "DF4A2A27-9888-429D-A749-2E157A049A37"
LIVE_UDID = "B7EEED61-B0B2-45B7-A2E7-6F8DF12FEEA1"


def test_wantedUDIDPresent_isHonored():
    assert pm.resolve_sim_id(LIVE_UDID, AVAILABLE) == LIVE_UDID


def test_wantedUDIDAbsent_fallsBackToAnAvailableIPhone():
    """THE regression: a stale UDID must not be handed back verbatim."""
    assert pm.resolve_sim_id(DEAD_UDID, AVAILABLE) == LIVE_UDID


def test_noDeviceListing_resolvesToNothing():
    """No `xcrun` (or no Xcode) must yield None, not the unvalidated want."""
    assert pm.resolve_sim_id(DEAD_UDID, "") is None


def test_onlyUnmatchedHardware_resolvesToNothing():
    """An iPhone 12-only host has no destination CLAUDE.md's matrix accepts."""
    listing = "-- iOS 18.0 --\n    iPhone 12 (31CF5C43-DD55-4889-B3B2-9A6810B4E98F) (Shutdown)\n"
    assert pm.resolve_sim_id(None, listing) is None


def test_iPadsAreNotSelected():
    listing = "    iPad Air 11-inch (M3) (50DF78E7-1544-4886-A3AF-65B4E6C0FE3F) (Shutdown)\n"
    assert pm.resolve_sim_id(None, listing) is None


def test_requireSimID_whenNothingResolves_exitsTwoAndSaysNothingWasMeasured(monkeypatch, capsys):
    """A missing simulator must NOT read as a mutation score."""
    monkeypatch.setattr(pm, "_RESOLVED_SIM_ID", None)
    monkeypatch.setattr(pm, "simctl_available_devices", lambda: "")
    monkeypatch.delenv("HARNESS_SESSION_SIM_UDID", raising=False)
    with pytest.raises(SystemExit) as exc:
        pm.require_sim_id()
    assert exc.value.code == 2
    err = capsys.readouterr().err
    assert "NOTHING WAS MEASURED" in err
    assert "not 'mutants survived'" in err.replace("NOT", "not")


def test_requireSimID_resolves_andMemoizes(monkeypatch):
    monkeypatch.setattr(pm, "_RESOLVED_SIM_ID", None)
    calls = []

    def listing():
        calls.append(1)
        return AVAILABLE

    monkeypatch.setattr(pm, "simctl_available_devices", listing)
    monkeypatch.setenv("HARNESS_SESSION_SIM_UDID", LIVE_UDID)
    assert pm.require_sim_id() == LIVE_UDID
    assert pm.require_sim_id() == LIVE_UDID
    assert len(calls) == 1, "resolution must be memoized, not re-shelled per mutant"


def test_simctlAvailableDevices_whenXcrunMissing_returnsEmptyNotRaise(monkeypatch):
    def boom(*a, **k):
        raise FileNotFoundError("xcrun")

    monkeypatch.setattr(subprocess, "run", boom)
    assert pm.simctl_available_devices() == ""


def test_moduleImportsWithoutShellingOut(monkeypatch):
    """scripts/tests/ runs on ubuntu in CI: import must not need `xcrun`."""
    def boom(*a, **k):
        raise AssertionError("resolution must be lazy, not at import time")

    monkeypatch.setattr(subprocess, "run", boom)
    import importlib
    importlib.reload(pm)

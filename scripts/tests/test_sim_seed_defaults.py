#!/usr/bin/env python3
"""Pytest for scripts/lib/sim-seed-defaults.sh and its wiring.

The defect: `xcrun simctl spawn <udid> defaults write <bundle-id> …` writes the
simulator HOST domain, not the app's sandboxed container, so `@AppStorage` never
observes it. The command succeeds, the caller prints "✓ seeded", and the belief
is false. Measured live on the rc330 sim: the host domain reports the key "does
not exist" while the app's container plist has it — two different stores.

The fix is a read-back, and a read-back is only worth anything if it can FAIL.
So the tests below drive the failure directions as hard as the success one.

The shell behaviour tests need PlistBuddy + plutil and therefore macOS; they
skip on the Linux tooling runner. The WIRING tests do not — they read the
scripts as text and run everywhere, which matters because the wiring is what
rots.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "lib" / "sim-seed-defaults.sh"
BUILD_SIM = REPO / "scripts" / "build-sim-for-simdrive.sh"

macos_only = pytest.mark.skipif(
    sys.platform != "darwin"
    or not Path("/usr/libexec/PlistBuddy").exists()
    or shutil.which("plutil") is None,
    reason="needs macOS PlistBuddy + plutil (the tools the simulator flow uses)")


def _sh(script: str) -> subprocess.CompletedProcess:
    """Run a snippet with the library sourced."""
    body = f'set -u\n. "{LIB}"\n{script}\n'
    return subprocess.run(["bash", "-c", body], capture_output=True, text=True,
                          timeout=60)


@pytest.fixture
def plist(tmp_path: Path) -> Path:
    """A path shaped like the real container preferences path."""
    return tmp_path / "Library" / "Preferences" / "org.thepalaceproject.palace.plist"


# --- behaviour --------------------------------------------------------------

@macos_only
def test_seed_writes_and_reads_back_true(plist):
    rc = _sh(f'seed_app_default_bool "{plist}" showDeveloperSettings true')
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert plist.is_file(), "the container plist was not created"
    out = subprocess.run(["plutil", "-extract", "showDeveloperSettings", "raw",
                          "-o", "-", str(plist)], capture_output=True, text=True)
    assert out.stdout.strip() == "true"


@macos_only
def test_seed_creates_the_preferences_directory(plist):
    assert not plist.parent.exists()
    assert _sh(f'seed_app_default_bool "{plist}" k true').returncode == 0
    assert plist.parent.is_dir()


@macos_only
def test_seed_overwrites_an_existing_value(plist):
    _sh(f'seed_app_default_bool "{plist}" k false')
    assert _sh(f'seed_app_default_bool "{plist}" k true').returncode == 0
    assert _sh(f'[ "$(read_app_default_bool "{plist}" k)" = true ]').returncode == 0


@macos_only
def test_seed_fails_when_the_write_cannot_land(plist):
    """The whole point. An unwritable target must FAIL, not announce success."""
    rc = _sh('seed_app_default_bool "/dev/null/nope/x.plist" k true')
    assert rc.returncode != 0
    assert "read-back FAILED" in rc.stderr or "cannot create" in rc.stderr


@macos_only
def test_seed_reports_what_it_wanted_and_what_it_found(plist):
    rc = _sh('seed_app_default_bool "/dev/null/nope/x.plist" k true')
    assert rc.returncode != 0
    assert "cannot create" in rc.stderr or (
        "wanted:" in rc.stderr and "got:" in rc.stderr)


@macos_only
def test_read_back_of_an_absent_key_is_non_zero(plist):
    _sh(f'seed_app_default_bool "{plist}" present true')
    rc = _sh(f'read_app_default_bool "{plist}" absent')
    assert rc.returncode != 0
    assert rc.stdout.strip() == ""


@macos_only
def test_read_back_of_a_missing_file_is_non_zero(tmp_path):
    rc = _sh(f'read_app_default_bool "{tmp_path}/nope.plist" k')
    assert rc.returncode != 0


@macos_only
def test_non_boolean_value_is_a_usage_error(plist):
    rc = _sh(f'seed_app_default_bool "{plist}" k banana')
    assert rc.returncode == 2
    assert "must be a bool" in rc.stderr


@macos_only
def test_verify_distinguishes_seeded_from_unseeded(plist):
    _sh(f'seed_app_default_bool "{plist}" k true')
    assert _sh(f'verify_app_default_bool "{plist}" k true').returncode == 0
    assert _sh(f'verify_app_default_bool "{plist}" k false').returncode != 0
    assert _sh(f'verify_app_default_bool "{plist}" missing true').returncode != 0


@macos_only
def test_read_back_survives_a_binary_plist(plist):
    """Real container plists are binary. A reader that only handles XML would
    pass in a fixture and fail on a device."""
    _sh(f'seed_app_default_bool "{plist}" k true')
    subprocess.run(["plutil", "-convert", "binary1", str(plist)], check=True)
    assert _sh(f'verify_app_default_bool "{plist}" k true').returncode == 0


@macos_only
def test_the_reader_is_not_the_writer(plist):
    """Independence check, stated as behaviour: a file PlistBuddy cannot parse
    must not read back as success."""
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_text("this is not a plist\n")
    rc = _sh(f'read_app_default_bool "{plist}" k')
    assert rc.returncode != 0


# --- defect reintroduction --------------------------------------------------

@macos_only
def test_removing_the_read_back_makes_the_failure_silent(tmp_path):
    """Prove the guard bites by deleting it.

    A copy of the library with the read-back replaced by an unconditional
    success is the pre-fix behaviour: it reports success for a write that could
    not possibly have landed. If this test ever passes with the REAL library,
    the read-back is decorative.
    """
    neutered = tmp_path / "neutered.sh"
    text = LIB.read_text(encoding="utf-8")
    marker = '  got="$(read_app_default_bool "$plist" "$key" || true)"'
    assert marker in text, "the read-back this test removes has moved"
    head, _, tail = text.partition(marker)
    tail_after_fn = tail[tail.index("\n# verify_app_default_bool"):]
    neutered.write_text(head + '  echo "  ✓ seeded"\n  return 0\n}\n'
                        + tail_after_fn, encoding="utf-8")

    # A target whose parent dir is fine (so the mkdir guard passes) but which
    # cannot hold a plist, because it is itself a directory. The write silently
    # does nothing; only the read-back can tell.
    target = tmp_path / "Library" / "Preferences" / "org.example.plist"
    target.mkdir(parents=True)

    def run(lib: Path):
        return subprocess.run(
            ["bash", "-c", f'set -u\n. "{lib}"\n'
                           f'seed_app_default_bool "{target}" k true'],
            capture_output=True, text=True, timeout=60)

    assert run(neutered).returncode == 0, \
        "the neutered library should announce success — fixture is wrong"
    assert run(LIB).returncode != 0, \
        "the REAL library also announced success: the read-back does not bite"


# --- wiring (runs everywhere) ----------------------------------------------

def test_build_sim_sources_the_library():
    """RED if the seeding is inlined or the source line is dropped."""
    text = BUILD_SIM.read_text(encoding="utf-8")
    assert "lib/sim-seed-defaults.sh" in text
    assert "seed_app_default_bool" in text


def test_build_sim_no_longer_writes_the_host_domain():
    """The exact command that produced the false checkmark must not come back."""
    text = BUILD_SIM.read_text(encoding="utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue            # the comment explaining the defect is fine
        assert not ("simctl spawn" in stripped and "defaults write" in stripped), \
            f"host-domain default write is back: {stripped}"


def test_build_sim_terminates_the_app_before_seeding():
    """cfprefsd in a running app flushes its cache over the file we write."""
    text = BUILD_SIM.read_text(encoding="utf-8")
    seed = text.index("seed_app_default_bool")
    before = text[:seed]
    assert "simctl terminate" in before, \
        "the app must be terminated before its container plist is written"


def test_build_sim_fails_closed_when_the_seed_does_not_land():
    """A failed seed must die, not warn — and must name a diagnosis."""
    text = BUILD_SIM.read_text(encoding="utf-8")
    idx = text.index("if seed_app_default_bool")
    block = text[idx:idx + 900]
    assert "else" in block and "die " in block, \
        "the seed failure path does not exit non-zero"
    assert "plutil -p" in block, "the failure must name a diagnosis command"


def test_build_sim_does_not_claim_a_seed_it_did_not_make():
    """With no install there is no container, so the summary must say so."""
    text = BUILD_SIM.read_text(encoding="utf-8")
    assert "DEV_MENU_LINE" in text
    assert "not seeded (no install)" in text


def test_scripts_pass_bash_syntax_check():
    for path in (LIB, BUILD_SIM):
        rc = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
        assert rc.returncode == 0, f"{path}: {rc.stderr}"


@pytest.mark.skipif(sys.platform != "darwin" or shutil.which("xcrun") is None,
                    reason="needs xcrun")
def test_container_path_shape_is_what_the_app_reads():
    """The path this library builds is <data-container>/Library/Preferences/<bid>.plist.

    Pinned as a string contract rather than against a live simulator, so the
    test does not depend on (or disturb) whatever sim is currently allocated.
    """
    text = LIB.read_text(encoding="utf-8")
    assert "get_app_container" in text
    assert "/Library/Preferences/%s.plist" in text

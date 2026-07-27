"""
test_check_bookregistry_package_purity.py — pytest for the DORMANT
`PalaceBookRegistry` package-purity gate (scripts/check-bookregistry-package-purity.sh).

Asserts the full gate-rule contract required by CLAUDE.md rule #4 even though
the gate's real target package (Wave 2b) does not exist yet:

  (a) package dir absent  -> NO-OP, exit 0 (today's actual repo state — the
      gate must not block anything before the package is extracted),
  (b) package dir present + a forbidden reference -> FAIL, exit 1,
  (c) package dir present + clean -> PASS, exit 0.

Each case points the script at a throwaway scan root via
BOOKREGISTRY_SCAN_ROOT so it never touches the real repo tree.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-bookregistry-package-purity.sh"


def _run(scan_root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(_SCRIPT)],
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "BOOKREGISTRY_SCAN_ROOT": str(scan_root),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_missing_package_dir_is_a_noop(tmp_path):
    """Today's actual repo state: the package hasn't been extracted yet. The
    gate MUST NOT block — it should no-op cleanly with exit 0."""
    missing_root = tmp_path / "Palace" / "Packages" / "PalaceBookRegistry" / "Sources"
    result = _run(missing_root)
    assert result.returncode == 0, (
        f"expected no-op exit 0 for a nonexistent package dir, got "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "NO-OP" in result.stdout


def test_forbidden_reference_is_flagged(tmp_path):
    """Once the package exists, a reference back into the app-target coupling
    surface (AppContainer here) MUST fail the gate."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "BookRegistryStore.swift").write_text(
        "import Foundation\n"
        "struct BookRegistryStore {\n"
        "    let container = AppContainer.production()\n"
        "}\n"
    )
    result = _run(root)
    assert result.returncode == 1, (
        f"expected exit 1 for a forbidden reference, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "AppContainer" in result.stdout


def test_each_forbidden_symbol_is_flagged(tmp_path):
    """Every symbol in the forbidden list fires independently."""
    forbidden_symbols = [
        "AccountsManager",
        "TPPUserAccount",
        "AppContainer",
        "MyBooksDownloadCenter",
        "LCPAudiobooks",
        "NotificationService",
    ]
    for symbol in forbidden_symbols:
        root = tmp_path / symbol / "Sources"
        root.mkdir(parents=True)
        (root / "Thing.swift").write_text(f"let x = {symbol}.thing\n")
        result = _run(root)
        assert result.returncode == 1, (
            f"{symbol}: expected exit 1, got {result.returncode}\n"
            f"stdout: {result.stdout!r}"
        )
        assert symbol in result.stdout


def test_clean_package_passes(tmp_path):
    """A package that only depends on its own inverted seam (e.g.
    AccountScopeProviding) — no forbidden app-target reference — MUST pass."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "BookRegistryStore.swift").write_text(
        "import Foundation\n"
        "protocol AccountScopeProviding {\n"
        "    var currentAccountID: String { get }\n"
        "}\n"
        "struct BookRegistryStore {\n"
        "    let scope: AccountScopeProviding\n"
        "}\n"
    )
    result = _run(root)
    assert result.returncode == 0, (
        f"expected exit 0 for a clean package, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "PASS" in result.stdout

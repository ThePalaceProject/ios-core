"""
test_check_palaceaccounts_package_purity.py — pytest for the DORMANT
`PalaceAccounts` package-purity gate (scripts/check-palaceaccounts-package-purity.sh).

Asserts the full gate-rule contract required by CLAUDE.md rule #4 even though
the gate's real target package (Wave 3a) does not exist yet:

  (a) package dir absent  -> NO-OP, exit 0 (today's actual repo state — the
      gate must not block anything before the package is extracted),
  (b) package dir present + a forbidden reference -> FAIL, exit 1,
  (c) package dir present + clean -> PASS, exit 0.

Each case points the script at a throwaway scan root via
PALACEACCOUNTS_SCAN_ROOT so it never touches the real repo tree.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-palaceaccounts-package-purity.sh"


def _run(scan_root: Path, path: str = "/usr/bin:/bin:/usr/sbin:/sbin") -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(_SCRIPT)],
        env={
            "PATH": path,
            "PALACEACCOUNTS_SCAN_ROOT": str(scan_root),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_missing_package_dir_is_a_noop(tmp_path):
    """Today's actual repo state: the package hasn't been extracted yet. The
    gate MUST NOT block — it should no-op cleanly with exit 0."""
    missing_root = tmp_path / "Palace" / "Packages" / "PalaceAccounts" / "Sources"
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
    (root / "AccountsStore.swift").write_text(
        "import Foundation\n"
        "struct AccountsStore {\n"
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
        "AppContainer",
        "MyBooksDownloadCenter",
        "ImageCache",
        "TPPBookCoverRegistry",
        "FirebaseManager",
    ]
    for symbol in forbidden_symbols:
        root = tmp_path / symbol / "Sources"
        root.mkdir(parents=True)
        if symbol == "ImageCache":
            (root / "Thing.swift").write_text("let x = ImageCache.shared.thing\n")
        else:
            (root / "Thing.swift").write_text(f"let x = {symbol}.thing\n")
        result = _run(root)
        assert result.returncode == 1, (
            f"{symbol}: expected exit 1, got {result.returncode}\n"
            f"stdout: {result.stdout!r}"
        )
        assert symbol in result.stdout


def test_clean_package_passes(tmp_path):
    """A package that only depends on its own inverted seam (e.g. a protocol)
    — no forbidden app-target reference — MUST pass."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "AccountsStore.swift").write_text(
        "import Foundation\n"
        "protocol AccountsCoverImageProviding {\n"
        "    func image(for accountID: String) -> Data?\n"
        "}\n"
        "struct AccountsStore {\n"
        "    let images: AccountsCoverImageProviding\n"
        "}\n"
    )
    result = _run(root)
    assert result.returncode == 0, (
        f"expected exit 0 for a clean package, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "PASS" in result.stdout


def test_forbidden_symbol_in_doc_comment_passes(tmp_path):
    """The extracted package's boundary docs legitimately NAME these types
    (e.g. "no `AppContainer` type crosses this boundary"). The invariant is
    about CODE coupling, not prose — a comment mention MUST NOT be flagged, or
    the gate would fail on its own documentation (the Wave 2b regression)."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "AccountsCoverImageProviding.swift").write_text(
        "import Foundation\n"
        "/// Value-only: no `AppContainer` or `MyBooksDownloadCenter` type ever\n"
        "/// crosses this boundary. The package holds no edge to `ImageCache.shared`,\n"
        "/// `TPPBookCoverRegistry`, or `FirebaseManager`.\n"
        "/* block comment naming FirebaseManager too */\n"
        "protocol AccountsCoverImageProviding {\n"
        "    func image(for accountID: String) -> Data?  // adapter reads AppContainer app-side\n"
        "}\n"
    )
    result = _run(root)
    assert result.returncode == 0, (
        f"expected exit 0 — forbidden names appear ONLY in comments, got "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "PASS" in result.stdout


def test_forbidden_symbol_in_string_literal_passes(tmp_path):
    """A forbidden name inside a string literal is not a code coupling edge."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "Log.swift").write_text(
        'let msg = "resolved via AppContainer.production() on the app side"\n'
        "let n = 1\n"
    )
    result = _run(root)
    assert result.returncode == 0, (
        f"expected exit 0 — forbidden name is in a string literal, got "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "PASS" in result.stdout


def test_python_crash_fails_closed(tmp_path):
    """If the embedded python3 scanner itself crashes (bad interpreter, syntax
    error, whatever), the gate must FAIL, not silently pass. Simulate a crash
    by shadowing `python3` on PATH with a stub that always exits non-zero,
    then assert the gate fails closed with a message that names the crash
    (not a false "PASS")."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "Clean.swift").write_text("import Foundation\nstruct Clean {}\n")

    fake_bin = tmp_path / "fakebin"
    fake_bin.mkdir()
    fake_python = fake_bin / "python3"
    fake_python.write_text(
        "#!/bin/sh\n"
        "echo 'boom: simulated interpreter crash' >&2\n"
        "exit 137\n"
    )
    fake_python.chmod(fake_python.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    result = _run(root, path=f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin")

    assert result.returncode != 0, (
        f"expected the gate to fail closed when python3 crashes, got exit "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "PASS" not in result.stdout, (
        "gate must never report PASS when the scanner itself crashed "
        f"(fail-open regression)\nstdout: {result.stdout!r}"
    )
    assert "crash" in result.stdout.lower() or "crash" in result.stderr.lower()


def test_forbidden_symbol_in_code_after_a_comment_line_is_flagged(tmp_path):
    """Comment-stripping must not mask a REAL code reference elsewhere in the
    file — a doc comment naming the type PLUS actual code usage still fails."""
    root = tmp_path / "Sources"
    root.mkdir(parents=True)
    (root / "Sync.swift").write_text(
        "/// This package must not touch AppContainer.\n"
        "import Foundation\n"
        "let leaked = AppContainer.production()\n"
    )
    result = _run(root)
    assert result.returncode == 1, (
        f"expected exit 1 — real code reference despite a comment, got "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "AppContainer" in result.stdout

#!/usr/bin/env python3
"""
test_check_raising_unarchiver.py — self-verify the RUA-1 detector
(scripts/check-raising-unarchiver.py).

The detector bans `NSKeyedUnarchiver.unarchiveObject(with:)`, which signals a
corrupt archive by RAISING an uncatchable ObjC exception. Measured by
bit-flipping each byte of a valid archive: 2 of 156 flips abort the process for
an archived String, 63 of 277 for an archived dictionary; the throwing
replacements abort on none.

Two live call sites motivated it: `TPPNetworkQueue` (offline-queue purge and
drain) and `TPPKeychainManager`, whose `validateKeychain()` runs from
`TPPAppDelegate.performBackgroundStartupTasks()` on EVERY launch — so one
corrupt keychain item was an unrecoverable launch crash loop.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-raising-unarchiver.py"


def _scan(root: Path) -> tuple[int, str]:
    p = subprocess.run([sys.executable, str(_SCRIPT), "--scan", str(root)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def _swift(root: Path, rel: str, body: str) -> Path:
    f = root / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(body)
    return f


# ───────────────────────────── it fires ─────────────────────────────────────

def test_firesOnTheRaisingCall(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           'let s = NSKeyedUnarchiver.unarchiveObject(with: data) as? String\n')
    rc, out = _scan(tmp_path)
    assert rc == 1
    assert "RUA-1" in out and "Palace/Thing.swift:1" in out


def test_firesOnTheWithFileVariant(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           'let s = NSKeyedUnarchiver.unarchiveObject(withFile: path)\n')
    rc, out = _scan(tmp_path)
    assert rc == 1
    assert "RUA-1" in out


def test_firesOnEachOccurrenceSeparately(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           'let a = NSKeyedUnarchiver.unarchiveObject(with: d1)\n'
           'let b = NSKeyedUnarchiver.unarchiveObject(with: d2)\n')
    rc, out = _scan(tmp_path)
    assert rc == 1
    assert "Thing.swift:1" in out and "Thing.swift:2" in out


# ───────────────────── it does NOT fire (the clean paths) ───────────────────

def test_approvedTypedFormPasses(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           'let s = try? NSKeyedUnarchiver.unarchivedObject(\n'
           '    ofClasses: [NSString.self], from: data) as? String\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_approvedTopLevelFormPasses(tmp_path):
    """The untyped escape valve — must not be mistaken for the banned call."""
    _swift(tmp_path, "Palace/Thing.swift",
           'let v = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_emptyTreePasses(tmp_path):
    """Clean-diff path: a detector that cannot pass is a detector nobody wires in."""
    (tmp_path / "Palace").mkdir()
    rc, out = _scan(tmp_path)
    assert rc == 0, out


# ─────────── the false positive that shipped in the first revision ──────────

def test_doesNotFireOnALineComment(tmp_path):
    """Naming the banned API in prose is how the ban is DOCUMENTED.

    The first revision of this detector fired on its own fix's explanatory
    comment — the known "detectors count comment mentions" failure, where a
    detector that flags its own documentation trains people to ignore it.
    """
    _swift(tmp_path, "Palace/Thing.swift",
           '// NSKeyedUnarchiver.unarchiveObject(with:) raises; do not use it.\n'
           'let s = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(d)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_doesNotFireOnATrailingComment(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           'let s = safeDecode(d)  // replaces NSKeyedUnarchiver.unarchiveObject(with:)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_doesNotFireInsideABlockComment(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           '/*\n'
           ' * Was: NSKeyedUnarchiver.unarchiveObject(with: data)\n'
           ' */\n'
           'let s = safeDecode(data)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_stillFiresOnCodeAfterAStringContainingSlashes(tmp_path):
    """A URL in a string must not be mistaken for a comment start."""
    _swift(tmp_path, "Palace/Thing.swift",
           'let u = "https://example.org"; '
           'let s = NSKeyedUnarchiver.unarchiveObject(with: data)\n')
    rc, out = _scan(tmp_path)
    assert rc == 1, out


# ───────────────────────── scope and escape hatch ──────────────────────────

def test_testCodeIsOutOfScope(tmp_path):
    """A test may legitimately construct the banned call to prove it aborts."""
    _swift(tmp_path, "PalaceTests/ThingTests.swift",
           'let s = NSKeyedUnarchiver.unarchiveObject(with: data)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_escapeHatchSuppresses(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift",
           '// no-raising-unarchiver: reading a format that predates secure coding\n'
           'let s = NSKeyedUnarchiver.unarchiveObject(with: data)\n')
    rc, out = _scan(tmp_path)
    assert rc == 0, out


def test_realTreeKeychainManagerIsClean():
    """The site this detector was written for stays fixed."""
    src = (_REPO_ROOT / "Palace" / "Keychain" / "TPPKeychainManager.swift")
    if not src.is_file():
        pytest.skip("TPPKeychainManager.swift not present")
    text = src.read_text()
    code_lines = [ln for ln in text.splitlines()
                  if not ln.strip().startswith(("//", "*", "/*"))]
    assert not any("unarchiveObject(with" in ln for ln in code_lines), \
        "TPPKeychainManager must not reintroduce the raising unarchiver"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))

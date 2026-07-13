"""
test_check_adjacency_staleness.py — pytest for the ADJ-STALE detector.

scripts/check-adjacency-staleness.py is warn-only: it ALWAYS exits 0.
Renames vs deletions are not mechanically distinguishable from a diff, so
a strict gate would false-positive on legitimate deletes. The observable
signal is therefore NOT the exit code but the presence of

    ADJ-STALE: <file>:<line>: comment references removed/renamed `<name>`

lines on stdout. Each test feeds a unified diff on stdin and points --root
at a temp tree so the codebase scan is fully controlled.

Coverage (both paths mandatory per CLAUDE.md gate rule #4):
  - REAL violation: a type is removed in the diff and a surviving file
    still references it in a comment  → ADJ-STALE emitted.
  - CLEAN removal: a type is removed in the diff and NO surviving comment
    references it                     → no ADJ-STALE (clean-pass wiring
    assertion — the one that catches "scan-only called with --diff" bugs).
  - Rename (removed AND re-added same name) is suppressed.
  - Empty candidate set (no removed decls) is a clean pass.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-adjacency-staleness.py"


def _run(diff_text: str, root: Path) -> subprocess.CompletedProcess:
    """Invoke the detector with `diff_text` on stdin and --root=<root>.

    Matches the real CLI: diff arrives via stdin (default), the codebase
    scan is confined to --root, and --quiet suppresses the summary so we
    assert on the ADJ-STALE findings alone.
    """
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--root", str(root), "--quiet"],
        input=diff_text,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _write_swift(root: Path, rel: str, body: str) -> None:
    dst = root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(body, encoding="utf-8")


# --- (a) REAL violation is caught -----------------------------------------

def test_removed_type_with_surviving_comment_ref_is_flagged(tmp_path):
    """A removed `class LegacyParser` while a surviving file's doc comment
    still says `LegacyParser` must emit an ADJ-STALE finding."""
    _write_swift(
        tmp_path,
        "Palace/Catalog/CatalogService.swift",
        "import Foundation\n"
        "/// Delegates parsing to LegacyParser for OPDS 1.x feeds.\n"
        "final class CatalogService {\n"
        "    func parse() {}\n"
        "}\n",
    )
    diff = (
        "diff --git a/Palace/Catalog/LegacyParser.swift b/Palace/Catalog/LegacyParser.swift\n"
        "--- a/Palace/Catalog/LegacyParser.swift\n"
        "+++ b/Palace/Catalog/LegacyParser.swift\n"
        "@@ -1,3 +0,0 @@\n"
        "-final class LegacyParser {\n"
        "-    func parse() {}\n"
        "-}\n"
    )
    result = _run(diff, tmp_path)
    assert result.returncode == 0, (
        f"detector is warn-only; expected exit 0, got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )
    assert "ADJ-STALE" in result.stdout, (
        f"expected an ADJ-STALE finding for the stale comment, "
        f"got stdout: {result.stdout!r}"
    )
    assert "LegacyParser" in result.stdout
    assert "CatalogService.swift" in result.stdout


# --- (b) CLEAN removal passes (the wiring-bug assertion) -------------------

def test_removed_type_with_no_surviving_ref_is_clean(tmp_path):
    """A removed `class LegacyParser` with NO surviving comment mentioning
    it is a legitimate delete — no ADJ-STALE should be emitted.

    This is the clean-pass assertion: if the detector were wired wrong
    (e.g. scanning added-line noise or ignoring --root), it would still
    surface a phantom finding here."""
    _write_swift(
        tmp_path,
        "Palace/Catalog/CatalogService.swift",
        "import Foundation\n"
        "/// Parses OPDS 2.0 feeds. No legacy dependency remains.\n"
        "final class CatalogService {\n"
        "    func parse() {}\n"
        "}\n",
    )
    diff = (
        "diff --git a/Palace/Catalog/LegacyParser.swift b/Palace/Catalog/LegacyParser.swift\n"
        "--- a/Palace/Catalog/LegacyParser.swift\n"
        "+++ b/Palace/Catalog/LegacyParser.swift\n"
        "@@ -1,3 +0,0 @@\n"
        "-final class LegacyParser {\n"
        "-    func parse() {}\n"
        "-}\n"
    )
    result = _run(diff, tmp_path)
    assert result.returncode == 0
    assert "ADJ-STALE" not in result.stdout, (
        f"clean removal should emit no findings, got: {result.stdout!r}"
    )


# --- Rename (removed AND re-added) is suppressed --------------------------

def test_rename_same_name_readded_is_suppressed(tmp_path):
    """If the removed name is also re-added in the diff, it is an edit, not
    a removal — even a comment ref must NOT be flagged (removed - added)."""
    _write_swift(
        tmp_path,
        "Palace/Catalog/Notes.swift",
        "// CatalogService owns the parse pipeline.\n"
        "struct Notes {}\n",
    )
    diff = (
        "diff --git a/Palace/Catalog/CatalogService.swift b/Palace/Catalog/CatalogService.swift\n"
        "--- a/Palace/Catalog/CatalogService.swift\n"
        "+++ b/Palace/Catalog/CatalogService.swift\n"
        "@@ -1,3 +1,3 @@\n"
        "-final class CatalogService {\n"
        "+public final class CatalogService {\n"
        "     func parse() {}\n"
        " }\n"
    )
    result = _run(diff, tmp_path)
    assert result.returncode == 0
    assert "ADJ-STALE" not in result.stdout, (
        f"re-added name is an edit, not a removal; got: {result.stdout!r}"
    )


# --- No removed declarations at all is a clean pass ----------------------

def test_diff_with_no_removed_decls_is_clean(tmp_path):
    """An add-only diff has no removal candidates — clean pass regardless
    of what comments exist in the tree."""
    _write_swift(
        tmp_path,
        "Palace/Catalog/CatalogService.swift",
        "// Mentions AnythingAtAll in a comment.\n"
        "final class CatalogService {}\n",
    )
    diff = (
        "diff --git a/Palace/Catalog/New.swift b/Palace/Catalog/New.swift\n"
        "--- a/dev/null\n"
        "+++ b/Palace/Catalog/New.swift\n"
        "@@ -0,0 +1,2 @@\n"
        "+final class New {}\n"
        "+// hello\n"
    )
    result = _run(diff, tmp_path)
    assert result.returncode == 0
    assert "ADJ-STALE" not in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))

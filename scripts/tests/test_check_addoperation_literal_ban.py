#!/usr/bin/env python3
"""
test_check_addoperation_literal_ban.py — self-verify the AOB-1 detector
(scripts/check-addoperation-literal-ban.py).

Runs the detector via `--scan` against the sibling per-shape Swift fixtures
and asserts the predicate fires on each of the four banned literal forms
(`.addOperation {`, `.addExecutionBlock {`, `BlockOperation {` /
`BlockOperation(block: {`, `.completionBlock = {`) while passing the
approved hoisted-`let`-binding form, the `// no-addoperation-literal-ban:`
escape hatch, and the out-of-scope `addOperations` (plural) API. Guards the
#1338 regression class (Xcode 26.2 ClangImporter @MainActor-poisoning of
NSOperation-family closure literals — see
Palace/Utilities/ImageCache/ImageCache.swift).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-addoperation-literal-ban.py"
_FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "addoperation_literal_ban"


def _run_scan(scan_root: Path) -> tuple[int, str, str]:
    """Invoke the detector in --scan mode; return (rc, stdout, stderr)."""
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--scan", str(scan_root), "--quiet"],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def _isolate(tmp_path: Path, fixture_name: str) -> Path:
    """Copy ONE fixture into a tmp Palace/ tree so --scan sees only it."""
    src = _FIXTURE_DIR / fixture_name
    assert src.is_file(), f"missing fixture: {src}"
    palace = tmp_path / "Palace"
    palace.mkdir()
    dst = palace / fixture_name
    dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
    return tmp_path


# --- Violation fixtures — each of the four banned literal forms ------------

def test_violation_addoperation_trailing_closure_is_flagged(tmp_path):
    """`.addOperation { ... }` — the canonical #1338 shape. MUST flag AOB-1."""
    root = _isolate(tmp_path, "violation_addoperation_trailing_closure.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "AOB-1" in out, f"expected AOB-1 finding. stdout={out!r}"
    assert "high" in out, f"expected high severity. stdout={out!r}"
    assert "violation_addoperation_trailing_closure.swift" in out


def test_violation_add_execution_block_is_flagged(tmp_path):
    """`.addExecutionBlock { ... }` — MUST flag AOB-1."""
    root = _isolate(tmp_path, "violation_add_execution_block.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "AOB-1" in out
    assert "violation_add_execution_block.swift" in out


def test_violation_block_operation_init_is_flagged(tmp_path):
    """`BlockOperation { ... }` (trailing-closure init) — MUST flag AOB-1."""
    root = _isolate(tmp_path, "violation_block_operation_init.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "AOB-1" in out
    assert "violation_block_operation_init.swift" in out


def test_violation_block_operation_labeled_is_flagged(tmp_path):
    """`BlockOperation(block: { ... })` — MUST flag AOB-1."""
    root = _isolate(tmp_path, "violation_block_operation_labeled.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "AOB-1" in out
    assert "violation_block_operation_labeled.swift" in out


def test_violation_completion_block_assign_is_flagged(tmp_path):
    """`.completionBlock = { ... }` — MUST flag AOB-1."""
    root = _isolate(tmp_path, "violation_completion_block_assign.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "AOB-1" in out
    assert "violation_completion_block_assign.swift" in out


# --- Clean fixtures ---------------------------------------------------------

def test_clean_hoisted_all_forms_passes(tmp_path):
    """The CANONICAL fix (ImageCache.swift pattern): every closure is bound to
    an explicitly-typed `let` before being handed to the API. MUST pass with
    exit 0 and no AOB-1 finding."""
    root = _isolate(tmp_path, "clean_hoisted_all_forms.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "AOB-1" not in out


def test_clean_annotation_escape_hatch_passes(tmp_path):
    """`// no-addoperation-literal-ban: <reason>` on the preceding line MUST
    suppress the finding."""
    root = _isolate(tmp_path, "clean_annotation_escape.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "AOB-1" not in out


def test_clean_addoperations_plural_passes(tmp_path):
    """`addOperations` (plural, array API) is out of scope — MUST NOT flag."""
    root = _isolate(tmp_path, "clean_addoperations_plural.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "AOB-1" not in out


def test_clean_empty_diff_passes(tmp_path):
    """`--diff` path on a no-op (empty) diff must exit 0 — the clean-diff half
    of the CLAUDE.md gate-rule contract (a wiring bug that always-fires would
    be invisible to a violation-only fixture)."""
    diff_file = tmp_path / "empty.diff"
    diff_file.write_text("")
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--diff", str(diff_file), "--quiet"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"empty diff must pass, got exit {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )


def test_diff_scoped_ignores_unrelated_added_lines(tmp_path):
    """A diff that adds an unrelated Swift line elsewhere in the SAME file as
    a pre-existing (not newly-added) literal must NOT flag it — the detector
    is diff-scoped (only lines this diff ADDS), not whole-file scan-on-touch."""
    diff_text = """diff --git a/Palace/Foo/Existing.swift b/Palace/Foo/Existing.swift
--- a/Palace/Foo/Existing.swift
+++ b/Palace/Foo/Existing.swift
@@ -1,4 +1,5 @@
 import Foundation
 queue.addOperation {
     print("pre-existing literal, not part of this diff")
 }
+let unrelated = 1
"""
    diff_file = tmp_path / "unrelated.diff"
    diff_file.write_text(diff_text)
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--diff", str(diff_file), "--quiet"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"expected exit 0 (only an unrelated line was added), got "
        f"{result.returncode}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "AOB-1" not in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))

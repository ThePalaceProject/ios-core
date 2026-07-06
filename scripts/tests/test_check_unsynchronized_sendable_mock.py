#!/usr/bin/env python3
"""
test_check_unsynchronized_sendable_mock.py — self-verify the segv-class
detector added in fix/sync-mock-race-segv-bookmark-keys.

Builds tiny synthetic Mocks/ + tests/ trees in tmp_path and asserts each
branch of the join:
  - violation: unsynchronized @unchecked Sendable mock + concurrent test → rc 1
  - clean: locked mock + concurrent test → rc 0        (the clean-diff pass —
    a detector that rejects a compliant tree must not land)
  - latent: unsynchronized mock, NO concurrent usage → rc 0 (note only),
    rc 1 under --strict
  - deferred: violation carrying the deferral marker → rc 0, reported as note
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-unsynchronized-sendable-mock.py"

UNSYNCED_MOCK = """
import Foundation
class BadMock: NSObject, SomeProvider, @unchecked Sendable {
    var registry = [String: Int]()
    func set(_ v: Int, for k: String) { registry[k] = v }
}
"""

LOCKED_MOCK = """
import Foundation
class GoodMock: NSObject, SomeProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _registry = [String: Int]()
    func set(_ v: Int, for k: String) { lock.withLock { _registry[k] = v } }
}
"""

DEFERRED_MOCK = """
import Foundation
// unsync-sendable-mock-deferred: PP-XXXX big blast radius
class DeferredMock: NSObject, SomeProvider, @unchecked Sendable {
    var registry = [String: Int]()
}
"""

CONCURRENT_TEST_TEMPLATE = """
import XCTest
final class SomeTests: XCTestCase {{
    func testHammer() {{
        let mock = {mock}()
        for i in 0..<100 {{
            DispatchQueue.global().async {{ mock.set(i, for: "k") }}
        }}
    }}
}}
"""

SEQUENTIAL_TEST_TEMPLATE = """
import XCTest
final class SomeTests: XCTestCase {{
    func testSequential() {{
        let mock = {mock}()
        mock.set(1, for: "k")
    }}
}}
"""


def _run(tmp: Path, *extra: str) -> tuple[int, str]:
    result = subprocess.run(
        ["python3", str(_SCRIPT),
         "--mocks-dir", str(tmp / "Mocks"),
         "--tests-dir", str(tmp / "tests"), *extra],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30,
    )
    return result.returncode, result.stdout + result.stderr


def _tree(tmp: Path, mock_src: str, test_src: str) -> Path:
    (tmp / "Mocks").mkdir()
    (tmp / "tests").mkdir()
    (tmp / "Mocks" / "Mock.swift").write_text(mock_src, encoding="utf-8")
    (tmp / "tests" / "SomeTests.swift").write_text(test_src, encoding="utf-8")
    return tmp


def test_violation_unsynced_mock_used_concurrently(tmp_path):
    _tree(tmp_path, UNSYNCED_MOCK, CONCURRENT_TEST_TEMPLATE.format(mock="BadMock"))
    rc, out = _run(tmp_path)
    assert rc == 1, out
    assert "BadMock" in out and "concurrent test" in out


def test_clean_locked_mock_passes(tmp_path):
    _tree(tmp_path, LOCKED_MOCK, CONCURRENT_TEST_TEMPLATE.format(mock="GoodMock"))
    rc, out = _run(tmp_path)
    assert rc == 0, out
    assert "GoodMock" not in out.replace("no unsynchronized", "")


def test_latent_unsynced_mock_is_note_only(tmp_path):
    _tree(tmp_path, UNSYNCED_MOCK, SEQUENTIAL_TEST_TEMPLATE.format(mock="BadMock"))
    rc, out = _run(tmp_path)
    assert rc == 0, out
    assert "latent" in out


def test_latent_fails_under_strict(tmp_path):
    _tree(tmp_path, UNSYNCED_MOCK, SEQUENTIAL_TEST_TEMPLATE.format(mock="BadMock"))
    rc, out = _run(tmp_path, "--strict")
    assert rc == 1, out


def test_deferral_marker_downgrades_to_note(tmp_path):
    _tree(tmp_path, DEFERRED_MOCK, CONCURRENT_TEST_TEMPLATE.format(mock="DeferredMock"))
    rc, out = _run(tmp_path)
    assert rc == 0, out
    assert "deferred" in out and "PP-XXXX" in out


def test_missing_dirs_are_clean_pass_not_error(tmp_path):
    """The false-red-prevention branch (2026-06-08 wiring-bug class): a tree
    with no Mocks/tests dirs (hook fixture repos, checkouts without the test
    target) must be a clean pass, not an argparse/IO error that would block
    every commit."""
    rc, out = _run(tmp_path)  # tmp_path has neither Mocks/ nor tests/
    assert rc == 0, out
    assert "nothing to scan" in out


def test_repo_tree_is_currently_clean():
    """The live repo must pass — the mock this detector was born from is now
    locked, and the one known-wide survivor carries the deferral marker."""
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--quiet"],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=60,
    )
    assert result.returncode == 0, result.stdout + result.stderr

"""
test_check_blast_radius.py — pytest for the blast-radius detector (BLOCKING).

scripts/check-blast-radius.py scans a UNIFIED DIFF (not a source tree) for
newly-exposed API/visibility/test-seam surface. It reads the diff from
`--diff <file>` or stdin, prints greppable `<file>:<line>: <BR-N>: <sev>: ...`
findings, and exits:
  0  — no finding at/above the severity floor (default: high)
  1  — at least one finding at/above the floor
  2  — argument / I/O error

Because it is diff-driven, each test synthesizes a minimal unified diff and
feeds it on stdin. Every BR category test asserts BOTH the violation path
(exit 1 + the BR code present) and, per CLAUDE.md rule #4, a clean-diff path
(exit 0 + no finding) — the clean-pass assertion is the one that catches the
scan-only-detector-called-with-a-diff wiring bug.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-blast-radius.py"


def _run(diff_text: str, *extra: str) -> subprocess.CompletedProcess:
    """Invoke check-blast-radius.py with `diff_text` on stdin.

    Passes `--quiet` to keep stderr clean; extra args are appended verbatim.
    """
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--quiet", *extra],
        input=diff_text,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _diff(path: str, added_lines: list[str], start: int = 1) -> str:
    """Build a minimal unified diff that ADDS `added_lines` to `path`.

    One leading context line is included so the hunk header is well-formed
    for iter_hunk_lines (it only needs the `+++ b/` header + a `@@ +start @@`).
    """
    body = [f"+++ b/{path}", f"@@ -{start},1 +{start},{len(added_lines) + 1} @@",
            " // context anchor"]
    body.extend("+" + ln for ln in added_lines)
    return "\n".join(body) + "\n"


# --- BR-1: new public/open symbol on a prod Swift file ---------------------

def test_new_public_decl_on_prod_file_is_flagged():
    """A newly-added `public func` on a production Swift file is BR-1 (high)
    and must block (exit 1)."""
    diff = _diff("Palace/Book/BookDetail.swift",
                 ["    public func newlyExposedAPI() -> Int { 42 }"])
    r = _run(diff)
    assert r.returncode == 1, (
        f"expected exit 1, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-1" in r.stdout, f"expected BR-1 finding, got: {r.stdout!r}"
    assert "Palace/Book/BookDetail.swift" in r.stdout


def test_internal_decl_on_prod_file_is_clean():
    """The clean-pass control: an `internal func` addition adds no public
    surface, so the detector must PASS (exit 0, no finding)."""
    diff = _diff("Palace/Book/BookDetail.swift",
                 ["    internal func stillInternal() -> Int { 42 }"])
    r = _run(diff)
    assert r.returncode == 0, (
        f"expected exit 0, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert r.stdout.strip() == "", f"expected no findings, got: {r.stdout!r}"


def test_public_decl_with_PUBLIC_INTENT_annotation_is_suppressed():
    """The documented escape hatch: a `// PUBLIC_INTENT:` comment on the
    preceding line suppresses BR-1 for contracted SPM API. Must PASS."""
    diff = _diff("Palace/CatalogDomain/ContentTypes.swift", [
        "    // PUBLIC_INTENT: consumed by downstream Catalog SPM module",
        "    public let contentTypeFoo = \"foo\"",
    ])
    r = _run(diff)
    assert r.returncode == 0, (
        f"expected exit 0 (suppressed), got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-1" not in r.stdout, f"expected BR-1 suppressed, got: {r.stdout!r}"


def test_public_decl_on_test_file_is_ignored():
    """Non-prod paths (PalaceTests/, Mocks/, Utilities/Testing/) are exempt —
    a `public` on a test file must NOT be flagged."""
    diff = _diff("PalaceTests/Mocks/FakeThing.swift",
                 ["    public func spyHook() {}"])
    r = _run(diff)
    assert r.returncode == 0, (
        f"expected exit 0, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-1" not in r.stdout


# --- BR-5: discarded function result without TODO justification ------------

def test_discarded_result_without_todo_is_flagged_at_medium_floor():
    """`let _ = fn(...)` without a `// TODO(TICKET):` is BR-5 (medium). It
    blocks only when the floor is lowered to medium."""
    diff = _diff("Palace/MyBooks/Downloader.swift",
                 ["        let _ = startDownload(book)"])
    r = _run(diff, "--severity-floor", "medium")
    assert r.returncode == 1, (
        f"expected exit 1 at medium floor, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-5" in r.stdout, f"expected BR-5 finding, got: {r.stdout!r}"


def test_discarded_result_with_todo_is_clean():
    """The clean-pass control: same discard WITH a `// TODO(PP-1234):`
    justification on the line must PASS even at the medium floor."""
    diff = _diff("Palace/MyBooks/Downloader.swift",
                 ["        let _ = startDownload(book)  // TODO(PP-1234): fire-and-forget"])
    r = _run(diff, "--severity-floor", "medium")
    assert r.returncode == 0, (
        f"expected exit 0, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-5" not in r.stdout, f"expected no BR-5, got: {r.stdout!r}"


def test_medium_finding_does_not_block_at_default_high_floor():
    """BR-5 is medium; at the DEFAULT high floor a lone discard prints but
    does not block (exit 0). Guards the severity-floor wiring."""
    diff = _diff("Palace/MyBooks/Downloader.swift",
                 ["        let _ = startDownload(book)"])
    r = _run(diff)  # default floor = high
    assert r.returncode == 0, (
        f"expected exit 0 at high floor, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    # The finding is still printed (visibility) even though it does not block.
    assert "BR-5" in r.stdout


# --- BR-4: composition-root init churn on a *Container.swift file ----------

def test_new_init_on_container_file_is_flagged():
    """A new `init(` on AppContainer.swift is BR-4 (high) — hidden
    composition-root churn — and must block."""
    diff = _diff("Palace/AppInfrastructure/AppContainer.swift",
                 ["    init(testOverride: Foo) {"])
    r = _run(diff)
    assert r.returncode == 1, (
        f"expected exit 1, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert "BR-4" in r.stdout, f"expected BR-4 finding, got: {r.stdout!r}"


# --- Empty / no-op diff sanity --------------------------------------------

def test_empty_diff_passes():
    """A diff with no added prod-Swift lines yields no findings (exit 0).
    The floor of the clean-pass contract."""
    r = _run("")
    assert r.returncode == 0, (
        f"expected exit 0 on empty diff, got {r.returncode}\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert r.stdout.strip() == ""


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))

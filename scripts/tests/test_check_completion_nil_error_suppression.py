#!/usr/bin/env python3
"""
test_check_completion_nil_error_suppression.py — self-verify the D3 detector.

Runs scripts/check-completion-nil-error-suppression.py via `--scan` against the
sibling per-shape Swift fixtures and asserts the predicate fires (or doesn't)
in alignment with the PP-4419 / HelpSpot 17870 wall-failure spec and the
Phase-1a-revised architect false-positive guard at OAuth+244.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-completion-nil-error-suppression.py"
_FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "completion_nil_error"


def _run_scan(scan_root: Path) -> tuple[int, str, str]:
    """Invoke the detector in --scan mode; return (rc, stdout, stderr)."""
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--scan", str(scan_root), "--quiet"],
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


# --- Violation fixtures ----------------------------------------------------

def test_violation_string_literals_is_flagged(tmp_path):
    """`completion(nil, "Sign In Failed", "...")` — the PR547e185aa pre-fix
    shape with inline string literals in args 2-3. MUST flag at D3-1 high."""
    root = _isolate(tmp_path, "violation_string_literals.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "D3-1" in out, f"expected D3-1 finding. stdout={out!r}"
    assert "high" in out, f"expected high severity. stdout={out!r}"
    assert "PP-4419" in out, f"expected PP-4419 wall-failure cite. stdout={out!r}"
    assert "violation_string_literals.swift" in out, (
        f"expected fixture name in path. stdout={out!r}"
    )


def test_violation_bound_title_message_is_flagged(tmp_path):
    """`let title = "..."; let message = "..."; completion?(nil, title, message)`
    — same bug class with title/message bound by-name. MUST flag at D3-1."""
    root = _isolate(tmp_path, "violation_bound_title_message.swift")
    rc, out, err = _run_scan(root)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "D3-1" in out, f"expected D3-1 finding. stdout={out!r}"
    assert "violation_bound_title_message.swift" in out


# --- Clean fixtures --------------------------------------------------------

def test_clean_with_synthesized_nserror_passes(tmp_path):
    """The CANONICAL fix (commit 547e185aa): arg-1 is an NSError, not nil.
    MUST pass with exit 0 and no D3-1 finding."""
    root = _isolate(tmp_path, "clean_with_synthesized_nserror.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "D3-1" not in out, f"unexpected D3-1 finding. stdout={out!r}"


def test_clean_omits_title_message_passes(tmp_path):
    """Single-arg, two-arg-bool, and failure-passthrough shapes — none have
    title/message string literals after the nil error. MUST pass with exit 0."""
    root = _isolate(tmp_path, "clean_omits_title_message.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "D3-1" not in out, f"unexpected D3-1 finding. stdout={out!r}"


def test_clean_with_annotation_passes(tmp_path):
    """`// no-nil-error-suppression: <reason>` on the call line or preceding
    3 lines suppresses the detector. MUST pass with exit 0."""
    root = _isolate(tmp_path, "clean_with_annotation.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "D3-1" not in out, f"unexpected D3-1 finding. stdout={out!r}"


def test_clean_all_nil_success_path_passes(tmp_path):
    """Phase-1a-revised false-positive guard: `completion?(nil, nil, nil)` is
    the OAuth success path (verified at
    Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244). The detector
    predicate MUST NOT fire on this shape — if it does, the predicate is too
    broad and needs tightening."""
    root = _isolate(tmp_path, "clean_all_nil_success_path.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, (
        f"FALSE POSITIVE on OAuth success path. stdout={out!r} stderr={err!r}"
    )
    assert "D3-1" not in out, (
        f"FALSE POSITIVE: detector flagged the all-nil success-path shape — "
        f"predicate is too broad. stdout={out!r}"
    )


def test_no_completion_in_scope_passes(tmp_path):
    """False-positive immunity: nil-first-arg calls with string args 2-3 whose
    receiver is NOT `*completion` (e.g. `delegate`, `onResult`). Detector
    requires the completion-receiver shape. MUST pass with exit 0."""
    root = _isolate(tmp_path, "clean_no_completion_in_scope.swift")
    rc, out, err = _run_scan(root)
    assert rc == 0, f"expected exit 0, got {rc}. stdout={out!r} stderr={err!r}"
    assert "D3-1" not in out, f"unexpected D3-1 finding. stdout={out!r}"


# --- Integration sanity ----------------------------------------------------

def test_oauth_success_path_in_real_codebase_is_not_flagged():
    """Direct anti-regression test against the real source file. The OAuth
    success path lives at TPPSignInBusinessLogic+OAuth.swift:244 — if a future
    detector tweak picks it up, this test fails immediately."""
    oauth_file = (
        _REPO_ROOT / "Palace" / "SignInLogic"
        / "TPPSignInBusinessLogic+OAuth.swift"
    )
    if not oauth_file.is_file():
        pytest.skip(f"OAuth file not present at expected path: {oauth_file}")
    # Build a tmp tree containing ONLY the OAuth file so the scan is scoped.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        palace = td_path / "Palace" / "SignInLogic"
        palace.mkdir(parents=True)
        (palace / oauth_file.name).write_text(
            oauth_file.read_text(encoding="utf-8"), encoding="utf-8"
        )
        rc, out, err = _run_scan(td_path)
    assert "TPPSignInBusinessLogic+OAuth.swift:244" not in out, (
        f"REGRESSION: detector flagged the OAuth+244 success path. "
        f"Tighten the predicate; do NOT silently annotate. "
        f"stdout={out!r}"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))

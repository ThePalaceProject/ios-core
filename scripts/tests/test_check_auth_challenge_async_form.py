#!/usr/bin/env python3
"""
test_check_auth_challenge_async_form.py — self-verify the ACF-1 detector
(scripts/check-auth-challenge-async-form.py).

Guards the PP-4895 regression class: an authentication-challenge delegate
callback written in the completion-handler form can be left unmatched by the
Xcode 26.2 ClangImporter (WebKit annotates the shared canonical block type
`@MainActor`, Foundation does not, first import in the batch wins), which strips
the method from the ObjC runtime entirely — so URLSession, which invokes
optional delegate methods only via `respondsToSelector:`, never calls it and the
challenge goes unanswered with no error and no crash.

Asserts the predicate fires on all three arms of the collision (task-level
challenge, session-level challenge, and WebKit's side — whichever side loses the
import lottery is the broken one), and that it PASSES the approved async
spelling, the escape hatch, an unrelated completion-handler delegate method, and
— the failure mode sibling ratchet detectors have actually hit — source whose
COMMENTS name both banned tokens while the code is clean.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-auth-challenge-async-form.py"
_FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "auth_challenge_async_form"


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


def _run_diff(diff_text: str, cwd: Path) -> tuple[int, str, str]:
    """Invoke the detector in --diff mode over stdin."""
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--diff", "-", "--quiet"],
        input=diff_text,
        capture_output=True,
        text=True,
        cwd=str(cwd),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def _isolate(tmp_path: Path, fixture_name: str) -> Path:
    """Copy ONE fixture into a tmp Palace/ tree so --scan sees only it."""
    src = _FIXTURE_DIR / fixture_name
    assert src.is_file(), f"missing fixture: {src}"
    palace = tmp_path / "Palace"
    palace.mkdir(exist_ok=True)
    (palace / fixture_name).write_text(src.read_text(encoding="utf-8"),
                                      encoding="utf-8")
    return tmp_path


# --- Violations: every arm of the shared-block-type collision ----------------

def test_violation_task_level_challenge_is_flagged(tmp_path):
    """The PP-4895 shape itself — URLSessionTaskDelegate. MUST flag ACF-1."""
    rc, out, _ = _run_scan(_isolate(
        tmp_path, "violation_urlsession_task_completion_handler.swift"))
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "ACF-1" in out, f"expected ACF-1 finding. stdout={out!r}"
    assert "high" in out
    assert "violation_urlsession_task_completion_handler.swift" in out


def test_violation_session_level_challenge_is_flagged(tmp_path):
    """URLSessionDelegate's session-level challenge shares the block type."""
    rc, out, _ = _run_scan(_isolate(
        tmp_path, "violation_urlsession_session_level.swift"))
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "ACF-1" in out


def test_violation_webkit_side_is_flagged(tmp_path):
    """WebKit's own auth challenge is the arm that breaks when Foundation wins
    the import lottery — banning only the Foundation side would leave the
    invariant half-encoded."""
    rc, out, _ = _run_scan(_isolate(
        tmp_path, "violation_webkit_navigation_delegate.swift"))
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "ACF-1" in out


def test_violation_reports_the_declaration_line(tmp_path):
    """The finding must point at the `func` line, not at the file."""
    rc, out, _ = _run_scan(_isolate(
        tmp_path, "violation_urlsession_task_completion_handler.swift"))
    assert rc != 0
    line = next(l for l in out.splitlines() if "ACF-1" in l)
    reported = int(line.split(":")[1])
    assert reported == 6, f"expected the func line (6), got {reported}: {line!r}"


# --- Clean fixtures: the detector must not block correct code ----------------

def test_clean_async_form_passes(tmp_path):
    """The approved spelling. MUST PASS."""
    rc, out, _ = _run_scan(_isolate(tmp_path, "clean_async_form.swift"))
    assert rc == 0, f"expected clean pass, got rc={rc}. stdout={out!r}"
    assert out.strip() == ""


def test_clean_comment_mentions_only_passes(tmp_path):
    """Prose naming both banned tokens must not trip the gate. This is the
    concrete failure mode of the substring-grep ratchet detectors, and the
    production files fixed by PP-4895 carry exactly such comments."""
    rc, out, _ = _run_scan(_isolate(tmp_path, "clean_comment_mentions_only.swift"))
    assert rc == 0, f"comment-only mention must not block. stdout={out!r}"


def test_clean_annotation_escape_passes(tmp_path):
    """The documented `// no-auth-challenge-async-form:` hatch. MUST PASS."""
    rc, out, _ = _run_scan(_isolate(tmp_path, "clean_annotation_escape.swift"))
    assert rc == 0, f"escape hatch must pass. stdout={out!r}"


def test_clean_unrelated_completion_handler_passes(tmp_path):
    """A completion-handler delegate method with no challenge, and a challenge
    helper with no completion handler — neither is the poisoned shape."""
    rc, out, _ = _run_scan(_isolate(
        tmp_path, "clean_unrelated_completion_handler.swift"))
    assert rc == 0, f"unrelated shapes must pass. stdout={out!r}"


def test_test_target_sources_are_out_of_scope(tmp_path):
    """A violation under PalaceTests/ is out of scope — tests legitimately build
    challenge fixtures and stand up throwaway delegates."""
    src = _FIXTURE_DIR / "violation_urlsession_task_completion_handler.swift"
    tests_dir = tmp_path / "PalaceTests"
    tests_dir.mkdir()
    (tests_dir / "SomeDelegateTests.swift").write_text(
        src.read_text(encoding="utf-8"), encoding="utf-8")
    (tmp_path / "Palace").mkdir()
    rc, out, _ = _run_scan(tmp_path)
    assert rc == 0, f"PalaceTests/ must be out of scope. stdout={out!r}"


# --- Diff mode ---------------------------------------------------------------

def test_diff_mode_flags_an_added_violation(tmp_path):
    """Diff mode is how the pre-commit path invokes this. An added violating
    signature must block."""
    (tmp_path / "Palace").mkdir()
    diff = (
        "diff --git a/Palace/New.swift b/Palace/New.swift\n"
        "--- /dev/null\n"
        "+++ b/Palace/New.swift\n"
        "@@ -0,0 +1,8 @@\n"
        "+import Foundation\n"
        "+final class D: NSObject, URLSessionTaskDelegate {\n"
        "+    func urlSession(_ s: URLSession,\n"
        "+                    task: URLSessionTask,\n"
        "+                    didReceive c: URLAuthenticationChallenge,\n"
        "+                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {\n"
        "+    }\n"
        "+}\n"
    )
    rc, out, _ = _run_diff(diff, tmp_path)
    assert rc != 0, f"expected non-zero exit, got 0. stdout={out!r}"
    assert "ACF-1" in out


def test_diff_mode_passes_a_clean_diff(tmp_path):
    """The clean-diff path MUST pass. A detector invoked with an interface it
    rejects (or one that mis-parses a normal diff) would block every commit;
    asserting only the violation path leaves that hole open."""
    (tmp_path / "Palace").mkdir()
    diff = (
        "diff --git a/Palace/New.swift b/Palace/New.swift\n"
        "--- /dev/null\n"
        "+++ b/Palace/New.swift\n"
        "@@ -0,0 +1,7 @@\n"
        "+import Foundation\n"
        "+final class D: NSObject, URLSessionTaskDelegate {\n"
        "+    func urlSession(_ s: URLSession,\n"
        "+                    task: URLSessionTask,\n"
        "+                    didReceive c: URLAuthenticationChallenge)\n"
        "+    async -> (URLSession.AuthChallengeDisposition, URLCredential?) {\n"
        "+        (.performDefaultHandling, nil) }\n"
        "+}\n"
    )
    rc, out, _ = _run_diff(diff, tmp_path)
    assert rc == 0, f"clean diff must pass. rc={rc} stdout={out!r}"


def test_diff_mode_ignores_an_untouched_preexisting_violation(tmp_path):
    """Diff mode is ADDED-lines scoped, so an unrelated one-line edit to a file
    that already holds a violation must not block that commit."""
    palace = tmp_path / "Palace"
    palace.mkdir()
    src = (_FIXTURE_DIR / "violation_urlsession_task_completion_handler.swift"
           ).read_text(encoding="utf-8")
    (palace / "Legacy.swift").write_text(src + "\n// trailing note\n",
                                        encoding="utf-8")
    diff = (
        "diff --git a/Palace/Legacy.swift b/Palace/Legacy.swift\n"
        "--- a/Palace/Legacy.swift\n"
        "+++ b/Palace/Legacy.swift\n"
        f"@@ -14,0 +{len(src.splitlines()) + 1},1 @@\n"
        "+// trailing note\n"
    )
    rc, out, _ = _run_diff(diff, tmp_path)
    assert rc == 0, f"untouched pre-existing violation must not block. stdout={out!r}"

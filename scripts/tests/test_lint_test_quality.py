"""Contract tests for scripts/lint-test-quality.py — with a focus on the
DIFF-SCOPED STARVE-001 rule (recurrence class `parallel-clone-starvation`).

STARVE-001 blocks NEWLY-INTRODUCED fixed-deadline waits on async work
(`fulfillment(of:timeout:)`, `wait(for:timeout:)`, `waitForExpectations(timeout:)`)
because they starve under the 2 parallel sim clones on the CI macOS runner and
fail all 3 `-retry-tests-on-failure` iterations. It runs over ADDED diff lines
ONLY — never the full tree — so it does not wall the board red on the ~675 legacy
occurrences (green-board contract).

The green-board contract (CLAUDE.md "CI/CD reliability" #4) requires BOTH:
  * a violation-path assertion (the rule FIRES on a real violation), AND
  * a CLEAN-DIFF pass assertion (a diff the rule should accept does NOT block).
Both are pinned below, plus scoping guards (context lines, comments, allow-list,
non-test paths) and a regression check that the pre-existing full-scan rules
(MISSING-001 etc.) are untouched and that STARVE-001 never leaks into full-scan.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "lint-test-quality.py"


# --- module import (hyphenated filename → importlib) ------------------------

def _load_module():
    spec = importlib.util.spec_from_file_location("lint_test_quality", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_LTQ = _load_module()


# --- diff fixtures ----------------------------------------------------------

def _new_file_diff(path: str, added_lines: list[str]) -> str:
    """A unified diff that ADDS `path` as a new file with `added_lines`."""
    body = "".join(f"+{l}\n" for l in added_lines)
    return (
        f"diff --git a/{path} b/{path}\n"
        "new file mode 100644\n"
        "index 0000000..1111111\n"
        "--- /dev/null\n"
        f"+++ b/{path}\n"
        f"@@ -0,0 +1,{len(added_lines)} @@\n"
        f"{body}"
    )


# A fire-and-forget async test that waits on a fixed deadline — the violation.
_VIOLATION_LINES = [
    "import XCTest",
    "final class BarTests: XCTestCase {",
    "  func testAsync() async {",
    "    let e = XCTestExpectation(description: \"load\")",
    "    viewModel.$isLoaded.filter { $0 }.sink { _ in e.fulfill() }.store(in: &bag)",
    "    await viewModel.load()",
    "    await fulfillment(of: [e], timeout: 5)",
    "  }",
    "}",
]

# The corrected form — joins the real work via a Task-join seam. Clean.
_CLEAN_LINES = [
    "import XCTest",
    "final class BarTests: XCTestCase {",
    "  func testAsync() async {",
    "    await viewModel.load()",
    "    await viewModel._awaitTrackedWorkForTesting()",
    "    XCTAssertTrue(viewModel.isLoaded)",
    "  }",
    "}",
]


def _run_diff(diff_text: str) -> subprocess.CompletedProcess:
    """Invoke the linter's diff gate, feeding the diff on stdin (`--diff -`)."""
    # --quiet suppresses only the "no violations" success line; a real
    # violation still prints, so the clean path emits nothing and the
    # `"STARVE-001" not in stdout` assertion is unambiguous.
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--diff", "-", "--quiet"],
        input=diff_text, capture_output=True, text=True, cwd=_REPO,
    )


# --- (i) violation-path: STARVE-001 FIRES ----------------------------------

def test_starve001_flags_fulfillment_deadline_on_added_line():
    diff = _new_file_diff("PalaceTests/Foo/BarTests.swift", _VIOLATION_LINES)
    r = _run_diff(diff)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "STARVE-001" in r.stdout
    assert "PalaceTests/Foo/BarTests.swift" in r.stdout


@pytest.mark.parametrize("wait_line", [
    "    await fulfillment(of: [e], timeout: 5)",
    "    wait(for: [e], timeout: 5.0)",
    "    waitForExpectations(timeout: 3)",
])
def test_starve001_flags_each_deadline_shape(wait_line):
    diff = _new_file_diff(
        "PalaceTests/X/YTests.swift",
        ["func testX() {", wait_line, "}"],
    )
    r = _run_diff(diff)
    assert r.returncode == 1, r.stdout
    assert "STARVE-001" in r.stdout


# --- (ii) CLEAN-DIFF pass: the mandatory green-board assertion --------------

def test_starve001_clean_taskjoin_diff_passes():
    """A changed test file that joins the real work via a Task-join seam (no
    fixed deadline) must NOT trip the rule — the clean-diff pass the green-board
    contract requires so an accepted interface never blocks."""
    diff = _new_file_diff("PalaceTests/Foo/BarTests.swift", _CLEAN_LINES)
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "STARVE-001" not in r.stdout


def test_starve001_pure_sync_assertions_diff_passes():
    diff = _new_file_diff(
        "PalaceTests/Foo/SyncTests.swift",
        ["func testTotal() {", "  XCTAssertEqual(cart.total, 15.99)", "}"],
    )
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout


# --- scoping guards (no false positives) -----------------------------------

def test_starve001_allowlist_comment_suppresses():
    diff = _new_file_diff(
        "PalaceTests/Foo/IntegrationTests.swift",
        ["func testIO() {",
         "  wait(for: [e], timeout: 5) // STARVE-001-OK: real bounded I/O op",
         "}"],
    )
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout


def test_starve001_ignores_commented_out_line():
    diff = _new_file_diff(
        "PalaceTests/Foo/CommentTests.swift",
        ["func testX() {",
         "  // await fulfillment(of: [e], timeout: 5)  <- migrated away",
         "  await sut._awaitTrackedWorkForTesting()",
         "}"],
    )
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout


def test_starve001_scoped_to_test_files_not_production():
    """A `wait(for:` added in a production Palace/ file is out of scope — the
    rule is about test-side deadline polls, not production code."""
    diff = _new_file_diff("Palace/Foo/Bar.swift",
                          ["func f() { wait(for: [e], timeout: 5) }"])
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout


def test_starve001_ignores_preexisting_context_line():
    """A legacy deadline-poll that appears only as diff CONTEXT (space-prefixed,
    unchanged) must NOT flag — the rule fires on genuinely NEW lines only, so a
    PR editing a neighbor of a legacy poll is not blocked on it."""
    diff = (
        "diff --git a/PalaceTests/Foo/BarTests.swift b/PalaceTests/Foo/BarTests.swift\n"
        "--- a/PalaceTests/Foo/BarTests.swift\n"
        "+++ b/PalaceTests/Foo/BarTests.swift\n"
        "@@ -10,3 +10,4 @@ final class BarTests {\n"
        "   await fulfillment(of: [e], timeout: 5)\n"   # context (space) — legacy
        "+  XCTAssertTrue(sut.isLoaded)\n"              # the only ADDED line
        "   }\n"
        " }\n"
    )
    r = _run_diff(diff)
    assert r.returncode == 0, r.stdout


# --- unit level: parser + detector -----------------------------------------

def test_parse_added_lines_tracks_only_plus_lines_with_line_numbers():
    diff = (
        "diff --git a/PalaceTests/A.swift b/PalaceTests/A.swift\n"
        "--- a/PalaceTests/A.swift\n"
        "+++ b/PalaceTests/A.swift\n"
        "@@ -5,2 +5,3 @@\n"
        " context\n"          # line 5
        "-removed\n"          # does not advance post-image counter
        "+added-one\n"        # line 6
        "+added-two\n"        # line 7
    )
    added = _LTQ.parse_added_lines(diff)
    texts = [(a.path, a.line_no, a.text) for a in added]
    assert ("PalaceTests/A.swift", 6, "added-one") in texts
    assert ("PalaceTests/A.swift", 7, "added-two") in texts
    assert all(a.text not in ("context", "removed") for a in added)


def test_lint_starvation_diff_returns_violation_objects():
    diff = _new_file_diff("PalaceTests/Foo/BarTests.swift", _VIOLATION_LINES)
    findings = _LTQ.lint_starvation_diff(diff)
    assert len(findings) == 1
    assert findings[0].rule == "STARVE-001"
    assert findings[0].file == "PalaceTests/Foo/BarTests.swift"


# --- (iii) existing rules untouched ----------------------------------------

def test_full_scan_missing001_still_fires(tmp_path):
    """A pre-existing rule (MISSING-001) still blocks in the default --file scan,
    proving the STARVE additions didn't disturb the established gate."""
    f = tmp_path / "NoAssertTests.swift"
    f.write_text(
        "import XCTest\n"
        "final class NoAssertTests: XCTestCase {\n"
        "  func testDoesNothing() {\n"
        "    let x = Foo()\n"
        "    x.doWork()\n"
        "  }\n"
        "}\n"
    )
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--file", str(f)],
        capture_output=True, text=True, cwd=_REPO,
    )
    assert r.returncode == 1, r.stdout
    assert "MISSING-001" in r.stdout


def test_full_scan_never_emits_starve001(tmp_path):
    """STARVE-001 is diff-only: a full-tree/--file scan of a file FULL of
    deadline polls must NOT emit it (that is exactly the 675-legacy wall the
    scoping avoids)."""
    f = tmp_path / "LegacyPollTests.swift"
    f.write_text(
        "import XCTest\n"
        "final class LegacyPollTests: XCTestCase {\n"
        "  func testA() async {\n"
        "    let e = XCTestExpectation(description: \"x\")\n"
        "    await fulfillment(of: [e], timeout: 5)\n"
        "    XCTAssertTrue(true)\n"
        "  }\n"
        "}\n"
    )
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--file", str(f)],
        capture_output=True, text=True, cwd=_REPO,
    )
    assert "STARVE-001" not in r.stdout


# --- --changed git entry point (the actual CI invocation) ------------------

def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)


def test_changed_mode_end_to_end_flags_new_poll(tmp_path):
    """Exercise the real CI entry point: a throwaway git repo with a base commit
    and a branch that ADDS a deadline-poll test file. `--changed <base>` must
    diff against base and block."""
    repo = tmp_path / "repo"
    (repo / "PalaceTests" / "Foo").mkdir(parents=True)
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@t.io")
    _git(repo, "config", "user.name", "t")
    # Base commit: a clean test file.
    tf = repo / "PalaceTests" / "Foo" / "BarTests.swift"
    tf.write_text("\n".join(_CLEAN_LINES) + "\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    base_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    # Change: introduce a deadline poll.
    tf.write_text("\n".join(_VIOLATION_LINES) + "\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "add poll")

    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--changed", base_sha],
        capture_output=True, text=True, cwd=repo,
    )
    assert r.returncode == 1, r.stdout + r.stderr
    assert "STARVE-001" in r.stdout


def test_changed_mode_end_to_end_clean_passes(tmp_path):
    repo = tmp_path / "repo"
    (repo / "PalaceTests" / "Foo").mkdir(parents=True)
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@t.io")
    _git(repo, "config", "user.name", "t")
    tf = repo / "PalaceTests" / "Foo" / "BarTests.swift"
    tf.write_text("// baseline\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    base_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    tf.write_text("\n".join(_CLEAN_LINES) + "\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "add clean test")

    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--changed", base_sha],
        capture_output=True, text=True, cwd=repo,
    )
    assert r.returncode == 0, r.stdout + r.stderr


# --- FLUFF-005 / FLUFF-006: assertions that cannot fail ---------------------
#
# Added 2026-08-18. A reviewer found 34 `XCTAssertTrue(true, ...)` in
# PalaceTests/LCP/LCPAudiobooksTests.swift — a DRM path — while this linter
# reported the file clean. 76 across 14 files corpus-wide. CLAUDE.md bans
# assertions "mathematically guaranteed to pass"; nothing enforced it.

def _lint_source(tmp_path, body: str) -> list:
    """Run the file-level linter over a synthetic test file."""
    f = tmp_path / "SomeTests.swift"
    f.write_text(body)
    return _LTQ.lint_file(str(f))


def _codes(violations) -> str:
    return " ".join(str(getattr(v, "message", v)) for v in violations)


def test_fluff005_flags_assert_true_on_literal(tmp_path):
    v = _lint_source(tmp_path, """
import XCTest
final class SomeTests: XCTestCase {
    func testThing() {
        XCTAssertTrue(true, "LCP not enabled - test skipped")
    }
}
""")
    assert "FLUFF-005" in _codes(v), "an assertion on a literal must be flagged"


def test_fluff005_flags_assert_false_on_literal(tmp_path):
    v = _lint_source(tmp_path, """
import XCTest
final class SomeTests: XCTestCase {
    func testThing() {
        XCTAssertFalse(false)
    }
}
""")
    assert "FLUFF-005" in _codes(v)


def test_fluff006_flags_self_comparison(tmp_path):
    v = _lint_source(tmp_path, """
import XCTest
final class SomeTests: XCTestCase {
    func testThing() {
        let total = compute()
        XCTAssertEqual(total, total)
    }
}
""")
    assert "FLUFF-006" in _codes(v)


def test_fluff005_does_not_flag_a_real_assertion(tmp_path):
    """The clean path must pass — a detector that flags real assertions is worse
    than none. Guards the obvious false positives: a variable named `true`-ish,
    and an assertion whose ARGUMENT is a call returning Bool."""
    v = _lint_source(tmp_path, """
import XCTest
final class SomeTests: XCTestCase {
    func testThing() {
        XCTAssertTrue(cart.isEmpty)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(cart.total, 15.99)
        XCTAssertTrue(audiobook.supportsStreaming())
    }
}
""")
    assert "FLUFF-005" not in _codes(v), "must not flag assertions on real expressions"
    assert "FLUFF-006" not in _codes(v), "must not flag comparisons of distinct operands"


def test_fluff005_skip_is_the_sanctioned_no_op(tmp_path):
    """`XCTSkip` reports as skipped rather than green, so it is the correct way
    to express 'not applicable here' and must not be flagged."""
    v = _lint_source(tmp_path, """
import XCTest
final class SomeTests: XCTestCase {
    func testThing() throws {
        throw XCTSkip("LCP not enabled in this configuration")
    }
}
""")
    assert "FLUFF-005" not in _codes(v)

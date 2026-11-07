#!/usr/bin/env python3
"""
test_check_formatter_in_function.py — self-verify DFF-1
(scripts/check-formatter-in-function.py).

The detector flags `DateFormatter()` / `ISO8601DateFormatter()` built inside a
function, initializer, accessor or computed property in `Palace/`, and allows a
configured-once static, global or stored formatter (PP-5498).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-formatter-in-function.py"


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

FIRING = {
    "method": """
extension NSDate {
    @objc public func rfc3339String() -> String {
        let formatter = DateFormatter()
        return formatter.string(from: self as Date)
    }
}
""",
    "computed_property": """
extension Date {
    var iso8601: String {
        return ISO8601DateFormatter().string(from: self)
    }
}
""",
    "static_computed_property": """
enum Formats {
    static var shared: DateFormatter { DateFormatter() }
}
""",
    "initializer": """
final class Tracker {
    private let formatter: DateFormatter
    init() {
        self.formatter = DateFormatter()
    }
}
""",
    "closure_inside_method": """
struct Feed {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let f = ISO8601DateFormatter()
            return f.date(from: "")!
        }
        return decoder
    }
}
""",
    "getter": """
struct S {
    var value: String {
        get { DateFormatter().string(from: Date()) }
        set { }
    }
}
""",
    "free_function": """
func stamp() -> String {
    if true {
        return ISO8601DateFormatter().string(from: Date())
    }
    return ""
}
""",
    "multiline_signature": """
struct S {
    func format(
        date: Date,
        style: Int = 0
    ) -> String {
        DateFormatter().string(from: date)
    }
}
""",
}


@pytest.mark.parametrize("name", sorted(FIRING))
def test_fires_on_construction_inside_a_function_scope(tmp_path, name):
    _swift(tmp_path, "Palace/Thing.swift", FIRING[name])
    rc, out = _scan(tmp_path)
    assert rc == 1, out
    assert "DFF-1" in out and "Palace/Thing.swift:" in out


def test_reports_the_line_of_the_construction(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift", FIRING["method"])
    rc, out = _scan(tmp_path)
    assert rc == 1
    assert "Palace/Thing.swift:4:" in out


# ───────────────────────────── it stays quiet ───────────────────────────────

QUIET = {
    "static_let_closure": """
extension NSDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    @objc public func rfc3339String() -> String {
        Self.formatter.string(from: self as Date)
    }
}
""",
    "static_let_direct": """
enum Formats {
    static let iso = ISO8601DateFormatter()
}
""",
    "global_let": """
private let bookmarkFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()
""",
    "stored_instance_property": """
final class C {
    private let formatter = DateFormatter()
    lazy var other: DateFormatter = {
        let f = DateFormatter()
        return f
    }()
}
""",
    "in_comment_and_string": """
struct S {
    func f() -> String {
        // DateFormatter() would be rebuilt here
        /* ISO8601DateFormatter() */
        return "DateFormatter()"
    }
}
""",
    "annotated": """
struct S {
    func export() -> String {
        // formatter-in-function-ok: runs once per manual export
        let f = DateFormatter()
        return f.string(from: Date())
    }
}
""",
    "different_type": """
struct S {
    func f() -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(), relativeTo: Date())
    }
}
""",
    "interpolated_string_braces": """
struct S {
    func f(x: Int) -> String { "value \\(x) { not a scope" }
    static let g: DateFormatter = { DateFormatter() }()
}
""",
}


@pytest.mark.parametrize("name", sorted(QUIET))
def test_quiet_on_configured_once_or_non_code(tmp_path, name):
    _swift(tmp_path, "Palace/Thing.swift", QUIET[name])
    rc, out = _scan(tmp_path)
    assert rc == 0, out
    assert "DFF-1" not in out


def test_ignores_test_and_mock_paths(tmp_path):
    _swift(tmp_path, "Palace/Mocks/Thing.swift", FIRING["method"])
    _swift(tmp_path, "Palace/Packages/PalaceX/Tests/XTests/Thing.swift", FIRING["method"])
    rc, out = _scan(tmp_path)
    assert rc == 0, out


# ───────────────────────────── diff mode ────────────────────────────────────

def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, check=True,
                          capture_output=True, text=True).stdout


def _diff_repo(tmp_path: Path, before: str | None, after: str) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    target = repo / "Palace" / "Thing.swift"
    target.parent.mkdir(parents=True)
    if before is not None:
        target.write_text(before)
        _git(repo, "add", "-A")
        _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
    target.write_text(after)
    _git(repo, "add", "-A")
    diff_file = tmp_path / "staged.diff"
    diff_file.write_text(_git(repo, "diff", "--cached"))
    return repo, diff_file


def _run_diff(repo: Path, diff_file: Path) -> tuple[int, str]:
    p = subprocess.run([sys.executable, str(_SCRIPT), "--diff", str(diff_file), "--quiet"],
                       cwd=repo, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def test_diff_mode_flags_an_added_construction(tmp_path):
    repo, diff = _diff_repo(tmp_path, None, FIRING["computed_property"])
    rc, out = _run_diff(repo, diff)
    assert rc == 1, out
    assert "DFF-1" in out


def test_diff_mode_ignores_a_preexisting_construction_on_an_untouched_line(tmp_path):
    before = FIRING["method"]
    after = before + "\n// trailing note\n"
    repo, diff = _diff_repo(tmp_path, before, after)
    rc, out = _run_diff(repo, diff)
    assert rc == 0, out


def test_diff_mode_passes_when_the_fix_moves_it_to_a_static(tmp_path):
    repo, diff = _diff_repo(tmp_path, FIRING["method"], QUIET["static_let_closure"])
    rc, out = _run_diff(repo, diff)
    assert rc == 0, out


def test_dry_run_reports_but_exits_zero(tmp_path):
    _swift(tmp_path, "Palace/Thing.swift", FIRING["method"])
    p = subprocess.run([sys.executable, str(_SCRIPT), "--scan", str(tmp_path), "--dry-run"],
                       capture_output=True, text=True)
    assert p.returncode == 0
    assert "DFF-1" in p.stdout

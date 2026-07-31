"""Tests for check-inert-wiring.sh and check-machine-quiet.sh.

Both scripts exist because of defects that survived review on the 3.2.3 LCP
hotfix, and the wiring detector shipped with a false positive on its very first
run. These pin the candidate-selection rules and the load arithmetic without
needing xcodebuild.
"""
import subprocess
import textwrap
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
WIRING = SCRIPTS / "check-inert-wiring.sh"
QUIET = SCRIPTS / "check-machine-quiet.sh"


def _repo(tmp_path, base_files, head_files):
    """Build a throwaway git repo with a base commit and a HEAD commit."""
    run = lambda *a: subprocess.run(a, cwd=tmp_path, check=True,
                                    capture_output=True, text=True)
    run("git", "init", "-q")
    run("git", "config", "user.email", "t@example.com")
    run("git", "config", "user.name", "t")
    (tmp_path / "Palace").mkdir()
    for name, body in base_files.items():
        (tmp_path / "Palace" / name).write_text(body)
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "base")
    base = run("git", "rev-parse", "HEAD").stdout.strip()
    for name, body in head_files.items():
        (tmp_path / "Palace" / name).write_text(body)
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "head")
    return base


def _list(tmp_path, base):
    return subprocess.run(
        ["bash", str(WIRING), "--list-only", "--base", base],
        cwd=tmp_path, capture_output=True, text=True,
    )


def test_flags_collaborator_wiring(tmp_path):
    base = _repo(tmp_path, {"A.swift": "class A {}\n"},
                 {"A.swift": textwrap.dedent("""\
                     class A {
                       init() {
                         self.coordinator.hasActiveTransfer = { _ in false }
                       }
                     }
                 """)})
    out = _list(tmp_path, base)
    assert "coordinator.hasActiveTransfer" in out.stdout


def test_ignores_constructor_plumbing(tmp_path):
    """`self.foo = foo` is covered by any construction test — not our target."""
    base = _repo(tmp_path, {"A.swift": "class A {}\n"},
                 {"A.swift": textwrap.dedent("""\
                     class A {
                       init(clock: Clock) {
                         self.clock = clock
                         self.timeout = timeout
                       }
                     }
                 """)})
    out = _list(tmp_path, base)
    assert "self.clock" not in out.stdout
    assert "self.timeout" not in out.stdout


def test_clean_diff_passes(tmp_path):
    """A diff with no wiring must exit 0 — a detector that fires on clean input
    gets disabled, which is how gates become decorative."""
    base = _repo(tmp_path, {"A.swift": "class A {}\n"},
                 {"A.swift": "class A { func f() -> Int { 1 } }\n"})
    out = _list(tmp_path, base)
    assert out.returncode == 0
    assert "nothing to check" in out.stdout


def test_requires_tests_argument_to_verify(tmp_path):
    # Assignment on its own line: the detector matches line-initial wiring, which
    # is how post-init composition is always written in practice.
    base = _repo(tmp_path, {"A.swift": "class A {}\n"},
                 {"A.swift": textwrap.dedent("""\
                     class A {
                       init() {
                         self.coordinator.hasActiveTransfer = { _ in false }
                       }
                     }
                 """)})
    out = subprocess.run(["bash", str(WIRING), "--base", base],
                         cwd=tmp_path, capture_output=True, text=True)
    assert out.returncode == 2
    assert "--tests is required" in out.stderr


def test_machine_quiet_reports_ratio():
    out = subprocess.run(["bash", str(QUIET)], capture_output=True, text=True)
    assert out.returncode == 0
    assert "machine-quiet:" in out.stdout


def test_machine_quiet_strict_blocks_when_saturated():
    """--max-ratio 0 makes any load exceed the limit, proving --strict bites."""
    out = subprocess.run(["bash", str(QUIET), "--strict", "--max-ratio", "0"],
                         capture_output=True, text=True)
    assert out.returncode == 1
    assert "refusing to run" in out.stdout

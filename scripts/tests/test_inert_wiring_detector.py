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
    """Build a throwaway git repo with a base commit and a HEAD commit.

    The repo lives in a SUBDIRECTORY so test fixtures (stub binaries) can sit
    beside it without dirtying the worktree — the script refuses to run on a dirty
    tree, and a fixture that trips that guard makes every assertion vacuous.
    """
    repo = tmp_path / "repo"
    repo.mkdir(exist_ok=True)
    run = lambda *a: subprocess.run(a, cwd=repo, check=True,
                                    capture_output=True, text=True)
    run("git", "init", "-q")
    run("git", "config", "user.email", "t@example.com")
    run("git", "config", "user.name", "t")
    (repo / "Palace").mkdir(exist_ok=True)
    for name, body in base_files.items():
        (repo / "Palace" / name).write_text(body)
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "base")
    base = run("git", "rev-parse", "HEAD").stdout.strip()
    for name, body in head_files.items():
        (repo / "Palace" / name).write_text(body)
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "head")
    return base


def _list(tmp_path, base):
    return subprocess.run(
        ["bash", str(WIRING), "--list-only", "--base", base],
        cwd=tmp_path / "repo", capture_output=True, text=True,
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
                         cwd=tmp_path / "repo", capture_output=True, text=True)
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


# --- The classify path -------------------------------------------------------
#
# The six tests above stop at candidate selection. The bug that made this script
# lie — a non-compiling probe scored as SURVIVED — lives in the classify branch,
# which none of them reach. A stub runner exercises it without Xcode.

def _stub_xcodebuild(tmp_path, body):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "fake-xcodebuild"
    stub.write_text("#!/usr/bin/env bash\n" + body + "\n")
    stub.chmod(0o755)
    return stub


def _run_with_stub(tmp_path, base, stub, extra_env=None):
    import os
    env = dict(os.environ, XCODEBUILD=str(stub))
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(WIRING), "--base", base, "--tests", "PalaceTests/Anything"],
        cwd=tmp_path / "repo", capture_output=True, text=True, env=env,
    )


WIRED = textwrap.dedent("""\
    class A {
      init() {
        self.coordinator.hasActiveTransfer = { _ in
          return false
        }
      }
    }
""")


def test_build_failure_is_inconclusive_not_survived(tmp_path):
    """THE regression test. A probe that does not compile ran no tests, so it
    proves nothing — scoring it SURVIVED sends you chasing coverage that already
    exists, and is the exact false positive this script shipped with."""
    base = _repo(tmp_path, {"A.swift": "class A {}\n"}, {"A.swift": WIRED})
    stub = _stub_xcodebuild(tmp_path, "echo '** BUILD FAILED **'; exit 65")
    out = _run_with_stub(tmp_path, base, stub)
    assert "INCONCLUSIVE" in out.stdout, out.stdout
    assert "SURVIVED" not in out.stdout, out.stdout
    assert out.returncode == 1, "an unverified line must not report success"


def test_tests_ran_and_passed_is_survived(tmp_path):
    base = _repo(tmp_path, {"A.swift": "class A {}\n"}, {"A.swift": WIRED})
    stub = _stub_xcodebuild(tmp_path, "echo '** TEST SUCCEEDED **'; exit 0")
    out = _run_with_stub(tmp_path, base, stub)
    assert "SURVIVED" in out.stdout, out.stdout
    assert out.returncode == 1


def test_tests_ran_and_failed_is_killed(tmp_path):
    base = _repo(tmp_path, {"A.swift": "class A {}\n"}, {"A.swift": WIRED})
    stub = _stub_xcodebuild(
        tmp_path,
        "echo 'error: -[FooTests testBar] : XCTAssertTrue failed'; "
        "echo '** TEST FAILED **'; exit 65",
    )
    out = _run_with_stub(tmp_path, base, stub)
    assert "KILLED" in out.stdout, out.stdout
    assert out.returncode == 0


def test_probe_removes_the_whole_closure_and_leaves_the_class_intact(tmp_path):
    """Indent-guessing once deleted 395 lines — to the end of the class — when the
    candidate lost its leading whitespace. Brace matching must remove exactly the
    assignment, and nothing that follows it."""
    tail = "func keepMe() -> Int { 42 }\n"
    base = _repo(tmp_path, {"A.swift": "class A {}\n"},
                 {"A.swift": WIRED + tail})
    stub = _stub_xcodebuild(
        tmp_path,
        "grep -q keepMe Palace/A.swift && echo '** TEST SUCCEEDED **' && exit 0; "
        "echo '** BUILD FAILED **'; exit 65",
    )
    out = _run_with_stub(tmp_path, base, stub)
    assert "INCONCLUSIVE" not in out.stdout, \
        "the probe deleted past the closure — everything after it was lost"
    assert (tmp_path / "repo" / "Palace" / "A.swift").read_text().count("keepMe") == 1, \
        "the probe must restore the file exactly"


def test_probe_matches_braces_rather_than_guessing_from_indent(tmp_path):
    """Kills the indent-guessing regression specifically.

    Discriminating on purpose. An earlier version of this test put the closure's
    closing brace at the same indent as the assignment, so both strategies agreed;
    and its oracle was a `grep` in the stub, which cannot see a syntax error at all.
    Both made it pass against the bug.

    Here the brace sits at a DIFFERENT indent. Brace matching removes the whole
    closure, body included. Indent guessing finds no same-indent `}`, falls back to
    deleting only the assignment line, and leaves the body orphaned — a syntax
    error that the real xcodebuild would reject and a grep-based stub would not.
    So the assertion is on what the probe actually WROTE.
    """
    src = textwrap.dedent("""\
        class A {
          init() {
            self.coordinator.hasActiveTransfer = { _ in
                return false
              }
            self.mustSurvive = 1
          }
        }
    """)
    base = _repo(tmp_path, {"A.swift": "class A {}\n"}, {"A.swift": src})
    captured = tmp_path / "probed.swift"
    stub = _stub_xcodebuild(
        tmp_path,
        f"cp Palace/A.swift {captured}; echo '** TEST SUCCEEDED **'; exit 0",
    )
    _run_with_stub(tmp_path, base, stub)

    probed = captured.read_text()
    assert "mustSurvive" in probed, \
        "the probe deleted past the closure and destroyed the following statement"
    assert "return false" not in probed, \
        "the probe left the closure BODY behind — orphaned, and a syntax error"

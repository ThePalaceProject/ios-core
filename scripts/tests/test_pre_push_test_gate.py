"""Tests for scripts/pre-push-test-gate.sh: the file-size ceiling step, and
(further down) test-class selection and the executed-count check.

prior-art-checked: nothing under scripts/tests exercised pre-push-test-gate.sh;
this follows the existing scripts/tests pytest convention.

The hook is run for real against a throwaway repo with a bare origin, with
`check-file-size-ceiling.sh` copied next to it. The ceiling fixtures have no
PalaceTests/, so after the ceiling step the hook derives no test classes and
never reaches xcodebuild. Each fixture injects its own allowlist through
FILE_SIZE_ALLOWLIST_FILE, the ceiling script's own seam.
"""
import os
import shutil
import subprocess
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
HOOK = SCRIPTS / "pre-push-test-gate.sh"
CEILING = SCRIPTS / "check-file-size-ceiling.sh"

ALLOWLISTED = "Palace/Hub.swift"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout


def _swift(lines: int) -> str:
    return "".join(f"let v{i} = {i}\n" for i in range(lines))


def _repo(tmp_path: Path, hub_cap: int, hub_lines: int) -> Path:
    """A repo pushed to its origin, with an allowlisted file at `hub_lines`."""
    origin = tmp_path / "origin.git"
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    _git(repo, "config", "commit.gpgsign", "false")
    (repo / "scripts").mkdir()
    shutil.copy(HOOK, repo / "scripts" / HOOK.name)
    shutil.copy(CEILING, repo / "scripts" / CEILING.name)
    (repo / "Palace").mkdir()
    (repo / ALLOWLISTED).write_text(_swift(hub_lines))
    (repo / "Palace" / "Small.swift").write_text(_swift(3))
    (repo / "README.md").write_text("readme\n")
    (tmp_path / "allowlist").write_text(f"{hub_cap} {ALLOWLISTED}\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    _git(repo, "remote", "add", "origin", str(origin))
    _git(repo, "push", "-q", "-u", "origin", "main")
    return repo


def _commit(repo: Path, rel: str, content: str) -> None:
    (repo / rel).write_text(content)
    _git(repo, "add", rel)
    _git(repo, "commit", "-q", "-m", f"change {rel}")


def _run_hook(repo: Path, tmp_path: Path) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.pop("SKIP_PRE_PUSH_TESTS", None)
    env["FILE_SIZE_ALLOWLIST_FILE"] = str(tmp_path / "allowlist")
    head = _git(repo, "rev-parse", "HEAD").strip()
    refs = f"refs/heads/main {head} refs/heads/main {'0' * 40}\n"
    return subprocess.run(
        ["bash", "scripts/pre-push-test-gate.sh", "origin", str(tmp_path / "origin.git")],
        cwd=repo, env=env, input=refs, capture_output=True, text=True, timeout=120,
    )


def test_push_growing_an_allowlisted_file_past_its_cap_is_blocked(tmp_path):
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    _commit(repo, ALLOWLISTED, _swift(6))

    result = _run_hook(repo, tmp_path)

    assert result.returncode != 0, result.stderr
    assert "OVER-ALLOWLIST" in result.stderr
    assert "file-size ceiling" in result.stderr and "push blocked" in result.stderr


def test_clean_swift_push_runs_the_ceiling_and_passes(tmp_path):
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    _commit(repo, "Palace/Small.swift", _swift(4))

    result = _run_hook(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "[file-size] OK" in result.stderr


def test_non_swift_push_skips_the_ceiling(tmp_path):
    # The tree is already over the cap, so the push would be blocked if the
    # ceiling ran at all. Exit 0 here means the step was skipped.
    repo = _repo(tmp_path, hub_cap=4, hub_lines=5)
    _commit(repo, "README.md", "readme, edited\n")

    result = _run_hook(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "[file-size]" not in result.stderr


# --- Test selection and the executed-count check ------------------------------
#
# These fixtures add PalaceTests/ and a project file, so the hook reaches
# xcodebuild. A stub xcodebuild on PATH records its arguments and replays a log
# from fixtures/pre_push_test_gate/ (shaped after real xcodebuild output); a
# stub xcrun reports no booted simulator.

GATE_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "pre_push_test_gate"
SOURCES_CHECK = SCRIPTS / "check-swift-sources-compiled.py"

# Two targets. PalaceTests compiles WidgetTests and WidgetExtraTests;
# WidgetOrphanTests has a file reference and no build file; WidgetAppSideTests
# is compiled, but by the app target, not by PalaceTests.
PBXPROJ = """// !$*UTF8*$!
{
\tarchiveVersion = 1;
\tobjectVersion = 56;
\tobjects = {
\t\tG0 = {isa = PBXGroup; children = (G1, G2); sourceTree = "<group>";};
\t\tG1 = {isa = PBXGroup; children = (F1); path = Palace; sourceTree = "<group>";};
\t\tG2 = {isa = PBXGroup; children = (F2, F3, F4, F5); path = PalaceTests; sourceTree = "<group>";};
\t\tF1 = {isa = PBXFileReference; path = Widget.swift; sourceTree = "<group>";};
\t\tF2 = {isa = PBXFileReference; path = WidgetTests.swift; sourceTree = "<group>";};
\t\tF3 = {isa = PBXFileReference; path = WidgetExtraTests.swift; sourceTree = "<group>";};
\t\tF4 = {isa = PBXFileReference; path = WidgetOrphanTests.swift; sourceTree = "<group>";};
\t\tF5 = {isa = PBXFileReference; path = WidgetAppSideTests.swift; sourceTree = "<group>";};
\t\tB1 = {isa = PBXBuildFile; fileRef = F1;};
\t\tB2 = {isa = PBXBuildFile; fileRef = F2;};
\t\tB3 = {isa = PBXBuildFile; fileRef = F3;};
\t\tB5 = {isa = PBXBuildFile; fileRef = F5;};
\t\tS1 = {isa = PBXSourcesBuildPhase; files = (B1, B5);};
\t\tS2 = {isa = PBXSourcesBuildPhase; files = (B2, B3);};
\t\tT1 = {isa = PBXNativeTarget; name = Palace; buildPhases = (S1);};
\t\tT2 = {isa = PBXNativeTarget; name = PalaceTests; buildPhases = (S2);};
\t\tP0 = {isa = PBXProject; mainGroup = G0; targets = (T1, T2);};
\t};
\trootObject = P0;
}
"""

ALL_TEST_CLASSES = ("WidgetTests", "WidgetExtraTests", "WidgetOrphanTests", "WidgetAppSideTests")


def _gate_repo(tmp_path: Path, test_classes=ALL_TEST_CLASSES) -> Path:
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    shutil.copy(SOURCES_CHECK, repo / "scripts" / SOURCES_CHECK.name)
    (repo / "Palace" / "Widget.swift").write_text("struct Widget {}\n")
    (repo / "PalaceTests").mkdir()
    for cls in test_classes:
        (repo / "PalaceTests" / f"{cls}.swift").write_text(
            f"import XCTest\n\nfinal class {cls}: XCTestCase {{\n"
            f"    func testWidget() {{}}\n}}\n")
    (repo / "Palace.xcodeproj").mkdir()
    (repo / "Palace.xcodeproj" / "project.pbxproj").write_text(PBXPROJ)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "widget")
    _git(repo, "push", "-q", "origin", "main")
    _commit(repo, "Palace/Widget.swift", "struct Widget { let id = 1 }\n")
    return repo


def _run_gate(repo: Path, tmp_path: Path, log: str, rc: int = 0) -> subprocess.CompletedProcess:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "xcodebuild"
    stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$FAKE_XCODEBUILD_ARGS"\n'
                    'cat "$FAKE_XCODEBUILD_OUTPUT"\nexit "$FAKE_XCODEBUILD_RC"\n')
    xcrun = bin_dir / "xcrun"
    xcrun.write_text("#!/bin/bash\nexit 0\n")
    stub.chmod(0o755)
    xcrun.chmod(0o755)

    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.pop("SKIP_PRE_PUSH_TESTS", None)
    env.update({
        "PATH": f"{bin_dir}:{env['PATH']}",
        "FILE_SIZE_ALLOWLIST_FILE": str(tmp_path / "allowlist"),
        "PRE_PUSH_TESTS_LOG": str(tmp_path / "gate.log"),
        "FAKE_XCODEBUILD_ARGS": str(tmp_path / "xcodebuild-args"),
        "FAKE_XCODEBUILD_OUTPUT": str(GATE_FIXTURES / log),
        "FAKE_XCODEBUILD_RC": str(rc),
    })
    head = _git(repo, "rev-parse", "HEAD").strip()
    refs = f"refs/heads/main {head} refs/heads/main {'0' * 40}\n"
    return subprocess.run(
        ["bash", "scripts/pre-push-test-gate.sh", "origin", str(tmp_path / "origin.git")],
        cwd=repo, env=env, input=refs, capture_output=True, text=True, timeout=120,
    )


def _selected(tmp_path: Path) -> list[str]:
    args = (tmp_path / "xcodebuild-args").read_text().split("\n")
    return sorted(a.split("/", 1)[1] for a in args if a.startswith("-only-testing:"))


def test_test_files_not_compiled_by_palacetests_are_not_selected(tmp_path):
    """A class in no PalaceTests Sources phase runs zero tests, so selecting it
    would make the gate pass on tests that never ran."""
    repo = _gate_repo(tmp_path)

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetExtraTests", "WidgetTests"]
    assert "skipping PalaceTests/WidgetOrphanTests.swift" in result.stderr
    assert "skipping PalaceTests/WidgetAppSideTests.swift" in result.stderr


def test_zero_executed_tests_on_exit_zero_blocks_the_push(tmp_path):
    """xcodebuild exits 0 when a selector matches nothing; that is not a pass."""
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "selector-matched-nothing.log")

    assert result.returncode == 1, result.stderr
    failure = result.stderr.split("executed 0 tests:", 1)[1]
    assert "  - WidgetTests" in failure
    assert "0 test(s) executed in total" in result.stderr


def test_one_class_with_zero_executed_among_green_ones_blocks_the_push(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests", "WidgetExtraTests"))

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 1, result.stderr
    failure = result.stderr.split("executed 0 tests:", 1)[1]
    assert "1 selected class(es) executed 0 tests" in result.stderr
    assert "  - WidgetExtraTests" in failure
    assert "  - WidgetTests" not in failure


def test_normal_run_passes_and_reports_the_executed_count(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests", "WidgetExtraTests"))

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert result.returncode == 0, result.stderr
    assert "PASS — 2 class(es) green, 5 test(s) executed." in result.stderr
    assert "-quiet" not in _selected_args(tmp_path)


def test_timeout_is_still_allowed_without_an_executed_count(tmp_path):
    """A run killed at the wall-clock cap has no "Executed" lines yet; it stays a
    non-blocking timeout rather than a 0-executed failure."""
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "timed-out.log", rc=124)

    assert result.returncode == 0, result.stderr
    assert "TIMEOUT after" in result.stderr
    assert "executed 0 tests" not in result.stderr


def _selected_args(tmp_path: Path) -> list[str]:
    return (tmp_path / "xcodebuild-args").read_text().split("\n")

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


def _gate_repo(tmp_path: Path, test_classes=ALL_TEST_CLASSES, files=None) -> Path:
    """`files` maps PalaceTests-relative paths to contents, replacing or adding
    to the one-XCTestCase-per-file defaults."""
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    shutil.copy(SOURCES_CHECK, repo / "scripts" / SOURCES_CHECK.name)
    (repo / "Palace" / "Widget.swift").write_text("struct Widget {}\n")
    (repo / "PalaceTests").mkdir()
    for cls in test_classes:
        (repo / "PalaceTests" / f"{cls}.swift").write_text(
            f"import XCTest\n\nfinal class {cls}: XCTestCase {{\n"
            f"    func testWidget() {{}}\n}}\n")
    for rel, content in (files or {}).items():
        (repo / "PalaceTests" / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / "PalaceTests" / rel).write_text(content)
    (repo / "Palace.xcodeproj").mkdir()
    (repo / "Palace.xcodeproj" / "project.pbxproj").write_text(PBXPROJ)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "widget")
    _git(repo, "push", "-q", "origin", "main")
    _commit(repo, "Palace/Widget.swift", "struct Widget { let id = 1 }\n")
    return repo


def _run_gate(repo: Path, tmp_path: Path, log: str, rc: int = 0,
              extra_env=None) -> subprocess.CompletedProcess:
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
    env.pop("PRE_PUSH_TESTS_ALLOW_TIMEOUT", None)
    env.update(extra_env or {})
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


# --- Classes that inherit XCTestCase through a project base class -------------

BASES = {
    "Support/PalaceTestCase.swift":
        "import XCTest\n\n@MainActor\nclass PalaceTestCase: XCTestCase {\n"
        "    override func setUp() { super.setUp() }\n}\n",
    "Support/PalaceWiringTestCase.swift":
        "import XCTest\n\n@MainActor\nclass PalaceWiringTestCase: PalaceTestCase {\n"
        "    func installWiring() {}\n}\n",
}


def test_classes_inheriting_xctestcase_through_project_bases_are_selected(tmp_path):
    """AppContainerResetTests subclasses PalaceTestCase; a change to AppContainer
    must select it, including through a second level of base class."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        **BASES,
        "WidgetTests.swift":
            "import XCTest\n\n@MainActor final class WidgetTests: PalaceTestCase {\n"
            "    func testWidget() {}\n}\n",
        "WidgetExtraTests.swift":
            "import XCTest\n\nfinal class WidgetExtraTests: PalaceWiringTestCase {\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetExtraTests", "WidgetTests"]


def test_a_base_class_without_test_methods_is_not_selected(tmp_path):
    """A fixture base declares no tests, so selecting it would fail the
    zero-executed check; the subclass after it in the same file is the test."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        "WidgetTests.swift":
            "import XCTest\n\nclass WidgetFixture: XCTestCase {\n"
            "    final class Spy: NSObject {}\n"
            "    func makeWidget() {}\n}\n\n"
            "final class WidgetTests: WidgetFixture {\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetTests"]


def test_a_class_declared_inside_a_string_literal_is_not_selected(tmp_path):
    """Lint tests embed synthetic test classes in indented string literals."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        **BASES,
        "WidgetTests.swift":
            "import XCTest\n\nfinal class WidgetTests: PalaceTestCase {\n"
            "    let source = \"\"\"\n"
            "        final class SyntheticTests: XCTestCase {\n"
            "            func testNothing() {}\n"
            "        }\n"
            "        \"\"\"\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetTests"]


def test_an_extension_of_xctestcase_is_not_selected(tmp_path):
    """`extension XCTestCase` holds shared helpers; selecting it would run
    PalaceTests/XCTestCase, execute 0 tests and block the push."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        "WidgetTests.swift":
            "import XCTest\n\nextension XCTestCase {\n"
            "    func testableWidget() {}\n"
            "    func test_helper() {}\n}\n\n"
            "final class WidgetTests: XCTestCase {\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetTests"]


def test_every_test_class_in_a_matched_file_is_selected(tmp_path):
    """MyBooksViewModelTests.swift declares many XCTestCase classes; a change to
    MyBooksViewModel must run all of them, not only the first one in the file."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        "WidgetTests.swift":
            "import XCTest\n\nextension XCTestCase {\n"
            "    func test_helper() {}\n}\n\n"
            "final class WidgetTests: XCTestCase {\n"
            "    func testWidget() {}\n}\n\n"
            "final class WidgetSpy: NSObject {\n"
            "    func testSpyLooksLikeATest() {}\n}\n\n"
            "final class WidgetFacetTests: XCTestCase {\n"
            "    func testFacet() {}\n"
            "    func testFacetAgain() {}\n}\n\n"
            "class WidgetFixture: XCTestCase {\n"
            "    func makeWidget() {}\n}\n\n"
            "extension WidgetTests {\n"
            "    func testFromAnExtension() {}\n}\n\n"
            "final class WidgetHostTests: XCTestCase {}\n\n"
            "extension WidgetHostTests {\n"
            "    func testOnlyInAnExtension() {}\n}\n\n"
            "@MainActor final class WidgetSortTests: XCTestCase {\n"
            "    func testSort() {}\n}\n",
    })

    _run_gate(repo, tmp_path, "one-class-passed.log")

    assert _selected(tmp_path) == ["WidgetFacetTests", "WidgetHostTests", "WidgetSortTests", "WidgetTests"]


def test_a_test_named_helper_is_not_a_test_method(tmp_path):
    """`func testableX` is a helper, not an XCTest method, so a base that only
    declares one is not selected."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        "WidgetTests.swift":
            "import XCTest\n\nclass WidgetFixture: XCTestCase {\n"
            "    func testableWidget() {}\n}\n\n"
            "final class WidgetTests: WidgetFixture {\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetTests"]


def test_an_attributed_top_level_type_ends_the_preceding_class(tmp_path):
    """A test-named method in `@MainActor struct` after a test-less class must
    not be credited to that class."""
    repo = _gate_repo(tmp_path, test_classes=(), files={
        "WidgetTests.swift":
            "import XCTest\n\nclass WidgetFixture: XCTestCase {\n"
            "    func makeWidget() {}\n}\n\n"
            "@MainActor struct WidgetProbe {\n"
            "    func testProbe() {}\n}\n\n"
            "@available(iOS 17, *)\nfinal class WidgetTests: WidgetFixture {\n"
            "    func testWidget() {}\n}\n",
    })

    result = _run_gate(repo, tmp_path, "one-class-passed.log")

    assert result.returncode == 0, result.stderr
    assert _selected(tmp_path) == ["WidgetTests"]


# --- Runs killed at the wall-clock cap ----------------------------------------


def test_timeout_before_any_selected_class_ran_blocks_the_push(tmp_path):
    """A run killed during the build verified nothing, so it is not a pass."""
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "timed-out.log", rc=124)

    assert result.returncode == 1, result.stderr
    assert "TIMEOUT after" in result.stderr
    assert "  - WidgetTests" in result.stderr.split("did not finish before the cap:", 1)[1]
    assert "PRE_PUSH_TESTS_ALLOW_TIMEOUT=1" in result.stderr
    assert "PRE_PUSH_TESTS_TIMEOUT_SECS" in result.stderr


def test_timeout_after_some_classes_ran_names_only_the_missing_ones(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests", "WidgetExtraTests"))

    result = _run_gate(repo, tmp_path, "timed-out-after-one-class.log", rc=142)

    assert result.returncode == 1, result.stderr
    missing = result.stderr.split("did not finish before the cap:", 1)[1]
    assert "  - WidgetExtraTests" in missing
    assert "  - WidgetTests" not in missing


def test_timeout_after_every_selected_class_ran_allows_the_push(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "timed-out-after-one-class.log", rc=124)

    assert result.returncode == 0, result.stderr
    assert "every selected class ran (3 test(s))" in result.stderr


def test_timeout_after_a_test_failure_blocks_even_with_the_override(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "timed-out-after-failure.log", rc=124,
                       extra_env={"PRE_PUSH_TESTS_ALLOW_TIMEOUT": "1"})

    assert result.returncode == 1, result.stderr
    assert "-[PalaceTests.WidgetTests testB]" in result.stderr


def test_allow_timeout_override_allows_a_run_killed_during_the_build(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "timed-out.log", rc=124,
                       extra_env={"PRE_PUSH_TESTS_ALLOW_TIMEOUT": "1"})

    assert result.returncode == 0, result.stderr
    assert "PRE_PUSH_TESTS_ALLOW_TIMEOUT=1" in result.stderr
    assert "  - WidgetTests" in result.stderr.split("did not finish before the cap:", 1)[1]


def test_build_interrupted_without_a_timeout_exit_code_is_treated_as_a_timeout(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "build-interrupted.log", rc=65)

    assert result.returncode == 1, result.stderr
    assert "TIMEOUT after" in result.stderr
    assert "did not finish before the cap:" in result.stderr


def _selected_args(tmp_path: Path) -> list[str]:
    return (tmp_path / "xcodebuild-args").read_text().split("\n")


# --- The changed-file set after a rebase --------------------------------------

def _rebased_branch_repo(tmp_path: Path) -> Path:
    """A `feature` branch that changed Widget.swift and was pushed, then rebased
    onto a new main commit that changed Gadget.swift (another branch's work).
    Its upstream still points at the pre-rebase tip."""
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests", "WidgetExtraTests", "GadgetTests"))
    _git(repo, "reset", "-q", "--hard", "origin/main")
    pbxproj = (PBXPROJ
               .replace("children = (F2, F3, F4, F5)", "children = (F2, F3, F4, F5, F6)")
               .replace("\t\tB1 = {", "\t\tF6 = {isa = PBXFileReference; path = GadgetTests.swift; "
                        "sourceTree = \"<group>\";};\n\t\tB6 = {isa = PBXBuildFile; fileRef = F6;};\n\t\tB1 = {")
               .replace("files = (B2, B3);", "files = (B2, B3, B6);"))
    (repo / "Palace.xcodeproj" / "project.pbxproj").write_text(pbxproj)
    (repo / "Palace" / "Gadget.swift").write_text("struct Gadget {}\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "gadget")
    _git(repo, "push", "-q", "origin", "main")

    _git(repo, "checkout", "-q", "-b", "feature")
    _commit(repo, "Palace/Widget.swift", "struct Widget { let id = 1 }\n")
    _git(repo, "push", "-q", "-u", "origin", "feature")

    _git(repo, "checkout", "-q", "main")
    _commit(repo, "Palace/Gadget.swift", "struct Gadget { let id = 2 }\n")
    _git(repo, "push", "-q", "origin", "main")

    _git(repo, "checkout", "-q", "feature")
    _git(repo, "rebase", "-q", "main")
    return repo


def test_after_a_rebase_the_branch_s_own_files_are_selected_not_the_rebased_onto_ones(tmp_path):
    """`@{u}..HEAD` after a rebase holds only the commits rebased onto: the
    branch's own change is on both sides and cancels out."""
    repo = _rebased_branch_repo(tmp_path)
    assert _git(repo, "rev-parse", "@{u}") != _git(repo, "rev-parse", "HEAD"), \
        "precondition: the upstream is the pre-rebase tip"

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert (tmp_path / "xcodebuild-args").exists(), result.stderr
    assert _selected(tmp_path) == ["WidgetExtraTests", "WidgetTests"]


def test_a_branch_with_no_commits_ahead_of_its_base_runs_no_ios_tests(tmp_path):
    repo = _gate_repo(tmp_path)
    _git(repo, "reset", "-q", "--hard", "origin/main")
    _git(repo, "checkout", "-q", "-b", "empty")
    _git(repo, "push", "-q", "-u", "origin", "empty")

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "xcodebuild-args").exists()


# --- Where a linked worktree's DerivedData goes ---------------------------------
#
# A linked worktree gets its own DerivedData (a shared one carries another
# checkout's SPM paths). It used to live in $TMPDIR/prepush-dd-<hash>, which
# nothing deleted when the worktree was removed: 46 of them held 221 GB. Inside
# the worktree, removing the worktree removes the build with it.

def _arg_after(tmp_path: Path, flag: str):
    args = _selected_args(tmp_path)
    return args[args.index(flag) + 1] if flag in args else None


def test_a_linked_worktree_builds_inside_the_worktree(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))
    wt = tmp_path / "linked"
    _git(repo, "worktree", "add", "-q", "-b", "linked", str(wt))
    tmpdir = tmp_path / "user-tmp"
    tmpdir.mkdir()

    result = _run_gate(wt, tmp_path, "two-classes-passed.log",
                       extra_env={"TMPDIR": f"{tmpdir}/"})

    real_wt = wt.resolve()
    assert _arg_after(tmp_path, "-derivedDataPath") == f"{real_wt}/.dd-prepush", result.stderr
    assert (_arg_after(tmp_path, "-clonedSourcePackagesDirPath")
            == f"{real_wt}/.dd-prepush/SourcePackages")
    assert str(tmpdir) not in "\n".join(_selected_args(tmp_path))


def test_the_main_checkout_keeps_the_default_derived_data(tmp_path):
    repo = _gate_repo(tmp_path, test_classes=("WidgetTests",))

    result = _run_gate(repo, tmp_path, "two-classes-passed.log")

    assert result.returncode == 0, result.stderr
    assert "-derivedDataPath" not in _selected_args(tmp_path)


def test_the_worktree_derived_data_folder_is_gitignored():
    """Otherwise `git add -A` stages gigabytes and `git worktree remove` refuses
    the worktree as unclean."""
    root = SCRIPTS.parent
    # A neutral name inside the folder, and no global excludes file, so only the
    # repo's own rules can match.
    probe = subprocess.run(["git", "-c", "core.excludesFile=/dev/null",
                            "check-ignore", "-q", ".dd-prepush/probe"],
                           cwd=root, capture_output=True)
    assert probe.returncode == 0

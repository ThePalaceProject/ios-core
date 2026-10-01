"""scripts/tsan-lane.py and its wiring in .github/workflows/tsan.yml.

The ThreadSanitizer job can pass without checking anything in three ways, and
each has a test here:

  * TSan reports a race and lets the test continue, so xcodebuild exits 0.
    `check-log` must fail on a log holding a report, and pass a clean one.
  * -only-testing ignores a name that matches nothing, so a renamed suite
    drops out of the run. `suites` must reject a manifest entry that resolves
    to nothing, and `check-ran` must fail when a selected suite is absent from
    the result bundle.
  * The workflow could stop calling any of the above. The wiring tests parse
    the workflow as YAML and assert each check is invoked.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "tsan-lane.py"
_WORKFLOW = _REPO / ".github" / "workflows" / "tsan.yml"

# Abridged from a real report: a data race in a unit test, printed to the test
# host's stderr between two passing test cases.
_RACE_LOG = """\
Test Case '-[PalaceTests.FooConcurrencyTests testA]' started.
==================
WARNING: ThreadSanitizer: data race (pid=4242)
  Write of size 8 at 0x7b0c00012345 by thread T3:
    #0 closure #1 in FooConcurrencyTests.testA() FooConcurrencyTests.swift:31 (PalaceTests:arm64+0x1234)

  Previous write of size 8 at 0x7b0c00012345 by thread T2:
    #0 closure #1 in FooConcurrencyTests.testA() FooConcurrencyTests.swift:31 (PalaceTests:arm64+0x1234)

SUMMARY: ThreadSanitizer: data race FooConcurrencyTests.swift:31 in closure #1 in FooConcurrencyTests.testA()
==================
Test Case '-[PalaceTests.FooConcurrencyTests testA]' passed (0.412 seconds).
** TEST SUCCEEDED **
"""

_CLEAN_LOG = """\
Test Suite 'FooConcurrencyTests' started at 2026-09-30 10:00:00.000.
Test Case '-[PalaceTests.FooConcurrencyTests testA]' started.
Test Case '-[PalaceTests.FooConcurrencyTests testA]' passed (0.412 seconds).
Test Suite 'FooConcurrencyTests' passed at 2026-09-30 10:00:00.500.
\t Executed 1 test, with 0 failures (0 unexpected) in 0.412 (0.500) seconds
** TEST SUCCEEDED **
"""


def _run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(_SCRIPT), *args], capture_output=True, text=True, cwd=cwd)


# --- check-log -------------------------------------------------------------


def test_checkLog_withDataRaceReport_failsAndNamesTheLocation(tmp_path):
    log = tmp_path / "tsan.log"
    log.write_text(_RACE_LOG)
    p = _run("check-log", str(log))
    assert p.returncode == 1
    assert "FooConcurrencyTests.swift:31" in p.stdout
    assert "1 issue(s)" in p.stdout


def test_checkLog_withCleanLog_passes(tmp_path):
    log = tmp_path / "tsan.log"
    log.write_text(_CLEAN_LOG)
    p = _run("check-log", str(log))
    assert p.returncode == 0, p.stdout + p.stderr


def test_checkLog_countsEachReport(tmp_path):
    log = tmp_path / "tsan.log"
    log.write_text(_RACE_LOG + _RACE_LOG.replace(":31", ":57"))
    p = _run("check-log", str(log))
    assert p.returncode == 1
    assert "2 issue(s)" in p.stdout


def test_checkLog_colouredReport_countsSummariesNotEveryLine(tmp_path):
    # With TSAN_OPTIONS color=always (or unset on a TTY) each line carries ANSI
    # escapes, so SUMMARY is not at the start of the raw line.
    log = tmp_path / "tsan.log"
    log.write_text(_RACE_LOG.replace("WARNING:", "\x1b[1m\x1b[31mWARNING:").replace("SUMMARY:", "\x1b[1m\x1b[0mSUMMARY:"))
    p = _run("check-log", str(log))
    assert p.returncode == 1
    assert "1 issue(s)" in p.stdout
    assert "  SUMMARY: ThreadSanitizer: data race" in p.stdout


def test_checkLog_reportCutOffBeforeSummary_stillFails(tmp_path):
    log = tmp_path / "tsan.log"
    log.write_text(_RACE_LOG.split("SUMMARY:")[0])
    p = _run("check-log", str(log))
    assert p.returncode == 1
    assert "WARNING: ThreadSanitizer: data race" in p.stdout


def test_checkLog_sanitizerRuntimeError_fails(tmp_path):
    log = tmp_path / "tsan.log"
    log.write_text(_CLEAN_LOG + "ThreadSanitizer: failed to allocate 0x1000 bytes\n")
    assert _run("check-log", str(log)).returncode == 1


@pytest.mark.parametrize("content", [None, ""])
def test_checkLog_missingOrEmptyLog_isNotClean(tmp_path, content):
    log = tmp_path / "tsan.log"
    if content is not None:
        log.write_text(content)
    p = _run("check-log", str(log))
    assert p.returncode == 2
    assert "nothing was checked" in p.stderr


# --- suites ----------------------------------------------------------------


def _tree(tmp_path: Path, files: dict[str, str], manifest: str) -> Path:
    for rel, body in files.items():
        f = tmp_path / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(body)
    (tmp_path / "manifest.txt").write_text(manifest)
    return tmp_path


def _suites(root: Path) -> subprocess.CompletedProcess:
    return _run("suites", "--manifest", str(root / "manifest.txt"), "--root", str(root))


def test_suites_globSelectsOnlyTestCaseSubclasses(tmp_path):
    root = _tree(
        tmp_path,
        {
            "PalaceTests/A/FooConcurrencyTests.swift": (
                "final class FooConcurrencyTests: XCTestCase {}\n"
                "private final class SpyDelegate: FooDelegate {}\n"
            ),
            "PalaceTests/B/BarRaceTests.swift": "@MainActor final class BarRaceTests: PalaceWiringTestCase {}\n",
            "PalaceTests/B/Unrelated.swift": "final class UnrelatedTests: XCTestCase {}\n",
        },
        "glob: PalaceTests/**/*Concurrency*Tests.swift\nglob: PalaceTests/**/*Race*Tests.swift\n",
    )
    p = _suites(root)
    assert p.returncode == 0, p.stderr
    assert p.stdout.split() == ["BarRaceTests", "FooConcurrencyTests"]


def test_suites_explicitClassIsIncluded(tmp_path):
    root = _tree(
        tmp_path,
        {"PalaceTests/Hang.swift": "final class HangTests: PalaceTestCase {}\n"},
        "# comment\nclass: HangTests\n",
    )
    p = _suites(root)
    assert p.returncode == 0, p.stderr
    assert p.stdout.split() == ["HangTests"]


def test_suites_globMatchingNothing_isAnError(tmp_path):
    root = _tree(
        tmp_path,
        {"PalaceTests/FooConcurrencyTests.swift": "final class FooConcurrencyTests: XCTestCase {}\n"},
        "glob: PalaceTests/**/*Concurrency*Tests.swift\nglob: PalaceTests/**/*Renamed*Tests.swift\n",
    )
    p = _suites(root)
    assert p.returncode == 2
    assert "*Renamed*Tests.swift" in p.stderr


def test_suites_undeclaredClass_isAnError(tmp_path):
    root = _tree(
        tmp_path,
        {"PalaceTests/FooTests.swift": "final class FooTests: XCTestCase {}\n"},
        "class: GoneTests\n",
    )
    p = _suites(root)
    assert p.returncode == 2
    assert "GoneTests" in p.stderr


def test_suites_malformedLine_isAnError(tmp_path):
    root = _tree(tmp_path, {}, "PalaceTests/**/*Tests.swift\n")
    assert _suites(root).returncode == 2


def test_suites_emptyManifest_isAnError(tmp_path):
    root = _tree(tmp_path, {}, "# nothing\n")
    p = _suites(root)
    assert p.returncode == 2
    assert "selects no test classes" in p.stderr


def test_suites_realManifestResolvesOnThisTree():
    p = _run("suites", cwd=_REPO)
    assert p.returncode == 0, p.stderr
    classes = p.stdout.split()
    for name in (
        "AccountRegistryStorePoolStarvationTests",
        "AudiobookOpenStateRaceTests",
        "TPPBookRegistryStateConcurrencyTests",
    ):
        assert name in classes


# --- check-ran -------------------------------------------------------------


def _results(tmp_path: Path, suites: list[str]) -> Path:
    doc = {
        "testNodes": [
            {
                "nodeType": "Test Plan",
                "name": "Palace",
                "children": [
                    {
                        "nodeType": "Unit test bundle",
                        "name": "PalaceTests",
                        "children": [{"nodeType": "Test Suite", "name": s, "children": []} for s in suites],
                    }
                ],
            }
        ]
    }
    f = tmp_path / "tests.json"
    f.write_text(json.dumps(doc))
    return f


def test_checkRan_allSuitesPresent_passes(tmp_path):
    f = _results(tmp_path, ["FooTests", "BarTests"])
    assert _run("check-ran", str(f), "FooTests", "BarTests").returncode == 0


def test_checkRan_missingSuite_failsAndNamesIt(tmp_path):
    f = _results(tmp_path, ["FooTests"])
    p = _run("check-ran", str(f), "FooTests", "BarTests")
    assert p.returncode == 1
    assert "BarTests" in p.stderr


# --- workflow wiring -------------------------------------------------------


def _workflow() -> dict:
    yaml = pytest.importorskip("yaml")
    return yaml.safe_load(_WORKFLOW.read_text())


def _tsan_step() -> dict:
    steps = _workflow()["jobs"]["tsan"]["steps"]
    matches = [s for s in steps if s.get("id") == "tsan"]
    assert len(matches) == 1, "tsan.yml must have exactly one step with id 'tsan'"
    return matches[0]


def test_workflow_runsOnPullRequests():
    doc = _workflow()
    # PyYAML reads a bare `on:` key as the boolean True.
    on = doc.get("on", doc.get(True))
    assert "pull_request" in on


def test_workflow_enablesTSanAndChecksLogAndSuites():
    run = _tsan_step()["run"]
    assert "-enableThreadSanitizer YES" in run
    assert "scripts/tsan-lane.py check-log" in run
    assert "scripts/tsan-lane.py check-ran" in run
    assert "-only-testing:PalaceTests/" in run


def test_workflow_resolvesSuitesFromTheManifest():
    runs = "\n".join(s.get("run", "") for s in _workflow()["jobs"]["tsan"]["steps"])
    assert "scripts/tsan-lane.py suites" in runs


def test_workflow_enablesTheLoadSensitiveVariants():
    assert _tsan_step()["env"].get("TEST_RUNNER_PALACE_STRESS_POOL") == "1"


def test_workflow_letsTheHostContinuePastARace():
    # xcodebuild sets halt_on_error=1. On a race the host then aborts from
    # inside TSan's report path and hangs instead of exiting; the step would
    # sit until its timeout. With halt_on_error=0 the run finishes and the log
    # scan reports every race.
    opts = _tsan_step()["env"].get("TEST_RUNNER_TSAN_OPTIONS", "")
    assert "halt_on_error=0" in opts.split(":")


def test_workflow_readsXcodebuildExitDirectly_notThroughAPipe():
    run = _tsan_step()["run"]
    assert "XCB_EXIT=$?" in run
    xcb_last_line = next(ln for ln in run.splitlines() if "ONLY_ACTIVE_ARCH=YES" in ln)
    assert "|" not in xcb_last_line
    assert 'if [ "$XCB_EXIT" -ne 0 ]' in run


def _run_tsan_step_with_failing_xcodebuild(tmp_path: Path) -> subprocess.CompletedProcess:
    """Run the step's script the way Actions runs `shell: bash` (bash -e -o
    pipefail), with xcodebuild stubbed to exit 65 and every other tool stubbed
    to record its arguments."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls.log"
    stubs = {
        "xcodebuild": "exit 65",
        "xcrun": 'if [ "$1" = simctl ]; then '
                 'echo "iPhone 16 (00000000-0000-0000-0000-000000000000) (Shutdown)"; '
                 'elif [ "$1" = xcresulttool ]; then echo "{}"; fi',
        "python3": "exit 0",
    }
    for name, body in stubs.items():
        stub = bin_dir / name
        stub.write_text(f'#!/bin/bash\necho "{name} $*" >> "{calls}"\n{body}\n')
        stub.chmod(0o755)
    runner_temp = tmp_path / "runner"
    runner_temp.mkdir()
    (runner_temp / "tsan-suites.txt").write_text("SomeConcurrencyTests\n")
    (runner_temp / "TestResults-tsan.xcresult").mkdir()
    script = tmp_path / "step.sh"
    # The step deletes the bundle before the run; the stub xcodebuild does not
    # recreate it, so recreate it after the rm to exercise the check-ran path.
    script.write_text(_tsan_step()["run"].replace(
        'rm -rf "$RESULT"', 'rm -rf "$RESULT"; mkdir -p "$RESULT"'))
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "RUNNER_TEMP": str(runner_temp)}
    proc = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", str(script)],
                          capture_output=True, text=True, env=env, cwd=tmp_path)
    proc.calls = calls.read_text() if calls.exists() else ""
    return proc


def test_workflow_failingXcodebuild_underActionsErrexit_stillRunsTheChecks(tmp_path):
    # Actions runs `shell: bash` as `bash -e -o pipefail`. If errexit is still
    # on when xcodebuild fails, the step ends at that line and the log scan,
    # the suite check and the exit-status message never run.
    proc = _run_tsan_step_with_failing_xcodebuild(tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "python3 scripts/tsan-lane.py check-log" in proc.calls
    assert "python3 scripts/tsan-lane.py check-ran" in proc.calls
    assert "::error::xcodebuild exited 65" in proc.stdout

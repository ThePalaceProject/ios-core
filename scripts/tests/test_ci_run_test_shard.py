"""End-to-end wiring test for scripts/ci-run-test-shard.sh, with Xcode stubbed.

prior-art-checked: follows the scripts/tests/ pytest convention; the stubbed-PATH
shape is the one test_find_test_polluter_end_to_end.py uses.

The planner's own tests prove the plan partitions the classes. This proves the
shell that CONSUMES the plan: that it hands each class to the right pass, keeps
the retry scoping, fails the shard when a pass fails, and fails it when a class
it was given does not appear in the result bundle — plus the clean path, where
it must pass. `xcodebuild` and `xcrun` are replaced by stubs that record their
arguments and fabricate a result bundle holding exactly the classes they were
asked to run (optionally minus one), so every branch runs without a simulator.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "scripts" / "ci-run-test-shard.sh"

XCODEBUILD = textwrap.dedent("""\
    #!/bin/bash
    # Records its arguments, then writes a fake bundle: one line per test case,
    # "Bundle|Class|method|result|message". A class-level -only-testing id runs
    # one case "t"; a method-level id (the second chance) runs that method.
    # STUB_HANG=<Bundle/Class>: the runner given that class never connects, the
    # first time only (always, with STUB_HANG_AGAIN): the class is absent and a
    # System Failures case is recorded, as on run 36797084975.
    # STUB_SYSFAIL_ONLY: record that runner failure once, losing nothing.
    # STUB_CRASH=<n>: the first n invocations abort the way Xcode 26.3's
    # XCTHarness does (PRs #1562, #1565): the INTERNAL ERROR marker, exit 134,
    # and a bundle directory with nothing readable in it. STUB_CRASH_FAILED
    # also prints a failed test before the abort; STUB_CRASH_EXIT overrides 134.
    echo "$*" >> "$STUB_LOG"
    bundle=""; prev=""; ids=()
    for a in "$@"; do
      [ "$prev" = "-resultBundlePath" ] && bundle="$a"
      case "$a" in -only-testing:*) ids+=("${a#-only-testing:}");; esac
      prev="$a"
    done
    crashes="$STUB_LOG.crashes"
    n=$(cat "$crashes" 2>/dev/null || echo 0)
    if [ "$n" -lt "${STUB_CRASH:-0}" ]; then
      echo $((n + 1)) > "$crashes"
      mkdir -p "$bundle"
      [ -n "${STUB_CRASH_FAILED:-}" ] && echo "Test case 'A.t()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (0.010 seconds)"
      echo "** INTERNAL ERROR: Uncaught exception **"
      echo "Uncaught Exception: Unexpected operation <IDERunOperation: 0x1; state = aReF!C>, current operation is (null)"
      exit "${STUB_CRASH_EXIT:-134}"
    fi
    mkdir -p "$bundle"; : > "$bundle/cases"
    failed=0
    hung="$STUB_LOG.hung"
    if [ -n "${STUB_SYSFAIL_ONLY:-}" ] && [ ! -e "$hung" ]; then
      touch "$hung"; failed=1
      echo "PalaceTests|System Failures|Palace (36741) encountered an error|Failed|The test runner hung before establishing connection." >> "$bundle/cases"
    fi
    for id in "${ids[@]}"; do
      [ "$id" = "${STUB_DROP:-}" ] && continue
      if [ "$id" = "${STUB_HANG:-}" ] && { [ ! -e "$hung" ] || [ -n "${STUB_HANG_AGAIN:-}" ]; }; then
        touch "$hung"; failed=1
        echo "PalaceTests|System Failures|Palace (36741) encountered an error|Failed|The test runner hung before establishing connection." >> "$bundle/cases"
        continue
      fi
      IFS=/ read -r b c m <<< "$id"
      rerun=0; [ -n "$m" ] && rerun=1; m="${m:-t}"
      result="Passed"; msg=""
      if [ "$b/$c" = "${STUB_KILL:-}" ] && { [ $rerun -eq 0 ] || [ -n "${STUB_KILL_AGAIN:-}" ]; }; then
        result="Failed"; msg="Test exceeded execution time allowance of 2 minutes"
      fi
      if [ "$b/$c" = "${STUB_FAIL:-}" ]; then result="Failed"; msg="XCTAssertEqual failed"; fi
      [ "$result" = "Failed" ] && { failed=1; echo "Test case '$c.$m()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (0.010 seconds)"; }
      echo "$b|$c|$m|$result|$msg" >> "$bundle/cases"
    done
    [ $failed -eq 1 ] && exit 65
    exit "${STUB_XCB_EXIT:-0}"
    """)

XCRUN = textwrap.dedent("""\
    #!/bin/bash
    if [ "$1" = "simctl" ]; then
      echo "    iPhone 16 Pro (11111111-2222-3333-4444-555555555555) (Shutdown)"; exit 0
    fi
    if [ "$1 $2" = "xcresulttool merge" ]; then
      out="$4"; shift 4
      # A bundle xcodebuild abandoned has no Info.plist, and merge refuses it.
      for b in "$@"; do [ -e "$b/cases" ] || { echo "error: $b is not a result bundle" >&2; exit 1; }; done
      mkdir -p "$out"
      for b in "$@"; do cat "$b/cases" >> "$out/cases"; done; exit 0
    fi
    if [ "$1 $2 $3 $4" = "xcresulttool get test-results tests" ]; then
      [ -e "$6/cases" ] || { echo "error: $6 is not a result bundle" >&2; exit 1; }
      python3 - "$6/cases" <<'PY'
    import json, sys
    bundles = {}
    for line in open(sys.argv[1]).read().splitlines():
        b, c, m, result, msg = line.split("|")
        name, ident = (m, m) if c == "System Failures" else (f"{m}()", f"{c}/{m}()")
        case = {"nodeType": "Test Case", "name": name, "nodeIdentifier": ident,
                "result": result, "children": [{"nodeType": "Failure Message", "name": msg}] if msg else []}
        suites = bundles.setdefault(b, {})
        suites.setdefault(c, {"nodeType": "Test Suite", "name": c, "children": []})["children"].append(case)
    print(json.dumps({"testNodes": [{"nodeType": "Unit test bundle", "name": b,
                                     "children": list(s.values())} for b, s in bundles.items()]}))
    PY
      exit 0
    fi
    echo "unexpected xcrun $*" >&2; exit 2
    """)


def _exe(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _exe(bin_dir / "xcodebuild", XCODEBUILD)
    _exe(bin_dir / "xcrun", XCRUN)
    plan = {
        "shards": 2,
        "classes": {"PalaceTests/A": 0, "PalaceTests/Iso": 0, "TenPrintCoverTests/T": 0,
                    "PalaceTests/B": 1},
        "isolated": ["PalaceTests/Iso"],
        "extras": {"streaming-on": 1, "packages": 1},
        "estimated_seconds": [1, 1], "hashed": [],
    }
    (tmp_path / "plan.json").write_text(json.dumps(plan))
    e = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
         "STUB_LOG": str(tmp_path / "xcodebuild.log"), "SHARD_BUDGET_SECONDS": "120"}
    return tmp_path, e


def _run(tmp_path, env, shard=0, **extra):
    return subprocess.run(["bash", str(RUNNER), "Fake.xctestrun", str(tmp_path / "plan.json"),
                           str(shard), str(tmp_path / "out")],
                          capture_output=True, text=True, env={**env, **extra}, timeout=60)


def test_clean_shard_passes_and_reports_every_assigned_class(env):
    tmp_path, e = env
    r = _run(tmp_path, e)
    assert r.returncode == 0, r.stdout + r.stderr
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["executed"] == ["PalaceTests/A", "PalaceTests/Iso", "TenPrintCoverTests/T"]
    assert report["missing"] == [] and report["foreign"] == []


def test_isolated_classes_go_to_a_serial_pass_and_the_rest_to_the_parallel_one(env):
    tmp_path, e = env
    _run(tmp_path, e)
    calls = (tmp_path / "xcodebuild.log").read_text().splitlines()
    assert len(calls) == 2
    parallel, serial = calls
    assert "-parallel-testing-enabled YES" in parallel
    assert "-maximum-parallel-testing-workers 2" in parallel, "2 clones per shard, not 4"
    assert "-only-testing:PalaceTests/A" in parallel and "-only-testing:TenPrintCoverTests/T" in parallel
    assert "Iso" not in parallel
    assert "-parallel-testing-enabled NO" in serial
    assert serial.count("-only-testing:") == 1 and "-only-testing:PalaceTests/Iso" in serial


def test_both_passes_keep_retry_scoping_and_timeouts(env):
    tmp_path, e = env
    _run(tmp_path, e)
    for call in (tmp_path / "xcodebuild.log").read_text().splitlines():
        assert call.startswith("test-without-building -xctestrun Fake.xctestrun")
        assert "-retry-tests-on-failure -test-iterations 3" in call
        assert "-test-repetition-relaunch-enabled" not in call
        assert "-test-timeouts-enabled YES" in call
        assert "-collect-test-diagnostics on-failure" in call


def test_a_shard_with_no_isolated_classes_runs_one_pass(env):
    tmp_path, e = env
    r = _run(tmp_path, e, shard=1)
    assert r.returncode == 0, r.stdout + r.stderr
    assert len((tmp_path / "xcodebuild.log").read_text().splitlines()) == 1


def test_a_class_missing_from_the_bundle_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_DROP="TenPrintCoverTests/T")
    assert r.returncode == 1
    assert "TenPrintCoverTests/T" in r.stdout
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == ["TenPrintCoverTests/T"]


def test_a_failing_xcodebuild_fails_the_shard_but_still_writes_the_report(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_XCB_EXIT="65")
    assert r.returncode == 1
    assert "parallel=65" in r.stdout
    assert (tmp_path / "out/shard-report.json").exists()


def test_single_pass_iteration_mode_omits_the_retry_flags(env):
    """xcodebuild rejects `-test-iterations 1`; CI_TEST_ITERATIONS=1 must drop both."""
    tmp_path, e = env
    r = _run(tmp_path, e, CI_TEST_ITERATIONS="1")
    assert r.returncode == 0, r.stdout + r.stderr
    for call in (tmp_path / "xcodebuild.log").read_text().splitlines():
        assert "-retry-tests-on-failure" not in call and "-test-iterations" not in call


# --------------------------------------------------------------------------
# The second chance for allowance kills
# --------------------------------------------------------------------------

def test_a_kill_that_passes_alone_passes_the_shard_and_says_so(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A")
    assert r.returncode == 0, r.stdout + r.stderr
    calls = (tmp_path / "xcodebuild.log").read_text().splitlines()
    rerun = calls[-1]
    assert rerun.count("-only-testing:") == 1 and "-only-testing:PalaceTests/A/t" in rerun
    assert "-retry-tests-on-failure" not in rerun, "the second chance runs once"
    assert "-parallel-testing-enabled NO" in rerun
    assert "::warning title=Second chance for allowance kills::" in r.stdout
    assert "passed on the second chance" in r.stdout


def test_a_kill_that_repeats_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_KILL_AGAIN="1")
    assert r.returncode == 1
    assert "Allowance kill repeated" in r.stdout


def test_no_second_chance_when_any_failure_is_not_a_kill(env):
    """An assertion failure must never be re-run into a pass, and its presence
    withholds the second chance from the kills beside it too."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_FAIL="TenPrintCoverTests/T")
    assert r.returncode == 1
    assert "no second chance" in r.stdout
    assert len((tmp_path / "xcodebuild.log").read_text().splitlines()) == 2


def test_an_ordinary_failure_fails_the_shard_without_a_rerun(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_FAIL="PalaceTests/A")
    assert r.returncode == 1
    assert len((tmp_path / "xcodebuild.log").read_text().splitlines()) == 2


def test_the_shard_prints_its_memory_summary(env):
    tmp_path, e = env
    r = _run(tmp_path, e)
    assert "Shard 0 runner memory over" in r.stdout


# --------------------------------------------------------------------------
# Runner failures: classes a test runner never ran are relaunched once
# --------------------------------------------------------------------------

def _calls(tmp_path):
    return (tmp_path / "xcodebuild.log").read_text().splitlines()


def test_classes_lost_to_a_hung_runner_are_relaunched_once_and_the_shard_passes(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/A")
    assert r.returncode == 0, r.stdout + r.stderr
    calls = _calls(tmp_path)
    assert len(calls) == 3
    relaunch = calls[-1]
    assert relaunch.count("-only-testing:") == 1 and "-only-testing:PalaceTests/A" in relaunch
    assert "-parallel-testing-enabled YES" in relaunch
    assert "-retry-tests-on-failure -test-iterations 3" in relaunch
    assert "::warning title=Runner failure" in r.stdout
    assert "The test runner hung before establishing connection." in r.stdout
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == [] and report["foreign"] == []
    assert "PalaceTests/A" in report["executed"]
    assert report["system_failures"][0]["message"] == "The test runner hung before establishing connection."


def test_a_lost_isolated_class_is_relaunched_serially(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/Iso")
    assert r.returncode == 0, r.stdout + r.stderr
    relaunch = _calls(tmp_path)[-1]
    assert relaunch.count("-only-testing:") == 1 and "-only-testing:PalaceTests/Iso" in relaunch
    assert "-parallel-testing-enabled NO" in relaunch


def test_a_runner_failure_that_repeats_on_relaunch_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/A", STUB_HANG_AGAIN="1")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 3, "relaunched once, not again"
    assert "Runner failure not recovered" in r.stdout
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == ["PalaceTests/A"]


def test_a_relaunch_does_not_excuse_a_test_failure_elsewhere_in_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/A", STUB_FAIL="TenPrintCoverTests/T")
    assert r.returncode == 1
    assert "-only-testing:PalaceTests/A" in _calls(tmp_path)[2]


def test_a_runner_failure_that_lost_no_class_still_fails_and_says_why(env):
    """Nothing to relaunch, and the bundle cannot say which tests it cost."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_SYSFAIL_ONLY="1")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 2
    assert "The test runner hung before establishing connection." in r.stdout
    assert "every assigned class ran" in r.stdout



# --------------------------------------------------------------------------
# xcodebuild's own crash: one retry of the pass, never of a test failure
# --------------------------------------------------------------------------

def _bundle_of(call):
    args = call.split()
    return args[args.index("-resultBundlePath") + 1]


def _selection(call):
    return sorted(a for a in call.split() if a.startswith("-only-testing:"))


def test_an_xcodebuild_internal_error_is_retried_once_and_the_shard_passes(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1")
    assert r.returncode == 0, r.stdout + r.stderr
    calls = _calls(tmp_path)
    assert len(calls) == 3, "crashed parallel pass, its retry, then the serial pass"
    crashed, retry, serial = calls
    assert _selection(retry) == _selection(crashed), "the retry runs the same classes"
    assert "-parallel-testing-enabled YES" in retry
    assert _bundle_of(retry) != _bundle_of(crashed), "the retry writes a fresh bundle"
    assert "-parallel-testing-enabled NO" in serial
    assert "::warning title=xcodebuild crashed; retrying the pass once::" in r.stdout
    assert "exit 134" in r.stdout
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == []


def test_the_internal_error_marker_alone_triggers_the_retry(env):
    """Same crash, different exit code: the marker is the signal too."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_EXIT="65")
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(_calls(tmp_path)) == 3


def test_an_internal_error_that_repeats_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="2")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 2, "retried once, not again, and nothing after"
    assert "::error title=xcodebuild crashed again::" in r.stdout
    assert "Shard 0 passed" not in r.stdout


def test_a_test_failure_with_exit_65_is_not_retried(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_FAIL="PalaceTests/A")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 2
    assert "xcodebuild crashed" not in r.stdout


def test_a_crash_after_a_test_failed_is_not_retried(env):
    """A retry could turn the failed test green, so the crash is not excused."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="1")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 1
    assert "retrying the pass once" not in r.stdout

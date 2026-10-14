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

import importlib.util
import json
import os
import re
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
    # also prints a failed test: "after" logs it after the marker, the way Xcode
    # 26.6 fails the test in flight when it gives up on it (run 36952741418);
    # "nomarker" exits without the marker; any other value logs it before the
    # marker. STUB_CRASH_EXIT overrides 134.
    # STUB_INTERRUPT=parallel|serial: the first pass of that kind is stopped at
    # the shard budget (runs 37947147417, 37962677753): the INTERRUPTED marker,
    # exit 73, and a bundle marked "nocoverage" that holds the runner failure
    # only, or with STUB_INTERRUPT_RAN its classes as passed (one Failed with
    # STUB_INTERRUPT_FAILED, killed if it is STUB_KILL), or nothing readable with
    # STUB_INTERRUPT_UNREADABLE. STUB_INTERRUPT_LOGGED_FAILURE logs a failed
    # test that the bundle does not record, as for the test in flight.
    # STUB_INTERRUPT_LATE=parallel|serial: the budget fires after that pass's
    # tests finished, while coverage is collected (run 38261917670): the tests
    # are recorded, the bundle is marked "nocoverage", and the stub prints
    # SUCCEEDED and exits 0. Either interrupt writes the shard's budget marker,
    # as its watchdog does before it sends SIGINT. STUB_OUTLAST_BUDGET=<kind>
    # ends the same way after sleeping past the budget, without writing the
    # marker, so only the shard's own watchdog can; it waits for that marker
    # (up to 30 s) rather than for a fixed time. STUB_INTERRUPT_NO_MARK keeps
    # STUB_INTERRUPT from writing the marker, leaving only the log line.
    # STUB_INTERRUPT_IN_FLIGHT logs the first class's test as failed in 0.000 s
    # after the INTERRUPTED line, as Xcode does for the test it cuts off (run
    # 38278109196); =bundle also records it Failed in the bundle.
    # STUB_RERUN_SAVE_FAIL: a method-level re-run (the second chance) runs its
    # tests, then cannot save the bundle and exits 73 (run 38292451781); with
    # =nobundle the bundle holds nothing readable, and with =loggedfail the log
    # shows a failed test the bundle records as passed; =noresult leaves a
    # readable bundle that records none of the re-run tests and logs no failure.
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
      failure="Test case 'A.t()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (120.000 seconds)"
      case "${STUB_CRASH_FAILED:-}" in ""|after|nomarker) ;; *) echo "$failure";; esac
      if [ "${STUB_CRASH_FAILED:-}" != "nomarker" ]; then
        echo "** INTERNAL ERROR: Uncaught exception **"
        echo "Uncaught Exception: Unexpected operation <IDERunOperation: 0x1; state = aReF!C>, current operation is (null)"
      fi
      case "${STUB_CRASH_FAILED:-}" in after|nomarker) echo "$failure";; esac
      exit "${STUB_CRASH_EXIT:-134}"
    fi
    kind=serial; case "$*" in *"-parallel-testing-enabled YES"*) kind=parallel;; esac
    interrupted="$STUB_LOG.interrupted"
    if [ "${STUB_INTERRUPT:-}" = "$kind" ] && [ ! -e "$interrupted" ]; then
      touch "$interrupted"
      [ -n "${STUB_INTERRUPT_NO_MARK:-}" ] || touch "$(dirname "$bundle")/budget-exceeded"
      mkdir -p "$bundle"; touch "$bundle/nocoverage"
      if [ -z "${STUB_INTERRUPT_UNREADABLE:-}" ]; then
        : > "$bundle/cases"
        if [ -n "${STUB_INTERRUPT_RAN:-}" ]; then
          for id in "${ids[@]}"; do
            IFS=/ read -r b c m <<< "$id"
            result="Passed"; msg=""
            [ "$b/$c" = "${STUB_KILL:-}" ] && { result="Failed"; msg="Test exceeded execution time allowance of 2 minutes"; }
            if [ -n "${STUB_INTERRUPT_FAILED:-}" ]; then
              result="Failed"; msg="XCTAssertEqual failed"
              echo "Test case '$c.t()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (0.010 seconds)"
            fi
            echo "$b|$c|t|$result|$msg" >> "$bundle/cases"
          done
        else
          echo "PalaceTests|System Failures|Palace (6129) encountered an error|Failed|The test runner hung before establishing connection." >> "$bundle/cases"
        fi
      fi
      if [ -n "${STUB_INTERRUPT_LOGGED_FAILURE:-}" ]; then
        echo "Test Case '-[PalaceTests.Iso t]' failed (0.010 seconds)."
      fi
      echo "** TEST EXECUTE INTERRUPTED **"
      if [ -n "${STUB_INTERRUPT_IN_FLIGHT:-}" ]; then
        IFS=/ read -r b c m <<< "${ids[0]}"
        echo "Test case '$c.t()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (0.000 seconds)"
        [ "$STUB_INTERRUPT_IN_FLIGHT" = "bundle" ] && echo "$b|$c|t|Failed|" >> "$bundle/cases"
      fi
      exit 73
    fi
    mkdir -p "$bundle"; : > "$bundle/cases"
    if [ "${STUB_OUTLAST_BUDGET:-}" = "$kind" ] && [ ! -e "$interrupted" ]; then
      touch "$interrupted" "$bundle/nocoverage"
      for _ in $(seq 300); do [ -e "$(dirname "$bundle")/budget-exceeded" ] && break; sleep 0.1; done
      late=1
    fi
    if [ "${STUB_INTERRUPT_LATE:-}" = "$kind" ] && [ ! -e "$interrupted" ]; then
      touch "$interrupted" "$(dirname "$bundle")/budget-exceeded" "$bundle/nocoverage"
      late=1
    fi
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
      rerun=0; [ -n "$m" ] && rerun=1 && any_rerun=1; m="${m:-t}"
      result="Passed"; msg=""
      if [ "$b/$c" = "${STUB_KILL:-}" ] && { [ $rerun -eq 0 ] || [ -n "${STUB_KILL_AGAIN:-}" ]; }; then
        result="Failed"; msg="Test exceeded execution time allowance of 2 minutes"
      fi
      if [ "$b/$c" = "${STUB_FAIL:-}" ]; then result="Failed"; msg="XCTAssertEqual failed"; fi
      [ "$result" = "Failed" ] && { failed=1; echo "Test case '$c.$m()' failed on 'Clone 1 of iPhone 16 Pro - Palace (123)' (0.010 seconds)"; }
      echo "$b|$c|$m|$result|$msg" >> "$bundle/cases"
    done
    [ -n "${late:-}" ] && [ $failed -eq 0 ] && echo "** TEST EXECUTE SUCCEEDED **"
    if [ -n "${STUB_RERUN_SAVE_FAIL:-}" ] && [ -n "${any_rerun:-}" ]; then
      touch "$bundle/nocoverage"
      [ "$STUB_RERUN_SAVE_FAIL" = "nobundle" ] && rm -f "$bundle/cases"
      [ "$STUB_RERUN_SAVE_FAIL" = "noresult" ] && : > "$bundle/cases"
      [ "$STUB_RERUN_SAVE_FAIL" = "loggedfail" ] && echo "Test Case '-[PalaceTests.A t]' failed (0.010 seconds)." && failed=1
      [ $failed -eq 0 ] && echo "** TEST EXECUTE SUCCEEDED **"
      echo "Error saving invocation record to resultBundlePath: Could not write the 1_Test action log because the log hasn't finished recording"
      exit 73
    fi
    [ $failed -eq 1 ] && exit 65
    exit "${STUB_XCB_EXIT:-0}"
    """)

XCRUN = textwrap.dedent("""\
    #!/bin/bash
    if [ "$1 $2" = "simctl bootstatus" ]; then
      echo "$*" >> "$STUB_LOG.simctl"
      # STUB_BOOTSTATUS=fail: the template does not report a booted device.
      # =hang: it never returns, so only the bounded wait around it can end it.
      [ "${STUB_BOOTSTATUS:-}" = "hang" ] && sleep 120
      [ "${STUB_BOOTSTATUS:-}" = "fail" ] && exit 164
      echo "All devices have finished booting."; exit 0
    fi
    if [ "$1" = "simctl" ]; then
      echo "    iPhone 16 Pro (11111111-2222-3333-4444-555555555555) (Shutdown)"; exit 0
    fi
    if [ "$1 $2" = "xcresulttool merge" ]; then
      out="$4"; shift 4
      # A bundle xcodebuild abandoned has no Info.plist, and merge refuses it.
      for b in "$@"; do [ -e "$b/cases" ] || { echo "error: $b is not a result bundle" >&2; exit 1; }; done
      mkdir -p "$out"
      # One input without a coverage report leaves the merged bundle unreadable to xccov.
      for b in "$@"; do cat "$b/cases" >> "$out/cases"; [ -e "$b/nocoverage" ] && touch "$out/nocoverage"; done; exit 0
    fi
    if [ "$1 $2" = "xccov view" ]; then
      b="${@: -1}"
      [ -e "$b/cases" ] && [ ! -e "$b/nocoverage" ] || { echo "error: Failed to load coverage report" >&2; exit 1; }
      exit 0
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


# The watchdog's pkill must reach only this test's stub, never an
# xcodebuild run elsewhere on the machine.
PKILL = textwrap.dedent("""\
    #!/bin/bash
    echo "$*" >> "$STUB_LOG.pkill"
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
    _exe(bin_dir / "pkill", PKILL)
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
    tests = json.dumps(json.loads((tmp_path / "out/tests.json").read_text()))
    assert '"nodeIdentifier": "A/t()", "result": "Passed"' in tests, "the re-run is merged, not hidden"
    assert "rerun.xcresult" not in _partial(tmp_path)


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


def test_the_test_in_flight_when_xcodebuild_crashed_does_not_block_the_retry(env):
    """Run 36952741418: Xcode 26.6 logs the in-flight test as failed after the
    crash marker. That failure is the crash's, so the pass is retried."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="after")
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(_calls(tmp_path)) == 3, "crashed parallel pass, its retry, then the serial pass"
    warning = next(l for l in r.stdout.splitlines()
                   if l.startswith("::warning title=xcodebuild crashed; retrying the pass once::"))
    assert "A.t()" in warning, "the annotation names the in-flight test it discounted"


def test_the_in_flight_test_must_still_pass_on_the_retry(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="after", STUB_FAIL="PalaceTests/A")
    assert r.returncode == 1
    assert "retrying the pass once" in r.stdout
    assert "Shard 0 passed" not in r.stdout


def test_a_failure_logged_before_the_crash_marker_is_not_retried(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="before")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 1
    assert "::error title=xcodebuild crashed after a test failed::" in r.stdout
    assert "retrying the pass once" not in r.stdout


def test_exit_134_with_a_failure_and_no_crash_marker_is_not_retried(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="nomarker")
    assert r.returncode == 1
    assert len(_calls(tmp_path)) == 1
    assert "::error title=xcodebuild crashed after a test failed::" in r.stdout
    assert "retrying the pass once" not in r.stdout


# --------------------------------------------------------------------------
# A crashed or failed pass keeps its bundle and log for upload (run 36961391002)
# --------------------------------------------------------------------------

def _partial(tmp_path):
    d = tmp_path / "out/partial"
    return sorted(p.name for p in d.iterdir()) if d.is_dir() else []


def test_a_clean_shard_keeps_no_partial_results(env):
    tmp_path, e = env
    r = _run(tmp_path, e)
    assert r.returncode == 0, r.stdout + r.stderr
    assert _partial(tmp_path) == []


def test_a_crash_after_a_test_failed_keeps_the_unmerged_bundle_and_its_log(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_CRASH_FAILED="before")
    assert r.returncode == 1
    assert not (tmp_path / "out/TestResults.xcresult").exists()
    assert _partial(tmp_path) == ["parallel.log", "parallel.xcresult"]
    log = (tmp_path / "out/partial/parallel.log").read_text()
    assert "Test case 'A.t()' failed" in log
    assert "** INTERNAL ERROR: Uncaught exception **" in log


def test_a_crash_that_is_retried_keeps_the_crashed_bundle_and_log(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1")
    assert r.returncode == 0, r.stdout + r.stderr
    assert _partial(tmp_path) == ["parallel.log", "parallel.xcresult"]
    assert "** INTERNAL ERROR" in (tmp_path / "out/partial/parallel.log").read_text()


def test_a_crash_that_repeats_keeps_both_crashed_passes(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="2")
    assert r.returncode == 1
    assert _partial(tmp_path) == ["parallel-crash-retry.log", "parallel-crash-retry.xcresult",
                                  "parallel.log", "parallel.xcresult"]


def test_a_failed_shard_keeps_its_pass_logs(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_FAIL="PalaceTests/A")
    assert r.returncode == 1
    assert _partial(tmp_path) == ["parallel.log", "serial.log"]
    assert "Test case 'A.t()' failed" in (tmp_path / "out/partial/parallel.log").read_text()


# --------------------------------------------------------------------------
# A pass stopped at the shard budget (runs 37947147417, 37962677753)
# --------------------------------------------------------------------------

def _results_lack_coverage(tmp_path):
    return (tmp_path / "out/TestResults.xcresult/nocoverage").exists()


def test_an_interrupted_pass_with_no_failure_is_set_aside_and_its_classes_rerun(env):
    """The interrupted bundle has no coverage report, so merging it breaks the
    coverage report for the whole run; its classes must run again instead."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial")
    assert r.returncode == 0, r.stdout + r.stderr
    calls = _calls(tmp_path)
    assert len(calls) == 3, "parallel, interrupted serial, relaunch"
    assert _selection(calls[2]) == ["-only-testing:PalaceTests/Iso"]
    assert "-parallel-testing-enabled NO" in calls[2]
    assert not _results_lack_coverage(tmp_path)
    assert "serial-interrupted.xcresult" in _partial(tmp_path) and "serial.log" in _partial(tmp_path)
    assert "::warning title=Pass interrupted; its classes run again::" in r.stdout
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == [] and "PalaceTests/Iso" in report["executed"]


def test_classes_that_finished_before_the_interruption_run_again(env):
    """A class that completed in the interrupted pass has no coverage either,
    so it is relaunched too, not only the ones that never started."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="parallel", STUB_INTERRUPT_RAN="1")
    assert r.returncode == 0, r.stdout + r.stderr
    relaunch = _calls(tmp_path)[-1]
    assert _selection(relaunch) == ["-only-testing:PalaceTests/A", "-only-testing:TenPrintCoverTests/T"]
    assert "-parallel-testing-enabled YES" in relaunch
    assert not _results_lack_coverage(tmp_path)


def test_a_failure_in_an_interrupted_pass_fails_the_shard_and_stays_in_the_results(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_RAN="1", STUB_INTERRUPT_FAILED="1")
    assert r.returncode == 1
    assert "::error title=Interrupted pass recorded a test failure::" in r.stdout
    assert "Shard 0 passed" not in r.stdout
    tests = json.loads((tmp_path / "out/tests.json").read_text())
    assert '"result": "Failed"' in json.dumps(tests), "the failure is still in the shard results"


def test_an_interrupted_kill_is_not_excused_by_the_second_chance(env):
    """A kill would otherwise get a second chance and pass the shard while the
    interrupted bundle, merged, still breaks the coverage report."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_RAN="1", STUB_KILL="PalaceTests/Iso")
    assert r.returncode == 1, r.stdout + r.stderr
    assert "interrupted-failure=1" in r.stdout


def test_an_unreadable_interrupted_bundle_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_UNREADABLE="1")
    assert r.returncode == 1
    assert "::error title=Interrupted pass unreadable::" in r.stdout


def test_a_shard_whose_only_pass_was_interrupted_recovers_on_relaunch(env):
    """With the one bundle set aside there is nothing to merge until the relaunch."""
    tmp_path, e = env
    r = _run(tmp_path, e, shard=1, STUB_INTERRUPT="parallel")
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(_calls(tmp_path)) == 2
    assert (tmp_path / "out/TestResults.xcresult").is_dir()
    assert not _results_lack_coverage(tmp_path)


def test_a_failure_only_in_the_log_of_an_interrupted_pass_fails_the_shard(env):
    """The test running at the interrupt can be logged as failed with no result in the bundle."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_LOGGED_FAILURE="1")
    assert r.returncode == 1
    assert "::error title=Interrupted pass recorded a test failure::" in r.stdout


def test_a_crash_retry_that_is_interrupted_is_set_aside_beside_the_crashed_bundle(env):
    """The retry's own log carries the marker, and both bundles stay in partial/."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", STUB_INTERRUPT="parallel")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not _results_lack_coverage(tmp_path)
    assert {"parallel.xcresult", "parallel-interrupted.xcresult"} <= set(_partial(tmp_path))
    assert _selection(_calls(tmp_path)[-1]) == ["-only-testing:PalaceTests/A",
                                               "-only-testing:TenPrintCoverTests/T"]


def test_an_interrupt_after_the_last_test_is_caught_though_the_pass_reports_success(env):
    """Run 38261917670: the budget fired while coverage was collected; the pass
    printed SUCCEEDED and exited 0, and its bundle had no coverage report."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT_LATE="serial")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "** TEST EXECUTE SUCCEEDED **" in r.stdout
    assert not _results_lack_coverage(tmp_path)
    assert "serial-interrupted.xcresult" in _partial(tmp_path)
    assert _selection(_calls(tmp_path)[-1]) == ["-only-testing:PalaceTests/Iso"]


def test_a_failure_before_a_late_interrupt_still_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT_LATE="serial", STUB_FAIL="PalaceTests/Iso")
    assert r.returncode == 1
    assert "::error title=Interrupted pass recorded a test failure::" in r.stdout
    assert "Shard 0 passed" not in r.stdout


def test_a_pass_that_starts_after_the_budget_fired_is_merged(env):
    """Only the pass running when the budget fired lost its coverage; the passes
    after it are merged as usual."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT_LATE="parallel")
    assert r.returncode == 0, r.stdout + r.stderr
    assert _partial(tmp_path) == ["parallel-interrupted.xcresult", "parallel.log"]
    assert not _results_lack_coverage(tmp_path)
    report = json.loads((tmp_path / "out/shard-report.json").read_text())
    assert report["missing"] == [] and "PalaceTests/Iso" in report["executed"]


def test_the_watchdog_marks_the_pass_it_interrupts(env):
    """The shard's own watchdog, not the stub, records that the budget fired. The
    first pass outlasts the budget, so the budget only has to outlast the setup."""
    tmp_path, e = env
    r = _run(tmp_path, e, SHARD_BUDGET_SECONDS="8", STUB_OUTLAST_BUDGET="parallel")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "exceeded 8s; interrupting" in r.stdout
    assert "-INT -f" in (tmp_path / "xcodebuild.log.pkill").read_text()
    assert not _results_lack_coverage(tmp_path)
    assert "parallel-interrupted.xcresult" in _partial(tmp_path)


def test_a_budget_marker_left_from_an_earlier_run_is_cleared(env):
    """A stale marker would make every pass look as if it started after the budget fired."""
    tmp_path, e = env
    (tmp_path / "out").mkdir()
    (tmp_path / "out/budget-exceeded").touch()
    r = _run(tmp_path, e, STUB_INTERRUPT_LATE="serial")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not _results_lack_coverage(tmp_path)


def test_the_interrupted_line_alone_marks_a_pass_interrupted(env):
    """An interrupt the watchdog did not send still leaves a bundle without coverage."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_NO_MARK="1")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not _results_lack_coverage(tmp_path)
    assert "serial-interrupted.xcresult" in _partial(tmp_path)


def test_the_test_cut_off_by_the_interrupt_is_rerun_not_counted_as_a_failure(env):
    """Run 38278109196: the in-flight test is logged failed (0.000 s) after the marker."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="parallel", STUB_INTERRUPT_IN_FLIGHT="bundle")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Discounted the failure of A/t" in r.stdout
    assert not _results_lack_coverage(tmp_path)
    assert "-only-testing:PalaceTests/A" in _selection(_calls(tmp_path)[-1])


def test_the_test_cut_off_by_the_interrupt_must_pass_when_rerun(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="parallel", STUB_INTERRUPT_IN_FLIGHT="log",
             STUB_FAIL="PalaceTests/A")
    assert r.returncode == 1
    assert "Shard 0 passed" not in r.stdout


def test_a_failure_before_the_interrupt_is_not_excused_by_a_test_in_flight(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_INTERRUPT="serial", STUB_INTERRUPT_RAN="1",
             STUB_INTERRUPT_FAILED="1", STUB_INTERRUPT_IN_FLIGHT="log")
    assert r.returncode == 1
    assert "::error title=Interrupted pass recorded a test failure::" in r.stdout


def test_a_second_chance_that_passed_but_could_not_save_its_bundle_passes(env):
    """Run 38292451781: both re-run tests passed, then the bundle save failed with exit 73."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_RERUN_SAVE_FAIL="1")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Second-chance pass exit code: 73" in r.stdout
    assert "::warning title=Second chance exited 73 after its tests passed::" in r.stdout
    assert not _results_lack_coverage(tmp_path), "the coverage-less bundle is not merged"
    assert "rerun.xcresult" in _partial(tmp_path)


def test_a_second_chance_failure_is_fatal_whatever_the_exit_code(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_KILL_AGAIN="1", STUB_RERUN_SAVE_FAIL="1")
    assert r.returncode == 1
    assert "Allowance kill repeated" in r.stdout


def test_a_second_chance_with_no_readable_result_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_RERUN_SAVE_FAIL="nobundle")
    assert r.returncode == 1
    assert "Shard 0 passed" not in r.stdout


def test_a_second_chance_failure_in_the_log_is_fatal_even_if_the_bundle_says_passed(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_RERUN_SAVE_FAIL="loggedfail")
    assert r.returncode == 1
    assert "Allowance kill repeated" in r.stdout


def test_a_second_chance_that_records_no_result_fails_even_without_a_failure_line(env):
    """A runner that never connects exits non-zero, logs no failed test, and runs nothing."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", STUB_RERUN_SAVE_FAIL="noresult")
    assert r.returncode == 1
    assert "did not run on the second chance" in r.stdout
    assert "Shard 0 passed" not in r.stdout


# --------------------------------------------------------------------------
# The step deadline: every recovery phase is skipped rather than overrun
# --------------------------------------------------------------------------
#
# The shard budget interrupts one xcodebuild pass; the recovery phases after it
# each add minutes, and together they outlasted the step's timeout-minutes. The
# step was killed with shard-report.json unwritten, and the upload step then
# failed for a missing file (if-no-files-found: error, run 38582762222). The
# phase checks below keep the script inside SHARD_STEP_SECONDS; the trap in
# cleanup() is the backstop for the exits that do not reach the normal report.

NO_TIME = {"SHARD_STEP_SECONDS": "200", "SHARD_REPORT_RESERVE_SECONDS": "180"}


def _report(tmp_path):
    return json.loads((tmp_path / "out/shard-report.json").read_text())


def test_phase_fits_is_a_floor_on_the_seconds_left():
    spec = importlib.util.spec_from_file_location(
        "ci_test_shards", REPO / "scripts" / "ci-test-shards.py")
    shards = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shards)
    assert shards.phase_fits(now=1000.0, deadline=1500.0, needed=420) == (True, 500)
    assert shards.phase_fits(now=1000.0, deadline=1500.0, needed=500) == (True, 500)
    assert shards.phase_fits(now=1000.0, deadline=1500.0, needed=501) == (False, 500)
    # Past the deadline the time left is negative, so nothing fits — not even a
    # phase that claims to need no time at all.
    assert shards.phase_fits(now=1600.0, deadline=1500.0, needed=0) == (False, -100)


def test_the_step_deadline_matches_the_workflow_step_timeout():
    """The script's default and the step's timeout-minutes are one number in two
    files; a drift either overruns the step or wastes minutes of it."""
    yaml = pytest.importorskip("yaml")
    workflow = yaml.safe_load((REPO / ".github" / "workflows" / "unit-testing.yml").read_text())
    step = next(s for s in workflow["jobs"]["test"]["steps"] if s.get("id") == "tests")
    assert int(step["env"]["SHARD_STEP_SECONDS"]) == step["timeout-minutes"] * 60
    default = re.search(r"SHARD_STEP_SECONDS:-(\d+)", RUNNER.read_text()).group(1)
    assert int(default) == step["timeout-minutes"] * 60


def test_a_relaunch_that_does_not_fit_is_skipped_and_the_shard_still_reports(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/A", **NO_TIME)
    assert r.returncode == 1
    assert "Recovery phase skipped at the step deadline" in r.stdout
    assert "the relaunch of the 1 class(es) the runner lost" in r.stdout
    assert "Runner failure not recovered" in r.stdout
    assert _report(tmp_path)["missing"] == ["PalaceTests/A"]
    assert len((tmp_path / "xcodebuild.log").read_text().splitlines()) == 2, \
        "the two original passes only; no relaunch pass"


def test_a_relaunch_that_fits_still_runs(env):
    """The control for the test above: the skip is the deadline's doing, not the
    runner failure's."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_HANG="PalaceTests/A")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Recovery phase skipped" not in r.stdout
    assert "Runner failure recovered" in r.stdout


def test_a_second_chance_that_does_not_fit_is_skipped_and_the_kill_fails_the_shard(env):
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_KILL="PalaceTests/A", **NO_TIME)
    assert r.returncode == 1
    assert "the second chance for 1 allowance kill(s)" in r.stdout
    assert "Second chance skipped" in r.stdout
    assert "passed on the second chance" not in r.stdout
    assert (tmp_path / "out/shard-report.json").exists()


def test_a_crash_retry_that_does_not_fit_is_skipped_and_the_shard_still_reports(env):
    """The crash paths exit before the normal report; cleanup() owes one anyway."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="1", **NO_TIME)
    assert r.returncode == 1
    assert "the retry of the parallel pass after xcodebuild crashed" in r.stdout
    assert "xcodebuild crashed with no time to retry" in r.stdout
    assert "retrying the pass once" not in r.stdout
    assert _report(tmp_path)["missing"] == ["PalaceTests/A", "PalaceTests/Iso",
                                            "TenPrintCoverTests/T"]


def test_a_crash_that_repeats_still_leaves_a_shard_report(env):
    """The second crash exits 1 from inside run_pass, far from the report step."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_CRASH="2")
    assert r.returncode == 1
    assert "crashed again" in r.stdout
    assert (tmp_path / "out/shard-report.json").exists()


def test_a_test_failure_inside_the_deadline_is_not_excused_by_it(env):
    """A skipped phase must not change what an ordinary failure reports: with no
    time left a failing test still fails the shard, and nothing is called lost."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_FAIL="PalaceTests/A", **NO_TIME)
    assert r.returncode == 1
    assert "Recovery phase skipped" not in r.stdout
    assert _report(tmp_path)["missing"] == []


# --------------------------------------------------------------------------
# Pre-booting the simulator template
# --------------------------------------------------------------------------
#
# SIMULATOR_ID was chosen from `simctl list` and never booted, so xcodebuild
# cold-booted each parallel clone itself with a 60 s allowance: "Failed to
# prepare device 'Clone 2 of iPhone 16 Pro' for impending launch. (Underlying
# Error: Timed out trying to boot simulator after waiting 60.00s.)"

def _warm_calls(tmp_path):
    p = tmp_path / "xcodebuild.log.simctl"
    return p.read_text().splitlines() if p.exists() else []


def test_the_simulator_template_is_booted_before_any_test_pass(env):
    tmp_path, e = env
    r = _run(tmp_path, e)
    assert r.returncode == 0, r.stdout + r.stderr
    assert _warm_calls(tmp_path) == \
        ["simctl bootstatus 11111111-2222-3333-4444-555555555555 -b"], \
        "the chosen template, warmed once, with -b so it boots rather than only reporting"
    assert "is booted" in r.stdout


@pytest.mark.parametrize("mode", ["fail", "hang"])
def test_a_template_that_will_not_warm_does_not_fail_the_shard(env, mode):
    """xcodebuild boots its own clones either way, so warming is best effort."""
    tmp_path, e = env
    r = _run(tmp_path, e, STUB_BOOTSTATUS=mode, SIM_WARM_SECONDS="2")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Simulator warm-up did not finish" in r.stdout
    assert _warm_calls(tmp_path), "it still tried"

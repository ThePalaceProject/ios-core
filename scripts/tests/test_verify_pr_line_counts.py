"""Tests for the two reporting defects fixed in scripts/verify-pr.sh.

Both were fail-QUIET, not fail-loud: the script kept running and printed a
number or a verdict that was wrong. Neither had a test, and in both cases the
missing case was the EMPTY one — the input nobody writes a fixture for.

1. `count_lines` — `echo "$V" | wc -l` returns 1 for an empty V, because echo
   writes a newline regardless. verify-pr used that idiom for its "Changed
   files: N production, M test" banner, so it could never print "0 production"
   and every docs-only or test-only PR read as touching production.

2. The coverage-floor leg reported `pass — All module floors met` from an
   argparse usage error. `enforce_coverage_floors.py` takes coverage-data.json
   as a required positional; verify-pr called it with none, argparse exited 2,
   `|| true` swallowed the status, and the guard was `grep -q "VIOLATED"` over
   stdout — which a usage message does not contain. A gate that cannot fail is
   worse than no gate, because it is reported as a pass.
"""
import os
import subprocess
import sys

REPO = os.path.join(os.path.dirname(__file__), "..", "..")
VERIFY = os.path.join(REPO, "scripts", "verify-pr.sh")
ENFORCE = os.path.join(REPO, "scripts", "enforce_coverage_floors.py")


def _count_lines(value):
    """Invoke the helper exactly as verify-pr.sh defines it."""
    script = (
        "count_lines() { printf '%s' \"$1\" | grep -c . || true; }; "
        'count_lines "$1"'
    )
    out = subprocess.run(
        ["bash", "-c", script, "bash", value],
        capture_output=True, text=True, check=True,
    )
    return int(out.stdout.strip())


def test_count_lines_empty_is_zero():
    """The case that was wrong for the entire life of the banner."""
    assert _count_lines("") == 0


def test_count_lines_single_and_multi():
    assert _count_lines("a.swift") == 1
    assert _count_lines("a.swift\nb.swift") == 2
    assert _count_lines("a.swift\nb.swift\nc.swift") == 3


def test_count_lines_ignores_trailing_newline():
    """A trailing newline is a line terminator, not an extra file."""
    assert _count_lines("a.swift\n") == 1
    assert _count_lines("a.swift\nb.swift\n") == 2


def test_verify_pr_uses_count_lines_for_the_changed_files_banner():
    """Pin the call site, not just the helper — the helper existing is not the
    fix; the banner using it is."""
    src = open(VERIFY, encoding="utf-8").read()
    assert 'count_lines "$CHANGED_SWIFT"' in src
    assert 'count_lines "$CHANGED_TEST_SWIFT"' in src
    assert 'echo "$CHANGED_SWIFT" | wc -l' not in src
    assert 'echo "$CHANGED_TEST_SWIFT" | wc -l' not in src


def test_enforce_coverage_floors_requires_a_coverage_json():
    """The behaviour that made the old guard fail open. If this ever starts
    exiting 0 with no argument, the coverage leg's error handling needs
    revisiting — so this test is a tripwire on the dependency, not a
    restatement of argparse."""
    r = subprocess.run(
        ["python3", ENFORCE, "--baseline-only"],
        capture_output=True, text=True, cwd=REPO,
    )
    assert r.returncode != 0
    assert "VIOLATED" not in (r.stdout + r.stderr), (
        "the old guard grepped for VIOLATED; a usage error contains no such "
        "string, which is exactly why an error was scored as a pass"
    )


def test_coverage_leg_passes_the_json_and_keys_off_exit_code():
    """The leg must hand the enforcement script a coverage file and branch on
    its documented exit code (0 met / 1 violated / 2 input error), never on
    grepping stdout."""
    src = open(VERIFY, encoding="utf-8").read()
    assert 'enforce_coverage_floors.py "$COV_JSON"' in src
    assert 'enforce_coverage_floors.py --baseline-only' not in src
    assert 'COV_RC=$?' in src
    assert 'echo "$COV_OUTPUT" | grep -q "VIOLATED"' not in src


def test_coverage_leg_uses_this_runs_bundle_not_deriveddata():
    """`-resultBundlePath` puts the bundle under $TMPDIR, so a DerivedData
    search finds either nothing or another worktree's run."""
    src = open(VERIFY, encoding="utf-8").read()
    assert 'find ~/Library/Developer/Xcode/DerivedData -name "*.xcresult"' not in src
    i = src.index("# 4. Coverage floors")
    assert 'XCRESULT="$RESULT_BUNDLE"' in src[i:i + 3000]


def test_coverage_leg_never_reports_pass_without_measuring():
    """Every non-measuring path must record fail or skip — never pass."""
    src = open(VERIFY, encoding="utf-8").read()
    i = src.index("# 4. Coverage floors")
    block = src[i:src.index("# 5.", i)] if "# 5." in src[i:] else src[i:i + 3000]
    passes = [ln for ln in block.splitlines() if 'record "coverage_floors" "pass"' in ln]
    assert len(passes) == 1, "exactly one path may report a pass"
    assert 'COV_RC" -eq 0' in block


def test_coverage_leg_does_not_pass_baseline_only():
    """`--baseline-only` sets every floor to the current actual
    (`effective_floor = actual if baseline_only`, enforce_coverage_floors.py:170),
    so the comparison is `actual >= actual` and the gate cannot fail.

    This is not theoretical. Against a real bundle the same coverage data
    exits 0 with the flag and reports `Coverage gate: FAIL` without it
    (AudiobookSessionManager 31.5% against a recorded floor of 44.0%). Fixing
    the call site to MEASURE while leaving this flag on would have produced a
    gate that reads coverage and still always passes."""
    src = open(VERIFY, encoding="utf-8").read()
    i = src.index("# 4. Coverage floors")
    block = src[i:i + 3000]
    # Check the INVOCATION, not the block text — the fix's own comment names
    # the flag to explain why it is not used, and a naive substring search
    # would trip on the explanation. (Same trap as the ratchet detectors that
    # counted comment mentions.)
    invocations = [
        ln for ln in block.splitlines()
        if "enforce_coverage_floors.py" in ln and not ln.strip().startswith("#")
    ]
    assert invocations, "the coverage leg must invoke the enforcement script"
    for ln in invocations:
        assert "--baseline-only" not in ln, ln.strip()


def test_baseline_only_cannot_fail_by_construction():
    """Tripwire on the dependency. If `--baseline-only` ever gains real
    semantics, the comment in verify-pr.sh explaining why it is not used needs
    revisiting."""
    src = open(ENFORCE, encoding="utf-8").read()
    assert "effective_floor = actual if baseline_only else float(floor)" in src
    assert "overall_floor = overall_actual" in src


# ---------------------------------------------------------------------------
# Coverage-floor semantics. A module that leaves the measured surface used to
# `continue` without touching `all_pass`, so it silently stopped being gated —
# which is what the decomposition campaign does every time it extracts one into
# Palace/Packages (coverage reports a single target, Palace.app; none of the 11
# packages' sources are measured).
# ---------------------------------------------------------------------------

def _evaluate(floors, coverage):
    sys.path.insert(0, os.path.join(REPO, "scripts"))
    import importlib
    mod = importlib.import_module("enforce_coverage_floors")
    importlib.reload(mod)
    return mod.evaluate(coverage, floors, baseline_only=False, metric="testable")


def _coverage(files):
    return {
        "testable_coverage": 90.0,
        "targets": [],
        "files": [{"name": n, "coverage": c} for n, c in files],
    }


def test_missing_module_fails_the_gate():
    """The behaviour that made an extracted module invisible."""
    floors = {"overall": 0.0, "modules": {"GoneAway": 0.50}}
    rows, all_pass = _evaluate(floors, _coverage([("StillHere.swift", 80.0)]))
    assert all_pass is False
    assert any(r["module"] == "GoneAway" and r["status"] == "MISSING" for r in rows)


def test_present_module_above_floor_passes():
    """Control: the same shape with the module present must pass, so the test
    above is not simply asserting that everything fails."""
    floors = {"overall": 0.0, "modules": {"StillHere": 0.50}}
    rows, all_pass = _evaluate(floors, _coverage([("StillHere.swift", 80.0)]))
    assert all_pass is True
    assert any(r["module"] == "StillHere" and r["status"] == "PASS" for r in rows)


def test_present_module_below_floor_fails():
    floors = {"overall": 0.0, "modules": {"StillHere": 0.90}}
    _, all_pass = _evaluate(floors, _coverage([("StillHere.swift", 80.0)]))
    assert all_pass is False


def test_floors_file_declares_its_unmeasured_exemption():
    """TPPBookRegistry is not a violation and not a vanished module — it is an
    unmeasured surface, and that has to be recorded with a reason rather than
    dropped, or the blind spot becomes invisible again."""
    import json
    floors = json.load(open(os.path.join(REPO, "scripts", "coverage-floors.json")))
    assert "TPPBookRegistry" not in floors["modules"]
    assert "TPPBookRegistry" in floors["unmeasured"]
    assert "PalaceBookRegistry" in floors["unmeasured"]["TPPBookRegistry"]

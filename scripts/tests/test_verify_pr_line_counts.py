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
    assert 'enforce_coverage_floors.py "$COV_JSON" --baseline-only' in src
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

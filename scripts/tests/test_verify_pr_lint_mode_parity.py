"""verify-pr.sh must run every `lint-test-quality.py` mode that CI runs.

WHY THIS FILE EXISTS. `lint-test-quality.py` has two independent entry points.
`--per-file` scans the whole tree and reports FLAKE/FLUFF/MISSING/TIMEOUT.
`--changed <base>` is a separate early-return path that evaluates ONLY the
diff-scoped STARVE-001 rule, and `--per-file` never evaluates that rule at all.

`verify-pr.sh` ran only `--per-file`; `.github/workflows/tooling-checks.yml`
runs `--changed`. A clean local run therefore could not predict that CI leg,
which is the one thing CLAUDE.md points contributors at this script to do. On
2026-10-21 a branch passed verify-pr six times and arrived red in CI on a rule
no local run had evaluated.

The first test is a census rather than a hardcoded flag: it fails on the NEXT
mode CI gains and the local script does not, which is the divergence class, not
just this instance.

prior-art-checked: this asserts parity between two files in THIS repo
(`scripts/verify-pr.sh` and `.github/workflows/*`), so no local tooling applies;
the repository convention for it is the sibling `test_verify_pr_*.py` wiring
tests, whose shape this follows.
"""
import os
import re

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_VERIFY_PR = os.path.join(_ROOT, "scripts", "verify-pr.sh")
_WORKFLOWS = os.path.join(_ROOT, ".github", "workflows")

_SCRIPT = "lint-test-quality.py"
# A mode is the first long flag after the script name on the same line.
_MODE_RE = re.compile(re.escape(_SCRIPT) + r"\s+(--[a-z-]+)")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _modes(text: str) -> set:
    # Comment lines are stripped first. Both files DISCUSS the other's modes in
    # prose, and a census that counts prose reports the wiring it was written to
    # detect: before this filter, the parity test passed on verify-pr.sh's
    # comment naming `--changed` while no invocation existed.
    code = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
    return set(_MODE_RE.findall("\n".join(code)))


def _ci_modes() -> set:
    found = set()
    for name in sorted(os.listdir(_WORKFLOWS)):
        if name.endswith((".yml", ".yaml")):
            found |= _modes(_read(os.path.join(_WORKFLOWS, name)))
    return found


def test_verify_pr_runs_every_lint_mode_ci_runs():
    ci = _ci_modes()
    assert ci, f"no {_SCRIPT} invocation found in .github/workflows"
    local = _modes(_read(_VERIFY_PR))
    missing = sorted(ci - local)
    assert not missing, (
        f"CI runs `{_SCRIPT} {' '.join(missing)}` and verify-pr.sh does not, so a "
        "clean local run cannot predict that CI leg. Either wire the mode in or "
        "have the leg say which rules it did not evaluate."
    )


def test_the_diff_scoped_gate_feeds_the_leg_verdict():
    # The STARVE-001 path signals by EXIT CODE, not by a line --per-file's grep
    # would match. Printing its output without reading the status would leave
    # the leg green on a finding — a check that cannot fail.
    src = _read(_VERIFY_PR)
    assert "STARVE_RC" in src, (
        "verify-pr.sh must capture the exit status of the diff-scoped gate; its "
        "findings are invisible to the --per-file grep"
    )
    deciding = [
        line.strip()
        for line in src.splitlines()
        if "STARVE_RC" in line and ("-eq 0" in line or "-ne 0" in line)
    ]
    assert deciding, (
        "the diff-scoped gate's status is captured but never decides the "
        "test_quality verdict"
    )


def test_the_leg_reports_a_starve_finding_as_a_failure():
    src = _read(_VERIFY_PR)
    fails = [
        line.strip()
        for line in src.splitlines()
        if 'record "test_quality" "fail"' in line and "STARVE" in line
    ]
    assert fails, (
        'no record "test_quality" "fail" line names STARVE, so a diff-scoped '
        "finding either passes or fails without saying what for"
    )


def test_each_failing_combination_reports_a_distinct_reason():
    # The leg has three ways to fail: per-file only, STARVE only, and both. A
    # revert collapsed the both-case into a message identical to the per-file
    # one, which reads as "STARVE-001 was clean" on a run where it fired. The
    # earlier assertions all passed through that, so the distinctness is pinned
    # here rather than inferred.
    src = _read(_VERIFY_PR)
    messages = [
        line.split('record "test_quality" "fail" ', 1)[1].strip()
        for line in src.splitlines()
        if 'record "test_quality" "fail"' in line
    ]
    assert len(messages) >= 3, (
        f"expected a distinct message per failing combination, found {len(messages)}"
    )
    duplicates = {m for m in messages if messages.count(m) > 1}
    assert not duplicates, (
        "two failing branches report the same reason, so the run cannot say "
        "which check fired:\n  " + "\n  ".join(sorted(duplicates))
    )

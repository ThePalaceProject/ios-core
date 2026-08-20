#!/usr/bin/env python3
"""Pytest for scripts/check-silent-success.py.

Three obligations, per CLAUDE.md's gate rules:

  * the VIOLATION path fires — including against the REAL pre-fix
    regression-area-worker.sh reconstructed from the current one by deleting its
    NO-COVERAGE guard, which is the defect-reintroduction proof;
  * the CLEAN path passes — the whole committed scan set comes back clean, so
    the gate cannot land as a blocker that fires on the tree it ships with;
  * the WIRING is asserted — a test here goes red if the CI step that invokes
    the detector is removed, because a detector nothing runs is indistinguishable
    from a detector that never fires.
"""
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-silent-success.py"
WORKER = REPO / "scripts" / "regression-area-worker.sh"
WORKFLOW = REPO / ".github" / "workflows" / "tooling-checks.yml"

_spec = importlib.util.spec_from_file_location("check_silent_success", SCRIPT)
css = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(css)


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args],
                          capture_output=True, text=True, cwd=str(REPO), timeout=60)


def _write(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return p


# --- the violating shape ---------------------------------------------------

VIOLATION = """#!/usr/bin/env bash
set -euo pipefail
pass_count=0
skip_count=0
for j in "$@"; do
  if [ -f "$j" ]; then
    pass_count=$((pass_count + 1))
  else
    skip_count=$((skip_count + 1))
  fi
done
echo "  passed:  $pass_count"
echo "  skipped: $skip_count"
exit 0
"""

GUARDED = VIOLATION.replace(
    'exit 0\n',
    'if [ "$pass_count" -eq 0 ]; then\n'
    '  echo "!!! NO COVERAGE"\n'
    '  exit 3\n'
    'fi\n'
    'exit 0\n')


def test_flags_counted_work_with_terminal_exit_zero(tmp_path):
    rc = _run(str(_write(tmp_path, "bad.sh", VIOLATION)))
    assert rc.returncode == 1, rc.stdout + rc.stderr
    assert "no zero-work guard" in rc.stdout
    assert "pass_count" in rc.stdout


def test_zero_guard_that_exits_nonzero_clears_it(tmp_path):
    rc = _run(str(_write(tmp_path, "good.sh", GUARDED)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_guard_that_only_warns_does_not_clear_it(tmp_path):
    """A guard is a guard because it changes the EXIT VALUE.

    Printing a warning and exiting 0 is the original defect wearing a hat: the
    per-shard log genuinely said `[SKIP]` 96 times and the shard still exited 0.
    """
    warn_only = VIOLATION.replace(
        'exit 0\n',
        'if [ "$pass_count" -eq 0 ]; then\n'
        '  echo "warning: nothing ran"\n'
        'fi\n'
        'exit 0\n')
    rc = _run(str(_write(tmp_path, "warn.sh", warn_only)))
    assert rc.returncode == 1, rc.stdout + rc.stderr


def test_falling_off_the_end_counts_as_exit_zero(tmp_path):
    rc = _run(str(_write(tmp_path, "fallthrough.sh", VIOLATION.replace("exit 0\n", ""))))
    assert rc.returncode == 1, rc.stdout + rc.stderr


def test_die_helper_in_the_guard_counts_as_non_zero(tmp_path):
    with_die = VIOLATION.replace(
        'exit 0\n',
        'if [ "$pass_count" -eq 0 ]; then\n'
        '  die "no coverage"\n'
        'fi\n'
        'exit 0\n')
    rc = _run(str(_write(tmp_path, "die.sh", with_die)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


# --- deliberate non-findings (false-positive guards) -----------------------

def test_internal_counter_that_is_never_printed_is_not_flagged(tmp_path):
    silent = VIOLATION.replace('echo "  passed:  $pass_count"\n', "") \
                      .replace('echo "  skipped: $skip_count"\n', "")
    rc = _run(str(_write(tmp_path, "internal.sh", silent)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_findings_counter_alone_does_not_demand_a_guard(tmp_path):
    """A real pass legitimately finds nothing.

    Gating on a FINDINGS count would block clean runs — the discriminator has to
    be executed work. Encoded so nobody re-derives it from a red board.
    """
    findings_only = """#!/usr/bin/env bash
finding_count=0
for j in "$@"; do finding_count=$((finding_count + 1)); done
echo "  findings: $finding_count"
exit 0
"""
    rc = _run(str(_write(tmp_path, "findings.sh", findings_only)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_help_early_exit_zero_is_not_what_we_key_on(tmp_path):
    """A `--help` early `exit 0` must neither satisfy nor trip the check.

    The violating script gains a usage early-out; it is STILL flagged, and the
    reported line is the terminal exit, not the help one.
    """
    with_help = VIOLATION.replace(
        'pass_count=0\n',
        'case "${1:-}" in -h|--help) echo usage; exit 0 ;; esac\npass_count=0\n')
    rc = _run(str(_write(tmp_path, "help.sh", with_help)))
    assert rc.returncode == 1, rc.stdout + rc.stderr
    reported = int(re.search(r"help\.sh:(\d+):", rc.stdout).group(1))
    help_line = with_help.splitlines().index(
        'case "${1:-}" in -h|--help) echo usage; exit 0 ;; esac') + 1
    assert reported > help_line, "reported the --help exit, not the terminal one"

    # And with the terminal exit guarded, the surviving --help exit 0 is fine.
    guarded_help = with_help[:with_help.rindex("exit 0")] + (
        'if [ "$pass_count" -eq 0 ]; then exit 3; fi\nexit 0\n')
    ok = _run(str(_write(tmp_path, "help_ok.sh", guarded_help)))
    assert ok.returncode == 0, ok.stdout + ok.stderr


def test_counter_mentioned_only_in_a_comment_is_not_a_counter(tmp_path):
    """A detector that reads comments reports the DISCUSSION as the defect."""
    commented = """#!/usr/bin/env bash
# We used to keep a pass_count here and `echo "passed: $pass_count"` then exit 0.
echo "done"
exit 0
"""
    rc = _run(str(_write(tmp_path, "comment.sh", commented)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_heredoc_body_is_not_read_as_shell(tmp_path):
    embedded = """#!/usr/bin/env bash
python3 - <<'PY'
row_count = 0
print(f"rows: {row_count}")
PY
echo "done"
exit 0
"""
    rc = _run(str(_write(tmp_path, "heredoc.sh", embedded)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


# --- defect reintroduction against the REAL script -------------------------

_GUARD_BLOCK = re.compile(
    r"\nif \[\[ \$pass_count -eq 0 && \$fail_count -eq 0 && \$skip_count -gt 0 \]\]; then"
    r".*?\n  exit 3\nfi\n", re.DOTALL)


def test_real_worker_is_clean_but_flagged_once_its_guard_is_removed(tmp_path):
    """Remove the guard from the shipping script; the detector must go RED.

    A green detector is not evidence that it bites. This deletes the actual
    NO-COVERAGE block from the actual regression-area-worker.sh and asserts the
    reconstructed pre-fix script is caught — the same shape that let 21 shards
    report a clean pass on 0 executed journeys.
    """
    original = WORKER.read_text(encoding="utf-8")
    assert _GUARD_BLOCK.search(original), (
        "the NO-COVERAGE guard this test reintroduces the defect against has "
        "moved or changed shape — update this test with it")

    clean = _run(str(WORKER))
    assert clean.returncode == 0, clean.stdout + clean.stderr

    neutered = _GUARD_BLOCK.sub("\n", original)
    assert neutered != original
    rc = _run(str(_write(tmp_path, "regression-area-worker.sh", neutered)))
    assert rc.returncode == 1, (
        "detector did NOT flag the pre-fix worker — it does not bite:\n"
        + rc.stdout + rc.stderr)
    assert "pass_count" in rc.stdout


# --- clean path: the whole committed scan set ------------------------------

def test_default_scan_set_is_clean():
    """False-positive check. A gate that fires on the tree it ships with gets
    reverted the first time it fires in anger."""
    rc = _run("--default-set")
    assert rc.returncode == 0, (
        "the committed harness scan set is NOT clean:\n" + rc.stdout + rc.stderr)


def test_default_scan_set_is_not_vacuous():
    """...and it is clean because it is GUARDED, not because it is empty.

    Without this, deleting every counter in the harness would read as a pass.
    """
    scanned = css.resolve_default_set()
    assert scanned, "the default scan set resolved to nothing"
    worker = [p for p in scanned if p.endswith("regression-area-worker.sh")]
    assert worker, "regression-area-worker.sh is not in the scan set"
    lines = css._strip_heredocs(Path(worker[0]).read_text(encoding="utf-8"))
    info = css._analyse(lines)
    assert info["summarised"], "no summarised counters found — detector is inert here"
    assert any(css._guard_exits_nonzero(lines, i) for i, _ in info["guards"]), \
        "no zero-work guard found in the worker — clean verdict would be vacuous"


# --- wiring ---------------------------------------------------------------

def test_detector_is_wired_into_ci():
    """RED if someone removes the CI step.

    `pytest scripts/tests/` is a directory glob, so THIS file auto-discovers.
    A detector script does not: it needs its own workflow step, and nothing else
    in the repo would notice its absence.
    """
    assert WORKFLOW.is_file()
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "check-silent-success.py" in text, (
        "check-silent-success.py is not invoked by .github/workflows/"
        "tooling-checks.yml — an unwired detector never fires")
    assert "--default-set" in text, (
        "the CI step must run the detector over its scan set")


def test_fails_closed_with_a_named_diagnosis(tmp_path):
    rc = _run(str(_write(tmp_path, "bad.sh", VIOLATION)))
    assert rc.returncode != 0
    assert "regression-area-worker.sh" in rc.stdout, \
        "the finding must name the reference fix, not just complain"


def test_usage_error_when_given_a_missing_file(tmp_path):
    rc = _run(str(tmp_path / "nope.sh"))
    assert rc.returncode == 1
    assert "could not read" in rc.stdout


@pytest.mark.parametrize("name,expected", [
    ("pass_count", True), ("PASS_COUNT", True), ("skip_counter", True),
    ("DRY_RUN", False), ("total", False), ("countdown", False),
])
def test_counter_name_predicate(name, expected):
    assert bool(css.COUNTER_NAME.match(name)) is expected

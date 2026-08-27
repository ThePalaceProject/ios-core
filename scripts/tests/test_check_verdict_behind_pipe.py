"""Tests for check-verdict-behind-pipe.py.

The gate's whole value is that it fires on a real defect and stays silent on the
idioms that merely resemble one. A detector that never fires is indistinguishable
from a detector that is broken — so every "does not flag" case here is paired
with a "does flag" case that differs by one property, and the pairs are what make
a green run mean something.

The violating fixtures are not invented. `POSITIVE_ORCHESTRATOR` is the exact
idiom this gate found in tools/palace-test-orchestrator/lib/unit-runner.sh. Be
precise about what it was: LATENT, not live. Those libs are only sourced from
bin/palace-test, which sets `set -euo pipefail`, so the inherited option made
the capture correct under the real entry point. The defect was the dependency on
inheriting it — a lib that stops being correct the moment anything else sources
it. The fixtures below deliberately carry no pipefail, which is what makes them
violations and is exactly why testing the idiom that way misled the first
write-up into calling it live.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DETECTOR = REPO_ROOT / "scripts" / "check-verdict-behind-pipe.py"


def run_detector(*paths: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DETECTOR), *[str(p) for p in paths]],
        capture_output=True, text=True, cwd=REPO_ROOT,
    )


def write_script(tmp_path: Path, body: str, name: str = "s.sh") -> Path:
    path = tmp_path / name
    path.write_text("#!/bin/bash\n" + body)
    return path


# --------------------------------------------------------------- it must fire

POSITIVE_ORCHESTRATOR = """
run_tests() {
  local exit_code=0
  xcodebuild test -scheme Palace \\
    2>&1 | tee "$log_path" || exit_code=$?
  return $exit_code
}
"""

POSITIVE_STATUS_AFTER_PIPE = """
xcodebuild build | tee build.log
rc=$?
"""

POSITIVE_ECHO_EATS_STATUS = """
run_the_build
echo "build finished"
if [ $? -ne 0 ]; then exit 1; fi
"""


@pytest.mark.parametrize("body,label", [
    (POSITIVE_ORCHESTRATOR, "the orchestrator idiom, unprotected"),
    (POSITIVE_STATUS_AFTER_PIPE, "$? on the line after an unprotected pipeline"),
    (POSITIVE_ECHO_EATS_STATUS, "a trailing echo overwriting the status"),
])
def test_flags_a_verdict_read_from_the_wrong_command(tmp_path, body, label):
    result = run_detector(write_script(tmp_path, body))
    assert result.returncode == 1, f"did not flag {label}:\n{result.stdout}{result.stderr}"


def test_the_orchestrator_idiom_really_does_lose_the_status(tmp_path):
    """The defect is real, not just pattern-matched — WITHOUT pipefail.

    Without this, the gate could be flagging a harmless idiom and every other
    test here would still pass. Note the scope carefully: this proves the idiom
    loses the status when pipefail is absent. It does NOT prove anything about a
    caller that sets pipefail, where the same idiom is correct. Conflating those
    two is what produced a false "live defect" claim about the orchestrator.
    """
    script = tmp_path / "prove.sh"
    script.write_text(
        "#!/bin/bash\n"
        "old() { local ec=0; ( exit 65 ) | tee /dev/null || ec=$?; echo \"old=$ec\"; }\n"
        "new() { local ec=0; ( exit 65 ) | tee /dev/null; ec=${PIPESTATUS[0]}; echo \"new=$ec\"; }\n"
        "old; new\n"
    )
    out = subprocess.run(["bash", str(script)], capture_output=True, text=True).stdout
    assert "old=0" in out, "the idiom under test did not actually lose the status"
    assert "new=65" in out, "PIPESTATUS did not recover the status"


# ---------------------------------------------------------- it must stay quiet

NEGATIVE_PIPEFAIL = """
set -euo pipefail
xcodebuild test | tee log.txt || exit_code=$?
"""

NEGATIVE_ECHO_FEEDS_THE_WORK = """
OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
EXIT=$?
"""

NEGATIVE_GREP_IS_THE_QUESTION = """
if ps aux | grep -q simulator; then echo running; fi
"""

NEGATIVE_EXPLICIT_DISCARD = """
CHANGED=$(git diff --name-only | { grep -v '/Tests/' || true; })
"""

NEGATIVE_STATUS_DISCARDED = """
xcodebuild test | tee build.log
echo "done"
"""

NEGATIVE_SAME_LINE_COMMAND = """
echo "checking"
"$DET" "$TMP/t.diff" >/dev/null 2>&1; rc=$?
"""

NEGATIVE_EMBEDDED_JQ = """
jq -n '
  def prPara:
    if ($pr | length) > 0 then
      [ { type: "text" } ]
    else [] end;
  prPara
'
"""

NEGATIVE_STATUS_IN_PROSE = """
echo "  Known bug pattern: OUT=\\$(cmd || true); EXIT=\\$?"
"""


@pytest.mark.parametrize("body,label", [
    (NEGATIVE_PIPEFAIL, "pipefail makes the pipeline status honest"),
    (NEGATIVE_ECHO_FEEDS_THE_WORK, "echo feeds the work; the work is last"),
    (NEGATIVE_GREP_IS_THE_QUESTION, "grep's own status IS the question"),
    (NEGATIVE_EXPLICIT_DISCARD, "|| true inside a brace group is a discard"),
    (NEGATIVE_STATUS_DISCARDED, "a status nobody reads claims nothing"),
    (NEGATIVE_SAME_LINE_COMMAND, "$? belongs to the command on its own line"),
    (NEGATIVE_EMBEDDED_JQ, "a jq pipe in a multi-line string is not a shell pipe"),
    (NEGATIVE_STATUS_IN_PROSE, "$? inside an echoed string is documentation"),
])
def test_does_not_flag_correct_or_merely_similar_idioms(tmp_path, body, label):
    result = run_detector(write_script(tmp_path, body))
    assert result.returncode == 0, (
        f"false positive on {label}:\n{result.stdout}{result.stderr}")


# ------------------------------------------------------------------- interface

def test_explicit_file_argument_is_honoured(tmp_path):
    """Wiring check: a scan-only detector called with a file list must work.

    CLAUDE.md records that wiring bugs of exactly this shape — a detector
    invoked with an interface it silently rejects — are invisible to a fixture
    that only ever stages a violation, because the detector "passes" by doing
    nothing at all.
    """
    clean = write_script(tmp_path, NEGATIVE_PIPEFAIL, "clean.sh")
    dirty = write_script(tmp_path, POSITIVE_ORCHESTRATOR, "dirty.sh")

    assert run_detector(clean).returncode == 0
    assert run_detector(dirty).returncode == 1
    # And both together must still fail — one clean file cannot mask the other.
    assert run_detector(clean, dirty).returncode == 1


def test_non_shell_files_are_ignored(tmp_path):
    swift = tmp_path / "NotShell.swift"
    swift.write_text('let x = a | b\nlet y = "$?"\n')
    assert run_detector(swift).returncode == 0

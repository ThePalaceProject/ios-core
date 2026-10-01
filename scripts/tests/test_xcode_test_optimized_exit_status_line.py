"""The pass summary lines in `scripts/xcode-test-optimized.sh`.

They printed a check mark next to any exit code, so an xcodebuild abort read
"✅ Parallel tests executed on: iPhone 16 Pro (exit code: 134)" (PRs #1562 and
#1565). The helper is lifted from the real script and run, so the test cannot
drift from what ships; the last test checks no summary line bypasses it.
"""

import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "xcode-test-optimized.sh"


def _helper() -> str:
    text = SCRIPT.read_text()
    start = text.index("exit_status_line() {")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def _line(label: str, code: str) -> str:
    out = subprocess.run(["bash", "-c", _helper() + f'exit_status_line "{label}" "{code}"'],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def test_a_zero_exit_gets_a_check_mark():
    assert _line("Parallel tests executed", "0") == "✅ Parallel tests executed (exit code: 0)"


@pytest.mark.parametrize("code", ["134", "65", "1"])
def test_a_non_zero_exit_reads_as_a_failure(code):
    line = _line("Parallel tests executed", code)
    assert "✅" not in line
    assert line.startswith("🔴") and f"exit code: {code}" in line


def test_no_summary_line_prints_an_exit_code_next_to_a_bare_check_mark():
    outside_helper = SCRIPT.read_text().replace(_helper(), "")
    offenders = [l for l in outside_helper.splitlines()
                 if re.search(r'echo "✅.*exit code', l)]
    assert offenders == []

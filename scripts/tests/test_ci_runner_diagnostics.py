"""Tests for scripts/ci-runner-diagnostics.py — runner stall vs code hang, in one line.

prior-art-checked: follows the scripts/tests/ pytest convention for a new script.

The spindump fixture below keeps the lines the summary reads from the real
spindump XCTest attached to the allowance kill of
TPPBookRegistryLargeCorpusTests.testRoundTrip_5000Books_AllFieldsPreserved in
run 36769109335 (header, process headers, lck_rw_sleep frames, the
VM_compressor thread), trimmed from 8 MB to what the parser needs.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-runner-diagnostics.py"
spec = importlib.util.spec_from_file_location("ci_runner_diagnostics", SCRIPT)
diag = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = diag  # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(diag)

STALL = """\
Date/Time:        2026-09-30 20:32:08.682 +0000
Reason:           Requested by testmanagerd [40128] - XCTest Diagnostics
Duration:         5.00s
Duration Sampled: 1.91s (event ends 3.09s after samples)
Hardware model:   VirtualMac2,1
Active cpus:      3
Memory size:      7 GB

Process:          Palace [33715]
  Thread 0x1    187 samples (1-187)    priority 46
  *187  lck_rw_sleep + 132 (kernel.release.vmapple + 472400) [0xfffffe0007def550]

Process:          xpcproxy_sim [32513]
               *187  lck_rw_sleep + 132 (kernel.release.vmapple + 472400) [0xfffffe0007def550]
               *12   lck_rw_sleep + 132 (kernel.release.vmapple + 472400) [0xfffffe0007def550]

Process:          SpringBoard [32540]
  Thread 0x2    187 samples (1-187)    priority 31
  *187  mach_msg2_trap + 8 (libsystem_kernel.dylib + 3212) [0x1ec6b0c8c]

Process:          kernel_task [0]
  Thread 0x1b5    Thread name "VM_compressor"    187 samples (1-187)    priority 91 (base 91)    cpu time 1.300s
"""

IDLE = STALL.replace("lck_rw_sleep", "mach_msg2_trap").replace("cpu time 1.300s", "cpu time 0.010s")


def test_a_memory_stall_is_called_one():
    s = diag.summarize_spindump(STALL)
    assert s.blocked_processes == ["Palace [33715]", "xpcproxy_sim [32513]"]
    assert s.compressor_share == 1.3 / 1.91
    line = s.line("T/test()")
    assert "2 process(es) in lck_rw_sleep" in line
    assert "VM_compressor BUSY" in line and "3 cpus, 7 GB" in line
    assert line.endswith("runner memory stall likely")


def test_a_quiet_host_points_back_at_the_test():
    line = diag.summarize_spindump(IDLE).line("T/test()")
    assert "0 process(es) in lck_rw_sleep" in line
    assert "VM_compressor idle" in line
    assert "look at the test's own stack" in line


def test_page_faults_without_a_busy_compressor_are_not_called_a_memory_stall():
    text = STALL.replace("cpu time 1.300s", "cpu time 0.010s")
    assert "runner memory stall likely" not in diag.summarize_spindump(text).line("x")


def test_a_spindump_without_the_compressor_thread_says_so():
    text = STALL.replace('Thread name "VM_compressor"', 'Thread name "other"')
    assert "VM_compressor not sampled" in diag.summarize_spindump(text).line("x")


SAMPLES = """\
=== sample 10:00:00
System-wide memory free percentage: 41%
vm.swapusage: total = 2048.00M  used = 100.50M  free = 1947.50M  (encrypted)
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages occupied by compressor:            1000.
=== sample 10:00:15
System-wide memory free percentage: 12%
vm.swapusage: total = 3072.00M  used = 1.25G  free = 1792.00M  (encrypted)
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages occupied by compressor:            64000.
"""


def test_memory_summary_reports_the_worst_moment():
    s = diag.summarize_samples(SAMPLES)
    assert s == {"samples": 2, "min_free_pct": 12, "peak_swap_mb": 1280.0,
                 "peak_compressor_mb": 1000.0}
    assert diag.memory_line(s) == ("runner memory over 2 sample(s): lowest free 12%, peak swap "
                                   "used 1280.0 MB, peak compressor 1000.0 MB")


def test_memory_summary_of_nothing_says_nothing_was_measured():
    s = diag.summarize_samples("")
    assert s["samples"] == 0
    assert "n/a" in diag.memory_line(s)


def test_cli_reads_an_attachments_export(tmp_path):
    (tmp_path / "abc.txt").write_text(STALL)
    (tmp_path / "shot.png").write_bytes(b"\x89PNG")
    (tmp_path / "manifest.json").write_text(json.dumps([
        {"testIdentifier": "LargeCorpusTests/testRoundTrip()", "attachments": [
            {"exportedFileName": "abc.txt",
             "suggestedHumanReadableName": "2026-09-30 203208 +0000-Spindump_0_A5F6.txt"},
            {"exportedFileName": "shot.png", "suggestedHumanReadableName": "Screenshot.png"}]}]))
    r = subprocess.run([sys.executable, str(SCRIPT), "spindump-summary", "--attachments", str(tmp_path)],
                       capture_output=True, text=True)
    assert r.returncode == 0
    assert r.stdout.startswith("LargeCorpusTests/testRoundTrip(): 2 process(es) in lck_rw_sleep")
    assert r.stdout.count("\n") == 1


def test_cli_with_no_spindumps_says_so_and_does_not_fail(tmp_path):
    r = subprocess.run([sys.executable, str(SCRIPT), "spindump-summary", "--attachments", str(tmp_path)],
                       capture_output=True, text=True)
    assert r.returncode == 0 and "no spindumps" in r.stdout

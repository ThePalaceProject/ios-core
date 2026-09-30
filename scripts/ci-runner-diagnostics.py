#!/usr/bin/env python3
"""Tell a runner stall from a code hang without downloading the xcresult.

When XCTest kills a test at its execution-time allowance it attaches a
spindump of the whole host, and that spindump usually answers the only
question that matters first: was THIS test stuck, or was the machine? The
2026-09 hang census found the second: the 3-CPU / 7 GB macOS runner under
memory pressure, the compressor and swap active, and 11-35 processes parked
in the kernel's `lck_rw_sleep` on page faults — the simulator's own
`xpcproxy_sim` among them. Reading that took downloading a ~200 MB artifact
and opening an 8 MB text file. This prints it as one line in the job log.

prior-art-checked: ci-test-history.py labels kills from the log but cannot see
host state; nothing in scripts/ reads a spindump or samples runner memory.

    ci-runner-diagnostics.py sample <file> [--interval S]    append samples until killed
    ci-runner-diagnostics.py memory-summary <file>           peak pressure over the samples
    ci-runner-diagnostics.py spindump-summary <file>...      one line per spindump

Diagnostics only: every subcommand exits 0 on input it can read, whatever it
finds. A missing or unreadable file is reported, not fatal.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# The share of the sampled window the VM_compressor thread spent on CPU above
# which the compressor is called busy. On an idle runner it is ~0; in the
# census spindump it was 1.30 s of 1.91 s (68%).
COMPRESSOR_BUSY_SHARE = 0.25

SAMPLE_MARK = "=== sample "


# --------------------------------------------------------------------------
# Spindump
# --------------------------------------------------------------------------

@dataclass
class SpindumpSummary:
    blocked_processes: list[str]
    compressor_cpu: float | None
    sampled: float | None
    memory: str | None
    cpus: str | None

    @property
    def compressor_share(self) -> float | None:
        if self.compressor_cpu is None or not self.sampled:
            return None
        return self.compressor_cpu / self.sampled

    def line(self, name: str) -> str:
        share = self.compressor_share
        if share is None:
            comp = "VM_compressor not sampled"
        else:
            state = "BUSY" if share >= COMPRESSOR_BUSY_SHARE else "idle"
            comp = (f"VM_compressor {state} ({self.compressor_cpu:.2f}s cpu of "
                    f"{self.sampled:.2f}s sampled, {share:.0%})")
        verdict = ("runner memory stall likely" if self.blocked_processes and share is not None
                   and share >= COMPRESSOR_BUSY_SHARE else
                   "no host-wide stall signature; look at the test's own stack")
        host = f"{self.cpus or '?'} cpus, {self.memory or '?'}"
        return (f"{name}: {len(self.blocked_processes)} process(es) in lck_rw_sleep; {comp}; "
                f"{host} -> {verdict}")


_PROCESS = re.compile(r"^Process:\s+(.+?)\s*$")
_COMPRESSOR = re.compile(r'Thread name "VM_compressor".*?cpu time ([\d.]+)s')
_SAMPLED = re.compile(r"^Duration Sampled:\s+([\d.]+)s")
_MEMORY = re.compile(r"^Memory size:\s+(.+?)\s*$")
_CPUS = re.compile(r"^Active cpus:\s+(\d+)")


def summarize_spindump(text: str) -> SpindumpSummary:
    blocked: list[str] = []
    current = None
    compressor = sampled = None
    memory = cpus = None
    for line in text.splitlines():
        m = _PROCESS.match(line)
        if m:
            current = m.group(1)
            continue
        if "lck_rw_sleep" in line and current and current not in blocked:
            blocked.append(current)
        if compressor is None and (m := _COMPRESSOR.search(line)):
            compressor = float(m.group(1))
        if sampled is None and (m := _SAMPLED.match(line)):
            sampled = float(m.group(1))
        if memory is None and (m := _MEMORY.match(line)):
            memory = m.group(1)
        if cpus is None and (m := _CPUS.match(line)):
            cpus = m.group(1)
    return SpindumpSummary(blocked, compressor, sampled, memory, cpus)


# --------------------------------------------------------------------------
# Memory samples
# --------------------------------------------------------------------------

_FREE_PCT = re.compile(r"System-wide memory free percentage:\s*(\d+)%")
_SWAP_USED = re.compile(r"vm\.swapusage:.*?used = ([\d.]+)([MG])")
_PAGE_SIZE = re.compile(r"page size of (\d+) bytes")
_COMPRESSED = re.compile(r'"?Pages occupied by compressor"?:\s+(\d+)')


def _mb(value: str, unit: str) -> float:
    return float(value) * (1024.0 if unit == "G" else 1.0)


def summarize_samples(text: str) -> dict:
    """-> {"samples", "min_free_pct", "peak_swap_mb", "peak_compressor_mb"}."""
    chunks = [c for c in text.split(SAMPLE_MARK) if c.strip()]
    free, swap, comp = [], [], []
    for c in chunks:
        if m := _FREE_PCT.search(c):
            free.append(int(m.group(1)))
        if m := _SWAP_USED.search(c):
            swap.append(_mb(m.group(1), m.group(2)))
        page = _PAGE_SIZE.search(c)
        if page and (m := _COMPRESSED.search(c)):
            comp.append(int(m.group(1)) * int(page.group(1)) / (1024 * 1024))
    return {
        "samples": len(chunks),
        "min_free_pct": min(free) if free else None,
        "peak_swap_mb": round(max(swap), 1) if swap else None,
        "peak_compressor_mb": round(max(comp), 1) if comp else None,
    }


def memory_line(summary: dict) -> str:
    def fmt(v, unit):
        return "n/a" if v is None else f"{v}{unit}"
    return (f"runner memory over {summary['samples']} sample(s): lowest free "
            f"{fmt(summary['min_free_pct'], '%')}, peak swap used "
            f"{fmt(summary['peak_swap_mb'], ' MB')}, peak compressor "
            f"{fmt(summary['peak_compressor_mb'], ' MB')}")


def _snapshot() -> str:
    out = [SAMPLE_MARK + time.strftime("%H:%M:%S")]
    for cmd in (["memory_pressure", "-Q"], ["sysctl", "vm.swapusage"], ["vm_stat"]):
        try:
            out.append(subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout)
        except (OSError, subprocess.SubprocessError) as exc:
            out.append(f"{cmd[0]}: {exc}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("file")
    s.add_argument("--interval", type=float, default=15.0)
    s.add_argument("--once", action="store_true")
    m = sub.add_parser("memory-summary")
    m.add_argument("file")
    d = sub.add_parser("spindump-summary")
    d.add_argument("files", nargs="*")
    d.add_argument("--attachments", help="directory from `xcresulttool export attachments`; "
                   "its spindumps are summarized under the test they were attached to")
    args = ap.parse_args(argv[1:])

    if args.cmd == "sample":
        while True:
            with open(args.file, "a", encoding="utf-8") as fh:
                fh.write(_snapshot())
            if args.once:
                return 0
            time.sleep(args.interval)
    if args.cmd == "memory-summary":
        try:
            text = Path(args.file).read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"runner memory: no samples ({exc})")
            return 0
        print(memory_line(summarize_samples(text)))
        return 0
    targets = [(Path(f), Path(f).name) for f in args.files]
    if args.attachments:
        targets += spindumps_in(Path(args.attachments))
    if not targets:
        print("no spindumps attached to a failure")
    for path, label in targets:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"{label}: unreadable ({exc})")
            continue
        print(summarize_spindump(text).line(label))
    return 0


def spindumps_in(directory: Path) -> list[tuple[Path, str]]:
    """-> [(file, test identifier)] for each spindump in an attachments export."""
    import json
    try:
        manifest = json.loads((directory / "manifest.json").read_text())
    except (OSError, ValueError):
        return []
    out = []
    for entry in manifest:
        for a in entry.get("attachments", []):
            if "spindump" in str(a.get("suggestedHumanReadableName", "")).lower():
                out.append((directory / a["exportedFileName"], entry.get("testIdentifier", "?")))
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv))

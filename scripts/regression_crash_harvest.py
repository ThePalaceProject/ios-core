#!/usr/bin/env python3
"""regression_crash_harvest.py — harvest + classify macOS crash reports for the
iPad-on-Mac (C-ipad-on-mac) regression cell, with first-class detection of the
WS-4 Adobe RMSDK `recursive_mutex`-at-exit signature.

Context (docs/architecture/ws4-mac-validation-runbook.md): the "Designed for
iPad" build run natively on Apple Silicon (`isiOSAppOnMac == true`) crashed at
process exit in Adobe RMSDK's C++ static `recursive_mutex` destructor (294
Crashlytics events, issue 9a91840677). PR #1067 installs `atexit { _exit(0) }`
at `applicationDidEnterBackground` so the process exits before that destructor
runs. This module is the automated detector that decides, from the crash reports
a run leaves behind, whether that remediation HELD (no signature → PASS) or
REGRESSED (signature present → FAIL).

The crash-report scan + WS-4 classification is pure and deterministic; it is the
unit-tested core. The orchestration (build / launch / drive the app) lives in
scripts/regression-ipad-on-mac.sh.

Crash reports: `~/Library/Logs/DiagnosticReports/*.ips` (modern JSON format).
Each .ips is a one-line JSON header followed by a JSON payload; we classify on
the raw text so the detector is robust to schema drift.

Findings: conforms to the pinned regression_findings schema (FINDINGS_COLUMNS).
On the pinned module's absence (isolated worktree) we fall back to an inline
writer that emits the identical CSV — so this is integration-ready AND
self-contained.

Usage:
  regression_crash_harvest.py --process Palace --since <epoch> \
      --device-cell C-ipad-on-mac --area audiobook-drm-exit \
      --run-dir .regression-runs/<id> [--reports-dir <dir>] \
      [--first-seen-commit <sha>] [--json]

Exit code:
  0  — scan ran; NO WS-4 signature found (PASS — remediation holds)
  1  — at least one WS-4 signature found (FAIL — regression; finding emitted)
  2  — config error
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional

DEFAULT_REPORTS_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")

# The WS-4 signature set (ws4-mac-validation-runbook.md CHECK 2 assertions).
# A crash matching ANY of these, in a report for our process, is the regression.
WS4_SIGNATURES = [
    # The literal fault the static-destructor bug produces.
    re.compile(r"recursive_mutex lock failed", re.I),
    re.compile(r"recursive_mutex", re.I),
    # The Crashlytics issue id for this crash family.
    re.compile(r"9a91840677", re.I),
]

# Adobe / RMSDK frame markers — a SIGABRT/EXC_CRASH carrying one of these in a
# stack frame is the same family even if the literal "recursive_mutex" string
# was elided. Used only to upgrade an abort that also names Adobe.
ADOBE_FRAME_MARKERS = [
    re.compile(r"\bdp::", ),
    re.compile(r"librmsdk", re.I),
    re.compile(r"\badept\b", re.I),
    re.compile(r"NYPLADEPT", ),
    re.compile(r"RMServices", re.I),
]

ABORT_MARKERS = [
    re.compile(r"EXC_CRASH \(SIGABRT\)", re.I),
    re.compile(r"\bSIGABRT\b"),
    re.compile(r"EXC_BAD_ACCESS", re.I),
]


def _process_name_of(text: str) -> str:
    """Best-effort extract the crashed process name from an .ips report."""
    # Modern .ips header is the first line: {"app_name":"Palace", "procName":...}
    first = text.lstrip().split("\n", 1)[0]
    try:
        hdr = json.loads(first)
        for key in ("procName", "app_name", "process", "bundleID", "coalitionName"):
            if hdr.get(key):
                return str(hdr[key])
    except (json.JSONDecodeError, AttributeError):
        pass
    m = re.search(r'"procName"\s*:\s*"([^"]+)"', text)
    if m:
        return m.group(1)
    m = re.search(r"^Process:\s+([^\[\s]+)", text, re.M)  # legacy .crash format
    return m.group(1) if m else ""


def classify_crash_text(text: str) -> dict:
    """Pure classifier. Returns whether the crash text is the WS-4 signature and
    which markers matched. No I/O."""
    matched = [sig.pattern for sig in WS4_SIGNATURES if sig.search(text)]
    is_ws4 = bool(matched)

    # Upgrade path: an abort that also names an Adobe/RMSDK frame is the same
    # family even without the literal mutex string.
    if not is_ws4:
        has_abort = any(m.search(text) for m in ABORT_MARKERS)
        has_adobe = any(m.search(text) for m in ADOBE_FRAME_MARKERS)
        if has_abort and has_adobe:
            is_ws4 = True
            matched = ["abort+adobe-frame"]

    exc = ""
    m = re.search(r'"exceptionType"\s*:\s*"([^"]+)"', text) or \
        re.search(r"Exception Type:\s+(\S+)", text)
    if m:
        exc = m.group(1)

    return {
        "is_ws4": is_ws4,
        "matched_signatures": matched,
        "exception_type": exc,
    }


def harvest(process: str, since_epoch: float, reports_dir: str) -> list[dict]:
    """Scan reports_dir for crash reports newer than since_epoch whose process
    matches `process`. Returns a parsed classification per matching report."""
    d = Path(reports_dir)
    if not d.is_dir():
        return []
    out = []
    for path in sorted(d.glob("*.ips")) + sorted(d.glob("*.crash")):
        try:
            if path.stat().st_mtime < since_epoch:
                continue
            text = path.read_text(errors="replace")
        except OSError:
            continue
        proc = _process_name_of(text)
        # Match the target process by case-insensitive substring (covers
        # "Palace", "Palace-noDRM", bundle ids).
        if process.lower() not in proc.lower() and process.lower() not in text[:2000].lower():
            continue
        cls = classify_crash_text(text)
        out.append({
            "path": str(path),
            "process": proc,
            "mtime": path.stat().st_mtime,
            **cls,
        })
    return out


def _emit_findings(run_dir: str, device_cell: str, area: str,
                   crashes: list[dict], first_seen_commit: str,
                   scan_log: Optional[str]) -> Optional[str]:
    """Write one finding per WS-4 crash into this cell's own shard, conforming to
    the pinned regression_findings schema. Returns the shard path, or None when
    there is nothing to emit."""
    ws4 = [c for c in crashes if c["is_ws4"]]
    if not ws4:
        return None

    shard = Path(run_dir) / "findings" / f"{device_cell}__{area}.csv"
    rows = []
    for i, c in enumerate(ws4):
        evidence = [c["path"]]
        if scan_log:
            evidence.append(scan_log)
        rows.append({
            "id": f"{device_cell}-ws4-{i+1}",
            "area": area,
            "device_cell": device_cell,
            "severity": "blocker",  # the WS-4 crash family is a release blocker
            "classification": "device-divergence",
            "verified": "false",
            "evidence_paths": ";".join(evidence),
            "screenshot_pair": "",
            "first_seen_commit": first_seen_commit,
            "dedup_cluster": "ws4-adobe-recursive-mutex",
            "disposition": "",
        })

    # Prefer the pinned module; fall back to an inline writer (identical CSV).
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import regression_findings as rf  # type: ignore
        rf.append_findings(str(shard), rows)
    except Exception:
        _inline_append(shard, rows)
    return str(shard)


_COLUMNS = [
    "id", "area", "device_cell", "severity", "classification", "verified",
    "evidence_paths", "screenshot_pair", "first_seen_commit", "dedup_cluster",
    "disposition",
]


def _inline_append(shard: Path, rows: list[dict]) -> None:
    import csv
    shard.parent.mkdir(parents=True, exist_ok=True)
    new = not shard.exists() or shard.stat().st_size == 0
    with shard.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=_COLUMNS)
        if new:
            w.writeheader()
        for row in rows:
            w.writerow({c: row.get(c, "") for c in _COLUMNS})


def main() -> int:
    ap = argparse.ArgumentParser(description="iPad-on-Mac crash harvest (WS-4)")
    ap.add_argument("--process", default="Palace")
    ap.add_argument("--since", type=float, required=True,
                    help="epoch seconds; only reports newer than this are scanned")
    ap.add_argument("--device-cell", default="C-ipad-on-mac")
    ap.add_argument("--area", default="audiobook-drm-exit")
    ap.add_argument("--run-dir", default=".regression-runs/adhoc")
    ap.add_argument("--reports-dir", default=DEFAULT_REPORTS_DIR)
    ap.add_argument("--first-seen-commit", default="")
    ap.add_argument("--scan-log", default="", help="path to the run's scan log (evidence)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    crashes = harvest(args.process, args.since, args.reports_dir)
    ws4 = [c for c in crashes if c["is_ws4"]]
    shard = _emit_findings(
        args.run_dir, args.device_cell, args.area, crashes,
        args.first_seen_commit, args.scan_log or None,
    )

    result = {
        "device_cell": args.device_cell,
        "area": args.area,
        "process": args.process,
        "scanned_since": args.since,
        "reports_matched": len(crashes),
        "ws4_signature_hits": len(ws4),
        "verdict": "FAIL" if ws4 else "PASS",
        "findings_shard": shard,
        "crashes": crashes,
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"=== iPad-on-Mac crash harvest ({args.device_cell}) ===")
        print(f"process={args.process}  reports_matched={len(crashes)}  "
              f"ws4_hits={len(ws4)}")
        for c in crashes:
            tag = "WS-4" if c["is_ws4"] else "----"
            print(f"  [{tag}] {Path(c['path']).name}  "
                  f"exc={c['exception_type'] or '?'}  "
                  f"sig={','.join(c['matched_signatures']) or '-'}")
        print(f"\nVERDICT: {result['verdict']}"
              + (f"  (finding → {shard})" if shard else "  (WS-4 remediation holds)"))

    return 1 if ws4 else 0


if __name__ == "__main__":
    sys.exit(main())

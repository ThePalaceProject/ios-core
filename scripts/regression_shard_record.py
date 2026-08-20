#!/usr/bin/env python3
"""Per-shard EXECUTION record for the fleet regression campaign.

WHY THIS EXISTS. ``findings.csv`` records what a campaign FOUND. Nothing
recorded what it RAN. Those are different questions, and conflating them is how
a campaign that executed nothing rendered as a clean regression: 21 shards, 96
journeys skipped, 0 executed, 0 findings — and a report whose only signal was
"no findings", which is exactly what a genuinely clean run also produces.

The discriminator is the count of EXECUTED UNITS (passed + failed). A real clean
run has a positive executed count and zero findings; a vacuous run has zero of
both. This module is the artifact that carries that number — plus the wall clock,
because 21 shards finishing in 25 seconds is impossible and the duration was
visible only in terminal scrollback at the time.

Layout: ``<run-dir>/shards/<device-cell>__<area>.json``, one file per shard, so
parallel workers never race (same concurrency design as the per-shard findings
CSVs).

    python3 scripts/regression_shard_record.py write \
        --run-dir .regression-runs/<id> --area auth --device-cell C-iphone-26 \
        --passed 4 --failed 1 --skipped 0 --findings 1 \
        --started-at 1755700000 [--ended-at 1755700123] [--exit-code 0]

Pure stdlib.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Dict, List, Optional

SHARDS_DIRNAME = "shards"

#: A shard whose executed units each took less than this many seconds did not
#: really drive a simulator — a simdrive journey replay cannot complete in under
#: a second. Surfaced as a flag in the report, not as a hard failure, because a
#: legitimately tiny shard is possible; the point is that the number is VISIBLE.
IMPLAUSIBLE_SECONDS_PER_UNIT = 2.0


def shards_dir(run_dir: str) -> str:
    return os.path.join(run_dir, SHARDS_DIRNAME)


def record_path(run_dir: str, device_cell: str, area: str) -> str:
    return os.path.join(shards_dir(run_dir), f"{device_cell}__{area}.json")


def write_record(
    run_dir: str,
    area: str,
    device_cell: str,
    passed: int,
    failed: int,
    skipped: int,
    findings: int = 0,
    started_at: Optional[float] = None,
    ended_at: Optional[float] = None,
    exit_code: int = 0,
    commit: str = "",
) -> str:
    """Write one shard's execution record; return its path."""
    ended = float(ended_at if ended_at is not None else time.time())
    started = float(started_at if started_at is not None else ended)
    rec = {
        "area": area,
        "device_cell": device_cell,
        "passed": int(passed),
        "failed": int(failed),
        "skipped": int(skipped),
        "findings": int(findings),
        "executed": int(passed) + int(failed),
        "started_at": started,
        "ended_at": ended,
        "elapsed_s": max(0.0, round(ended - started, 3)),
        "exit_code": int(exit_code),
        "commit": commit,
    }
    path = record_path(run_dir, device_cell, area)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return path


def load_records(shards_path: str) -> List[Dict]:
    """Every shard record under ``shards_path`` (sorted, malformed ones skipped)."""
    if not os.path.isdir(shards_path):
        return []
    out: List[Dict] = []
    for name in sorted(os.listdir(shards_path)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(shards_path, name), encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict):
            rec.setdefault("executed",
                           int(rec.get("passed", 0)) + int(rec.get("failed", 0)))
            out.append(rec)
    return out


def seconds_per_unit(rec: Dict) -> Optional[float]:
    executed = int(rec.get("executed", 0))
    if executed <= 0:
        return None
    return float(rec.get("elapsed_s", 0.0)) / executed


def is_implausibly_fast(rec: Dict) -> bool:
    spu = seconds_per_unit(rec)
    return spu is not None and spu < IMPLAUSIBLE_SECONDS_PER_UNIT


def execution_summary(records: List[Dict]) -> Dict:
    """Campaign-level rollup used for the report's verdict."""
    return {
        "shards": len(records),
        "executed": sum(int(r.get("executed", 0)) for r in records),
        "passed": sum(int(r.get("passed", 0)) for r in records),
        "failed": sum(int(r.get("failed", 0)) for r in records),
        "skipped": sum(int(r.get("skipped", 0)) for r in records),
        "elapsed_s": round(sum(float(r.get("elapsed_s", 0.0)) for r in records), 3),
        "implausible": [
            f"{r.get('device_cell', '?')}/{r.get('area', '?')}"
            for r in records if is_implausibly_fast(r)
        ],
    }


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("write", help="write one shard execution record")
    w.add_argument("--run-dir", required=True)
    w.add_argument("--area", required=True)
    w.add_argument("--device-cell", required=True)
    w.add_argument("--passed", type=int, default=0)
    w.add_argument("--failed", type=int, default=0)
    w.add_argument("--skipped", type=int, default=0)
    w.add_argument("--findings", type=int, default=0)
    w.add_argument("--started-at", type=float, default=None)
    w.add_argument("--ended-at", type=float, default=None)
    w.add_argument("--exit-code", type=int, default=0)
    w.add_argument("--commit", default="")

    s = sub.add_parser("summarize", help="print the campaign execution rollup")
    s.add_argument("--run-dir", required=True)

    args = ap.parse_args(argv)

    if args.cmd == "write":
        path = write_record(
            run_dir=args.run_dir, area=args.area, device_cell=args.device_cell,
            passed=args.passed, failed=args.failed, skipped=args.skipped,
            findings=args.findings, started_at=args.started_at,
            ended_at=args.ended_at, exit_code=args.exit_code, commit=args.commit,
        )
        print(f"shard record: {path}")
        return 0

    summary = execution_summary(load_records(shards_dir(args.run_dir)))
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

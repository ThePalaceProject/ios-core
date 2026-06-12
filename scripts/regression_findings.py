#!/usr/bin/env python3
"""
regression_findings.py — the single source of truth for the fleet regression
campaign's findings.csv I/O and the area-group manifest.

Per REGRESSION-BUILD-PLAN.md shared contracts, ALL stages (area-worker, chaos,
visual-diff, Fable-triage, report) read and write findings through THIS module
so there is exactly one schema implementation. Do not hand-roll a parallel CSV
writer elsewhere.

findings.csv schema (one row per raw finding) — FINDINGS_COLUMNS, order is the
contract:
    id, area, device_cell, severity, classification, verified, evidence_paths,
    screenshot_pair, first_seen_commit, dedup_cluster, disposition

  - classification ∈ FINDING_CLASSIFICATIONS
  - verified = "false" until the coordinator hermetic re-verify flips it true.
  - evidence_paths is ';'-joined; screenshot_pair is 'baseline|candidate'.

RATIFIED MODULE API (palace-pm, 2026-06-12 — pinned; other workstreams bind to
these exact signatures):
    FINDINGS_COLUMNS: list[str]
    append_findings(csv_path: str, rows: list[dict]) -> None
        Append schema-keyed dicts; create-with-header if missing; missing keys
        default to "". Plain writer — NO evidence enforcement here (that is a
        discovery-stage concern; see append_finding / the CLI --allow-no-evidence
        flag).
    read_findings(csv_path: str) -> list[dict]
    write_findings(csv_path: str, rows: list[dict]) -> None
        Full rewrite with header (triage upserts the master by id).

CONCURRENCY DESIGN (palace-pm-ratified): each area-worker appends to its OWN
shard `<run-dir>/findings/<cell>__<area>.csv` — never a shared findings.csv —
so append is race-free without locking. RC-CAMPAIGN merges the shards into the
`<run-dir>/findings.csv` master.

CLI (so shell scripts append without an inline python heredoc):
    regression_findings.py init-csv <csv>
    regression_findings.py append <csv> --id ... --area ... --device-cell ... \
        --classification crash --evidence 'a.log;b.crash' \
        [--severity ...] [--screenshot-pair 'base.png|cand.png'] \
        [--first-seen-commit abc] [--verified] [--allow-no-evidence]
    regression_findings.py journeys|chaos-seeds|matrix-ids <manifest> <area-group>
    regression_findings.py areas <manifest>
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# The BUILD-PLAN findings.csv schema — column order is the contract.
FINDINGS_COLUMNS = [
    "id",
    "area",
    "device_cell",
    "severity",
    "classification",
    "verified",
    "evidence_paths",
    "screenshot_pair",
    "first_seen_commit",
    "dedup_cluster",
    "disposition",
]
# Back-compat alias for internal callers that referenced the header by name.
FINDINGS_HEADER = FINDINGS_COLUMNS

# classification enum from the BUILD-PLAN shared contracts.
FINDING_CLASSIFICATIONS = {
    "unknown",
    "defer-flag",
    "keychain-auth-state",
    "alert-presentation",
    "build-staleness",
    "visual-parity",
    "device-divergence",
    "perf",
    "crash",
    "other",
}

# evidence_paths and screenshot_pair are multi-valued; we join with ';' (paths)
# and '|' (baseline|candidate) so a single CSV cell round-trips cleanly.
EVIDENCE_SEP = ";"
SCREENSHOT_SEP = "|"


# ── ratified module API ───────────────────────────────────────────────────────


def ensure_findings_header(csv_path: str | os.PathLike) -> None:
    """Create the CSV with the schema header if it does not yet exist.

    Idempotent: an existing non-empty file is left untouched.
    """
    path = Path(csv_path)
    if path.exists() and path.stat().st_size > 0:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        csv.writer(f).writerow(FINDINGS_COLUMNS)


def _normalize(row: dict) -> dict[str, str]:
    """Project a dict onto the schema columns; missing keys → ''. Extra keys are
    dropped (the schema is the contract)."""
    return {col: ("" if row.get(col) is None else str(row.get(col, ""))) for col in FINDINGS_COLUMNS}


def append_findings(csv_path: str, rows: list[dict]) -> None:
    """Append schema-keyed dict rows; create-with-header if missing.

    PINNED API. Plain append — no evidence enforcement (discovery stages enforce
    that before calling). Each worker targets its own shard path, so concurrent
    appends across workers never touch the same file.
    """
    if not rows:
        ensure_findings_header(csv_path)
        return
    ensure_findings_header(csv_path)
    with Path(csv_path).open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FINDINGS_COLUMNS)
        for row in rows:
            w.writerow(_normalize(row))


def read_findings(csv_path: str) -> list[dict]:
    """Read all rows back as dicts. PINNED API."""
    path = Path(csv_path)
    if not path.exists():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def write_findings(csv_path: str, rows: list[dict]) -> None:
    """Full rewrite with header (triage upserts the master by id). PINNED API."""
    path = Path(csv_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FINDINGS_COLUMNS)
        w.writeheader()
        for row in rows:
            w.writerow(_normalize(row))


# ── typed discovery helper (layered on the pinned API) ────────────────────────


@dataclass
class Finding:
    """One discovery-time finding.

    Discovery stages populate id/area/device_cell/classification/evidence and
    leave severity/dedup_cluster/disposition empty for the Fable-triage stage.
    """

    id: str
    area: str
    device_cell: str
    classification: str = "unknown"
    evidence_paths: list[str] = field(default_factory=list)
    screenshot_pair: tuple[str, str] | None = None
    severity: str = ""
    verified: bool = False
    first_seen_commit: str = ""
    dedup_cluster: str = ""
    disposition: str = ""

    def to_row(self) -> dict[str, str]:
        if self.classification not in FINDING_CLASSIFICATIONS:
            raise ValueError(
                f"classification {self.classification!r} not in "
                f"{sorted(FINDING_CLASSIFICATIONS)}"
            )
        sshot = ""
        if self.screenshot_pair is not None:
            base, cand = self.screenshot_pair
            sshot = f"{base}{SCREENSHOT_SEP}{cand}"
        return {
            "id": self.id,
            "area": self.area,
            "device_cell": self.device_cell,
            "severity": self.severity,
            "classification": self.classification,
            "verified": "true" if self.verified else "false",
            "evidence_paths": EVIDENCE_SEP.join(self.evidence_paths),
            "screenshot_pair": sshot,
            "first_seen_commit": self.first_seen_commit,
            "dedup_cluster": self.dedup_cluster,
            "disposition": self.disposition,
        }

    def has_evidence(self) -> bool:
        return bool(self.evidence_paths) or self.screenshot_pair is not None


def crashes_since(reports: list[dict], since_ts: float) -> list[dict]:
    """Filter simdrive crash reports to those that occurred at/after `since_ts`.

    simdrive's `diagnostics.list_crashes` returns dicts carrying a numeric
    `mtime` (crash-report file mtime). The area-worker already passes
    `since_ts=<run start>` to list_crashes, but applying this filter on top makes
    the run-scoping a pure, testable invariant: a crash that predates the run
    must NEVER yield a finding (the false-positive-crash class the architect
    review caught when the old code used a pre/post count delta). Reports with no
    usable `mtime` are kept (fail-open — better to surface than to silently drop
    a real crash).
    """
    out = []
    for r in reports:
        mtime = r.get("mtime") if isinstance(r, dict) else None
        if mtime is None or mtime >= since_ts:
            out.append(r)
    return out


def translate_chaos_row(
    row: dict,
    *,
    finding_id: str,
    area: str,
    device_cell: str,
    run_evidence: list[str],
    first_seen_commit: str = "",
) -> Finding | None:
    """Translate one legacy chaos findings.csv row into a campaign Finding.

    The chaos-qa corpus uses a different (wider) CSV schema; this maps it onto
    the campaign schema. Returns None for a blank-title row (the chaos CSV header
    is always present even with zero findings, and partial rows can appear).

    Mapping rules:
      - legacy `Classification` is kept iff it is in the campaign enum, else
        `other`; a row whose Title/Notes mention "crash" is forced to `crash`
        (high-confidence at discovery).
      - `Screenshot Baseline|Candidate` become the screenshot_pair if either is
        set.
      - `run_evidence` (the chaos run's findings.csv / logs / replays) is attached
        to every row so the anti-hallucination rule is satisfiable; a row with no
        run evidence AND no screenshot is still returned here, and the caller's
        append_finding rejects it (discard).
    """
    title = (row.get("Title") or "").strip()
    if not title:
        return None
    legacy = (row.get("Classification") or "").strip().lower()
    classification = legacy if legacy in FINDING_CLASSIFICATIONS else "other"
    if "crash" in title.lower() or "crash" in (row.get("Notes") or "").lower():
        classification = "crash"
    base = (row.get("Screenshot Baseline") or "").strip()
    cand = (row.get("Screenshot Candidate") or "").strip()
    sshot = (base, cand) if (base or cand) else None
    return Finding(
        id=finding_id,
        area=area,
        device_cell=device_cell,
        classification=classification,
        evidence_paths=list(run_evidence),
        screenshot_pair=sshot,
        severity=(row.get("Severity") or "").strip().lower(),
        first_seen_commit=first_seen_commit,
    )


def classify_replay(replay_result: dict) -> dict:
    """Classify a simdrive `recorder.replay()` return dict into a runner verdict.

    Enforces the anti-false-pass rule (the #1 integrity gate): a replay that
    executed **0 of its planned steps** (or fewer than planned), or that halted
    before running (`ok=False` / `halt_reason` set), is a FAILURE — never a
    pass. A halt at step 0 means the journey's recorded precondition (its
    `requires:` state contract) did not match the live app, so NOTHING was
    exercised; reporting that as PASS masks every regression behind it. This is
    the same class as the stale-bundle "0 tests executed = misconfiguration, not
    a pass" rule.

    simdrive 1.0.0b7 replay() returns:
      {ok, halted_at, halt_reason, steps_planned, steps: [step_result...], ...}
    where each step_result may carry `executed`, `error`, `drifted`. On a
    state-contract mismatch with halt_on_state_mismatch=True it returns
    `steps: []` (empty) with `steps_planned` still set and `halt_reason`
    populated — that is the exact shape that previously false-passed.

    Returns: {status, steps_planned, steps_executed, errored, drifted,
              halt_reason, reason} with status in {pass, fail, error}.
    """
    steps = replay_result.get("steps") or []
    planned = replay_result.get("steps_planned")
    if planned is None:
        planned = len(steps)
    step_dicts = [s for s in steps if isinstance(s, dict)]
    executed = sum(1 for s in step_dicts if s.get("executed"))
    # Compat: if no step result carries an `executed` flag at all, treat each
    # present result as executed (older/result shapes that omit the flag).
    if executed == 0 and step_dicts and not any("executed" in s for s in step_dicts):
        executed = len(step_dicts)
    errored = sum(1 for s in step_dicts if s.get("error"))
    drifted = sum(1 for s in step_dicts if s.get("drifted"))
    ok = replay_result.get("ok", True)
    halt_reason = replay_result.get("halt_reason") or ""

    verdict = {
        "steps_planned": planned,
        "steps_executed": executed,
        "errored": errored,
        "drifted": drifted,
        "halt_reason": halt_reason,
    }
    if planned == 0:
        verdict["status"] = "error"
        verdict["reason"] = "recording has 0 planned steps — misconfiguration, not a pass"
    elif ok is False or halt_reason:
        halted_at = replay_result.get("halted_at", "?")
        verdict["status"] = "fail"
        verdict["reason"] = (
            f"replay halted at step {halted_at}: {halt_reason or 'ok=false'} "
            f"(executed {executed}/{planned})"
        )
    elif executed < planned:
        verdict["status"] = "fail"
        verdict["reason"] = f"incomplete replay: executed {executed}/{planned} steps"
    elif errored > 0:
        verdict["status"] = "fail"
        verdict["reason"] = f"{errored}/{planned} step(s) errored"
    else:
        verdict["status"] = "pass"
        verdict["reason"] = f"executed {executed}/{planned} steps clean"
    return verdict


def strip_device_suffix(device: str) -> str:
    """Strip a trailing clone-suffix parenthetical from a sim device name.

    Fleet/pool sims are named `iPhone 16 Pro (pool-3)` / `(fleet-5)` — the
    parenthetical is a CoreSimulator clone tag, not a different device model.
    `iPhone 16 Pro (pool-3)` → `iPhone 16 Pro`.
    """
    import re
    return re.sub(r"\s*\([^)]*\)\s*$", "", device or "").strip()


def device_matches_modulo_suffix(expected: str, actual: str) -> bool:
    """True if two sim device names are the same model ignoring the clone suffix."""
    e, a = strip_device_suffix(expected), strip_device_suffix(actual)
    return bool(e) and e == a


def normalized_requires_device(recorded_device: str, current_device: str) -> str | None:
    """Return the device name a recording's `requires.sim.device` should be
    rewritten to so its literal contract check passes on the current sim — or
    None if no rewrite is needed/safe.

    CAMPAIGN-CRITICAL: `requires.sim.device` is matched LITERALLY, so a recording
    captured on a base `iPhone 16 Pro` halts on every fleet `(pool-N)/(fleet-N)`
    sim. The safe fix (vs bypassing the contract) is to rewrite the contract's
    device to the CURRENT sim name when they are the same model modulo the clone
    suffix, then replay with the FULL contract still enforced — so text_subset /
    version / foreground real mismatches still HALT→FAIL. Returns:
      - current_device  when recorded & current are the same model but differ
                        (the rewrite that makes the literal check pass);
      - None            when they already match, or are genuinely different
                        models (e.g. iPhone vs iPad — do NOT rewrite; a real
                        device-divergence must FAIL).
    """
    if not recorded_device or not current_device:
        return None
    if recorded_device == current_device:
        return None
    if device_matches_modulo_suffix(recorded_device, current_device):
        return current_device
    return None


def append_finding(
    csv_path: str | os.PathLike,
    finding: Finding,
    *,
    require_evidence: bool = True,
) -> None:
    """Append one typed Finding via the pinned writer.

    Enforces the anti-hallucination rule at the DISCOVERY layer (not in
    append_findings): a finding with neither an evidence path nor a screenshot
    pair is rejected with ValueError. Pass require_evidence=False for synthetic
    rows (tests).
    """
    if require_evidence and not finding.has_evidence():
        raise ValueError(
            f"finding {finding.id!r} has no evidence "
            "(evidence_paths + screenshot_pair both empty) — "
            "visible-only observations are discarded"
        )
    append_findings(str(csv_path), [finding.to_row()])


# ── manifest ──────────────────────────────────────────────────────────────────


def load_manifest(manifest_path: str | os.PathLike) -> dict[str, Any]:
    """Load the area-group manifest (stdlib json — NO pyyaml dependency, so the
    shared CI tooling-integrity job loads it cleanly). Keys beginning with '_'
    are documentation and ignored by the consumers."""
    import json

    with Path(manifest_path).open() as f:
        data = json.load(f)
    if not isinstance(data, dict) or "area_groups" not in data:
        raise ValueError(f"{manifest_path}: missing top-level 'area_groups'")
    return data


def _area(manifest: dict[str, Any], area_group: str) -> dict[str, Any]:
    groups = manifest.get("area_groups", {})
    if area_group not in groups:
        raise KeyError(
            f"area-group {area_group!r} not in manifest (have: {sorted(groups)})"
        )
    return groups[area_group] or {}


def area_group_names(manifest: dict[str, Any]) -> list[str]:
    return list((manifest.get("area_groups") or {}).keys())


def journeys_for_area(manifest: dict[str, Any], area_group: str) -> list[str]:
    return list(_area(manifest, area_group).get("journeys", []) or [])


def chaos_seeds_for_area(manifest: dict[str, Any], area_group: str) -> list[str]:
    return list(_area(manifest, area_group).get("chaos_seeds", []) or [])


def matrix_ids_for_area(manifest: dict[str, Any], area_group: str) -> list[str]:
    return list(_area(manifest, area_group).get("matrix_ids", []) or [])


# ── CLI ───────────────────────────────────────────────────────────────────────


def _cli(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="regression findings I/O + manifest")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init-csv", help="write the schema header if absent")
    p_init.add_argument("csv_path")

    p_app = sub.add_parser("append", help="append one finding row")
    p_app.add_argument("csv_path")
    p_app.add_argument("--id", required=True)
    p_app.add_argument("--area", required=True)
    p_app.add_argument("--device-cell", required=True)
    p_app.add_argument("--classification", default="unknown")
    p_app.add_argument("--severity", default="")
    p_app.add_argument("--evidence", default="", help="';'-joined evidence paths")
    p_app.add_argument("--screenshot-pair", default="", help="'baseline.png|candidate.png'")
    p_app.add_argument("--first-seen-commit", default="")
    p_app.add_argument("--dedup-cluster", default="")
    p_app.add_argument("--disposition", default="")
    p_app.add_argument("--verified", action="store_true")
    p_app.add_argument("--allow-no-evidence", action="store_true")

    for name in ("journeys", "chaos-seeds", "matrix-ids"):
        sp = sub.add_parser(name, help=f"print {name} for an area-group")
        sp.add_argument("manifest")
        sp.add_argument("area_group")

    p_areas = sub.add_parser("areas", help="list area-group names")
    p_areas.add_argument("manifest")

    args = p.parse_args(argv)

    if args.cmd == "init-csv":
        ensure_findings_header(args.csv_path)
        return 0

    if args.cmd == "append":
        evidence = [e for e in args.evidence.split(EVIDENCE_SEP) if e]
        sshot = None
        if args.screenshot_pair:
            base, _, cand = args.screenshot_pair.partition(SCREENSHOT_SEP)
            sshot = (base, cand)
        finding = Finding(
            id=args.id, area=args.area, device_cell=args.device_cell,
            classification=args.classification, evidence_paths=evidence,
            screenshot_pair=sshot, severity=args.severity, verified=args.verified,
            first_seen_commit=args.first_seen_commit,
            dedup_cluster=args.dedup_cluster, disposition=args.disposition,
        )
        try:
            append_finding(args.csv_path, finding, require_evidence=not args.allow_no_evidence)
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        return 0

    manifest = load_manifest(args.manifest)
    if args.cmd == "journeys":
        print("\n".join(journeys_for_area(manifest, args.area_group)))
    elif args.cmd == "chaos-seeds":
        print("\n".join(chaos_seeds_for_area(manifest, args.area_group)))
    elif args.cmd == "matrix-ids":
        print("\n".join(matrix_ids_for_area(manifest, args.area_group)))
    elif args.cmd == "areas":
        print("\n".join(area_group_names(manifest)))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))

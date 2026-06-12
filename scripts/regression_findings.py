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
    """Load the area-group manifest. Requires pyyaml (present in the toolchain)."""
    import yaml  # local import so non-manifest callers don't need it

    with Path(manifest_path).open() as f:
        data = yaml.safe_load(f)
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

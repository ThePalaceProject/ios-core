#!/usr/bin/env python3
"""Regression-rebuild campaign — Stage 4 (Fable-triage) harness.

Reads a campaign ``findings.csv`` (the shared contract schema, owned by
``scripts/regression_findings.py`` / RC-AREA) and writes back the four triage
fields the contract reserves for this stage:

    severity, classification, dedup_cluster, disposition

It does this in two layers:

1. A **deterministic pre-classifier** (this file) attributes every finding to the
   test-isolation pollution taxonomy + finding-type enum, computes dedup
   clusters by root-cause signature, assigns a severity, and assigns a
   disposition via the ``-test-iterations 3`` green@3/red@3 + ``verified``
   discriminator. This is the floor: it runs with zero model calls and is what
   the pytest suite pins.
2. A **Fable refinement bridge**. ``--emit-fable-input`` writes a per-finding
   JSON bundle for a ``model: fable`` subagent (see
   ``scripts/regression-fable-triage-agent.md``, symlinked into
   ``.claude/agents/`` locally); ``--apply-fable <json>``
   ingests that subagent's output and overrides the deterministic baseline where
   Fable provides a value. With no Fable output supplied, the deterministic
   classification stands — the stage never *requires* a model to produce a valid
   triaged CSV.

Contract schema (one row per raw finding)::

    id,area,device_cell,severity,classification,verified,evidence_paths,
    screenshot_pair,first_seen_commit,dedup_cluster,disposition

Enums (contract)::

    classification ∈ {unknown, defer-flag, keychain-auth-state,
                      alert-presentation, build-staleness, visual-parity,
                      device-divergence, perf, crash, other}
    severity       ∈ {blocker, major, minor, cosmetic}
    disposition    ∈ {file-jira, ticket-as-flake, drop, needs-verify}

Anti-hallucination rule (inherited from the chaos layer / BUILD-PLAN contract):
a finding with **no evidence at all** (no evidence_paths, no screenshot_pair, no
crash file) is dispositioned ``drop`` — visible-only observations do not count.

Usage::

    python3 scripts/regression-triage.py --csv .regression-runs/<run>/findings.csv
    python3 scripts/regression-triage.py --csv f.csv --emit-fable-input fable_in.json
    python3 scripts/regression-triage.py --csv f.csv --apply-fable fable_out.json
    python3 scripts/regression-triage.py --csv f.csv --dry-run   # print, don't write

Pure stdlib — plus ``scripts/regression_findings.py`` (RC-AREA's shared module,
the single source of truth for findings.csv I/O; we never hand-roll a parallel
CSV reader/writer).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

# The shared findings module owns the schema + CSV I/O (BUILD-PLAN contract).
# It sits next to this script in scripts/; put that dir on the path so the
# import resolves regardless of cwd / invocation (CLI, pytest, harness).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import regression_findings as rf  # noqa: E402

# ---------------------------------------------------------------------------
# Contract schema — sourced from the shared module, never re-declared here.
# ---------------------------------------------------------------------------

FIELDNAMES: List[str] = list(rf.FINDINGS_COLUMNS)
CLASSIFICATIONS = set(rf.FINDING_CLASSIFICATIONS)

# Pollution-taxonomy classes (test-isolation artifacts, not user-facing product
# bugs). These attribute to a *test* leak, so they route to flake-tickets unless
# they survive the CI iters-3 bar (red@3 = real board-reddener -> file-jira).
POLLUTION_CLASSES = {
    "defer-flag", "keychain-auth-state", "alert-presentation", "build-staleness",
}

# Real product-bug classes — a verified one files a Jira (a real regression).
PRODUCT_CLASSES = {
    "visual-parity", "device-divergence", "perf", "crash", "other",
}

SEVERITIES = {"blocker", "major", "minor", "cosmetic"}
DISPOSITIONS = {"file-jira", "ticket-as-flake", "drop", "needs-verify"}

# P0 critical-path area keywords (auth/borrow/return/download/DRM/audiobook).
# A real regression here is a blocker by default.
P0_AREA_RE = re.compile(
    r"auth|sign[\-\s]?in|sign[\-\s]?out|saml|oidc|borrow|return|hold|download|"
    r"drm|adobe|lcp|overdrive|findaway|fulfil|credential|reauth|audiobook",
    re.I,
)

# ---------------------------------------------------------------------------
# Signal extraction — scan every free-text field for taxonomy signatures.
# ---------------------------------------------------------------------------

_SPLIT_RE = re.compile(r"[;,\|\s]+")


def _row_blob(row: Dict[str, str]) -> str:
    """Concatenate every signal-bearing field into one lowercase blob."""
    parts = [
        row.get("area", ""), row.get("evidence_paths", ""),
        row.get("screenshot_pair", ""), row.get("id", ""),
    ]
    return " ".join(p for p in parts if p).lower()


def _has(blob: str, *needles: str) -> bool:
    return any(n in blob for n in needles)


def iters3_verdict(row: Dict[str, str]) -> Optional[str]:
    """Return 'green' / 'red' if the evidence encodes the iters-3 CI verdict.

    Convention: the area-worker stamps a token into evidence_paths, one of
    ``green@3`` / ``red@3`` / ``iters3=green`` / ``iters3=red``. A run that
    printed "Restarting after ... test timeout" is FAILED regardless of the final
    tally, so ``timeout@3`` / ``restart@3`` also read as red.
    """
    blob = _row_blob(row)
    if _has(blob, "red@3", "iters3=red", "timeout@3", "restart@3"):
        return "red"
    if _has(blob, "green@3", "iters3=green"):
        return "green"
    return None


def has_evidence(row: Dict[str, str]) -> bool:
    """Anti-hallucination floor: a real finding cites at least one artifact."""
    return bool(
        (row.get("evidence_paths") or "").strip()
        or (row.get("screenshot_pair") or "").strip()
    )


def _cells_for_signature(rows: List[Dict[str, str]], sig: Tuple[str, str]) -> set:
    return {
        (r.get("device_cell") or "").strip()
        for r in rows if _signature(r, r["classification"]) == sig
    }


# ---------------------------------------------------------------------------
# Layer 1a: classification (taxonomy attribution)
# ---------------------------------------------------------------------------

def classify(row: Dict[str, str]) -> str:
    """Attribute a raw finding to the contract taxonomy from its evidence.

    Order matters: crash/device-divergence first (strongest, user-facing), then
    the four pollution classes, then visual/perf, then a conservative fallback.
    An already-set non-``unknown`` classification is respected (trust the worker
    that emitted it) unless it is empty/unknown.
    """
    existing = (row.get("classification") or "").strip().lower()
    if existing and existing != "unknown" and existing in CLASSIFICATIONS:
        return existing

    blob = _row_blob(row)

    # Crash family. A crash that fires in only one device cell is a
    # device-divergence (the cross-cell collapse decides single-cell-ness later;
    # here we tag the divergence-flavoured crash families explicitly).
    crashy = _has(
        blob, ".crash", ".ips", "crashes/", "exc_bad", "sigabrt", "sigsegv",
        "signal ", "fatal", "_dispatch_semaphore", "task continuation misuse",
    )
    divergence = _has(
        blob, "recursive_mutex", "isiosapponmac", "ipad-on-mac", "ipad_on_mac",
        "_exit(0)", "static destructor", "at exit", "at-exit",
    )
    if divergence:
        return "device-divergence"
    if crashy:
        return "crash"

    # Pollution taxonomy (test-isolation artifacts).
    if _has(blob, "deferinitialloadcatalogs", "loadcatalogs", "pool starvation",
            "pool-starvation", "pool saturation", "idle-signout", "idle signout",
            "preloader timeout", "crawl"):
        return "defer-flag"
    if _has(blob, "keychain", "errsecmissingentitlement", "-34018",
            "credentialsstale", "credentials stale", "credential bleed",
            "auth-state-bleed", "auth state bleed"):
        return "keychain-auth-state"
    if _has(blob, "uialertcontroller", "cannot present", "present after",
            "alert-presentation", "alert presentation", "leaked alert",
            "modal stack"):
        return "alert-presentation"
    if _has(blob, "deriveddata", "derived-data", "derived_data", "stale build",
            "staleness", "resolvecallcount", "no adapters registered",
            "link failed", "relink"):
        return "build-staleness"

    # Visual parity (pixel diff / structural marks diff).
    if _has(blob, "visual-parity", "visual parity", "pixel", "ssim",
            "skeleton", "diffs/", "marks-diff", "screenshot", "snapshot"):
        return "visual-parity"

    # Perf.
    if _has(blob, "perf", "latency", "regressed by", "slower", "frame drop",
            "hang", "spinner"):
        return "perf"

    # We have evidence but no strong signal -> 'other' (a real, uncategorised
    # finding). No evidence at all -> stays 'unknown' (will be dropped).
    return "other" if has_evidence(row) else "unknown"


# ---------------------------------------------------------------------------
# Layer 1b: severity
# ---------------------------------------------------------------------------

def assign_severity(row: Dict[str, str], classification: str) -> str:
    """User-facing-impact severity. Pollution classes are graded by board impact
    (red@3 => operationally major), product crashes are blockers."""
    area_p0 = bool(P0_AREA_RE.search(row.get("area", "")))
    verdict = iters3_verdict(row)

    if classification in {"crash", "device-divergence"}:
        return "blocker"

    if classification in POLLUTION_CLASSES:
        # A pollution class that survives the CI retry bar reddens the board for
        # everyone -> operationally major; otherwise a tolerated flake -> minor.
        return "major" if verdict == "red" else "minor"

    if classification == "visual-parity":
        # An empty-skeleton on a main catalog lane (PP-4553) is a major parity
        # bug; off the critical path it's cosmetic.
        return "major" if area_p0 or _has(_row_blob(row), "lane", "catalog",
                                          "skeleton") else "cosmetic"

    if classification == "perf":
        return "major" if _has(_row_blob(row), "high", "blocker") else "minor"

    if classification == "other":
        return "major" if area_p0 else "minor"

    return "minor"


# ---------------------------------------------------------------------------
# Layer 1c: dedup clustering — collapse same-root across cells/areas
# ---------------------------------------------------------------------------

# Strong root tokens collapse a family across device cells AND areas (e.g. the
# Adobe recursive_mutex crash on every ipad-on-mac run is ONE cluster).
_ROOT_TOKENS = [
    "recursive_mutex", "_dispatch_semaphore", "task continuation misuse",
    "exc_bad_access", "errsecmissingentitlement", "deferinitialloadcatalogs",
    "uialertcontroller", "deriveddata", "isiosapponmac",
]


def _root_signal(row: Dict[str, str]) -> str:
    """A stable root key. Prefer a strong crash/symptom token (cell-independent);
    fall back to the normalised area so per-area visual findings still cluster."""
    blob = _row_blob(row)
    for tok in _ROOT_TOKENS:
        if tok in blob:
            return tok
    area = (row.get("area") or "").strip().lower()
    area = re.sub(r"[\s/]+", "-", area)
    return area or "unkeyed"


def _signature(row: Dict[str, str], classification: str) -> Tuple[str, str]:
    return (classification, _root_signal(row))


def assign_clusters(rows: List[Dict[str, str]]) -> Dict[Tuple[str, str], str]:
    """Assign a stable ``C-NNN`` cluster id per unique (classification, root)
    signature. Ids are deterministic (sorted by signature) regardless of row
    order so re-running triage is idempotent."""
    sigs = sorted({_signature(r, r["classification"]) for r in rows})
    return {sig: f"C-{i + 1:03d}" for i, sig in enumerate(sigs)}


# ---------------------------------------------------------------------------
# Layer 1d: disposition
# ---------------------------------------------------------------------------

def assign_disposition(row: Dict[str, str], classification: str) -> str:
    """Route the finding. Evidence-required; verified-required for filing."""
    if not has_evidence(row) or classification == "unknown":
        return "drop"  # anti-hallucination: no evidence => not a finding

    verified = (row.get("verified") or "").strip().lower() in {"true", "yes", "1"}
    verdict = iters3_verdict(row)

    if classification in POLLUTION_CLASSES:
        # red@3 = real board-reddener -> file it; green@3 (or unknown) = CI
        # tolerated flake -> track as a flake ticket, don't block the release.
        return "file-jira" if verdict == "red" else "ticket-as-flake"

    # Product-bug classes: a coordinator hermetic re-verify must confirm it
    # before it files. Unverified product findings wait at needs-verify.
    if not verified:
        return "needs-verify"
    return "file-jira"


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def triage_findings(rows: List[Dict[str, str]]) -> List[Dict[str, str]]:
    """Fill severity/classification/dedup_cluster/disposition on every row.
    Mutates and returns the rows (deterministic layer 1)."""
    for row in rows:
        row["classification"] = classify(row)
    cluster_ids = assign_clusters(rows)
    for row in rows:
        cls = row["classification"]
        row["severity"] = assign_severity(row, cls)
        row["dedup_cluster"] = cluster_ids[_signature(row, cls)]
        row["disposition"] = assign_disposition(row, cls)
    return rows


def build_fable_input(rows: List[Dict[str, str]]) -> Dict:
    """Per-finding bundle for the model:fable subagent to refine. Includes the
    deterministic baseline so Fable only overrides where it has higher-signal
    judgement (reading the actual evidence files)."""
    return {
        "schema": FIELDNAMES,
        "taxonomy": sorted(CLASSIFICATIONS),
        "severities": sorted(SEVERITIES),
        "dispositions": sorted(DISPOSITIONS),
        "findings": [
            {
                "id": r.get("id", ""),
                "area": r.get("area", ""),
                "device_cell": r.get("device_cell", ""),
                "evidence_paths": r.get("evidence_paths", ""),
                "screenshot_pair": r.get("screenshot_pair", ""),
                "verified": r.get("verified", ""),
                "deterministic_baseline": {
                    "classification": r.get("classification", ""),
                    "severity": r.get("severity", ""),
                    "dedup_cluster": r.get("dedup_cluster", ""),
                    "disposition": r.get("disposition", ""),
                },
            }
            for r in rows
        ],
    }


def apply_fable_output(rows: List[Dict[str, str]], fable: Dict) -> List[str]:
    """Override deterministic fields with Fable's per-id values. Returns the list
    of finding ids Fable changed. Validates enum membership — an out-of-enum
    Fable value is rejected (logged), never written."""
    by_id = {r.get("id", ""): r for r in rows}
    changed: List[str] = []
    for item in fable.get("findings", []):
        fid = item.get("id")
        row = by_id.get(fid)
        if row is None:
            continue
        touched = False
        for field, allowed in (
            ("classification", CLASSIFICATIONS),
            ("severity", SEVERITIES),
            ("disposition", DISPOSITIONS),
        ):
            val = item.get(field)
            if val is None:
                continue
            val = str(val).strip().lower()
            if val not in allowed:
                print(f"  [fable] rejected {fid}.{field}={val!r} (not in enum)",
                      file=sys.stderr)
                continue
            if row.get(field) != val:
                row[field] = val
                touched = True
        # dedup_cluster: Fable may merge clusters; accept any non-empty string.
        dc = item.get("dedup_cluster")
        if dc and str(dc).strip() and row.get("dedup_cluster") != str(dc).strip():
            row["dedup_cluster"] = str(dc).strip()
            touched = True
        if touched:
            changed.append(fid)
    return changed


# ---------------------------------------------------------------------------
# CSV I/O — delegated entirely to the shared regression_findings module.
# ---------------------------------------------------------------------------

def load_findings(csv_path: Path) -> List[Dict[str, str]]:
    """Read the master findings.csv via the shared module (single source of
    truth), normalising so every contract column exists for downstream code."""
    rows = list(rf.read_findings(str(csv_path)))
    for r in rows:
        for col in FIELDNAMES:
            r.setdefault(col, "")
    return rows


def write_findings(csv_path: Path, rows: List[Dict[str, str]]) -> None:
    """Write back via the shared module (full rewrite w/ header; upsert-by-id
    semantics live there per the pinned API)."""
    rf.write_findings(str(csv_path), rows)


def summarize(rows: List[Dict[str, str]]) -> str:
    by_cls: Dict[str, int] = {}
    by_disp: Dict[str, int] = {}
    clusters = set()
    for r in rows:
        by_cls[r["classification"]] = by_cls.get(r["classification"], 0) + 1
        by_disp[r["disposition"]] = by_disp.get(r["disposition"], 0) + 1
        clusters.add(r["dedup_cluster"])
    lines = [f"  {len(rows)} findings, {len(clusters)} dedup clusters"]
    lines.append("  classification: " + ", ".join(
        f"{k}={v}" for k, v in sorted(by_cls.items())))
    lines.append("  disposition:    " + ", ".join(
        f"{k}={v}" for k, v in sorted(by_disp.items())))
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Stage-4 Fable-triage harness.")
    ap.add_argument("--csv", required=True, type=Path, help="findings.csv path")
    ap.add_argument("--emit-fable-input", type=Path, metavar="JSON",
                    help="write the model:fable input bundle and exit")
    ap.add_argument("--apply-fable", type=Path, metavar="JSON",
                    help="ingest a model:fable output bundle after triage")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the summary; do not write the CSV back")
    args = ap.parse_args(argv)

    if not args.csv.exists():
        print(f"Error: findings CSV not found: {args.csv}", file=sys.stderr)
        return 2

    rows = load_findings(args.csv)
    if not rows:
        print("Error: 0 findings in CSV (a 0-row run is a misconfiguration, "
              "not a clean pass).", file=sys.stderr)
        return 3

    triage_findings(rows)

    if args.emit_fable_input:
        args.emit_fable_input.write_text(
            json.dumps(build_fable_input(rows), indent=2), encoding="utf-8")
        print(f"Wrote Fable input bundle: {args.emit_fable_input} "
              f"({len(rows)} findings)")
        return 0

    if args.apply_fable:
        fable = json.loads(args.apply_fable.read_text(encoding="utf-8"))
        changed = apply_fable_output(rows, fable)
        print(f"Applied Fable overrides to {len(changed)} findings: "
              f"{', '.join(changed) if changed else '(none)'}")

    print("Triage complete:")
    print(summarize(rows))

    if args.dry_run:
        print("(--dry-run: CSV not written)")
        return 0

    write_findings(args.csv, rows)
    print(f"Wrote triaged CSV: {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

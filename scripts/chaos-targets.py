#!/usr/bin/env python3
"""
chaos-targets.py — given a list of changed file paths, return the set of
fixture flow seeds whose `mutation_targets` cover those files.

This reverse-maps `.specterqa/fixtures/flows/*.yaml` → `mutation_targets[].file`
so chaos-qa can focus its exploration on flows whose assertions cover the
changed surface area. PR authors who add a new flow YAML automatically
extend chaos's reach.

Usage
-----
    # Print seed flows for a list of changed files (one per line on stdout):
    chaos-targets.py Palace/Accounts/Library/AccountsManager.swift Palace/SignInLogic/TPPSignInBusinessLogic.swift

    # Or pipe a git diff:
    git diff --name-only origin/develop...HEAD | xargs chaos-targets.py

    # JSON output for tooling:
    chaos-targets.py --json Palace/MyBooks/MyBooksDownloadCenter.swift

    # Just list every flow (no targeting):
    chaos-targets.py --all

Output
------
By default: one `<flow>/<step>` per line, where `<step>` is the FIRST step
of the flow that mentions the changed file in its mutation_targets, or
the flow's last step if the targets are flow-wide. Each flow appears at
most once.

If no flows match, exits 0 with no output (the empty corpus is a valid
result — it means chaos should fall back to `cold-launch`).

Why steps matter
----------------
The seed determines what Phase-1 state chaos will reproduce. Seeding
mid-flow puts chaos at a state transition (most bugs hide there). The
LAST step of a flow is the post-transition state, which is the most
informative seed for code that mutates on that transition.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def load_flow(yaml_path: Path) -> dict | None:
    """Tiny YAML loader — we only need name, steps[].id, mutation_targets[].file.
    Avoids a yaml-package dependency for CI portability.
    """
    text = yaml_path.read_text()
    flow: dict = {"path": str(yaml_path), "name": yaml_path.stem,
                  "steps": [], "mutation_targets": [], "status": "unknown"}

    # Top-level scalars.
    name_m = re.search(r"^name:\s*(\S+)", text, re.M)
    if name_m:
        flow["name"] = name_m.group(1).strip()
    status_m = re.search(r"^status:\s*(\S+)", text, re.M)
    if status_m:
        flow["status"] = status_m.group(1).strip()

    # Steps — each `- id: <step-id>` at any indent.
    flow["steps"] = re.findall(r"^\s*-\s*id:\s*([\w-]+)", text, re.M)

    # mutation_targets — each `- file: <path>` block under `mutation_targets:`.
    in_targets = False
    targets: list[str] = []
    for line in text.splitlines():
        stripped = line.rstrip()
        if re.match(r"^mutation_targets:\s*$", stripped):
            in_targets = True
            continue
        if in_targets:
            if re.match(r"^\S", stripped):  # next top-level key — section ended
                in_targets = False
                continue
            m = re.match(r"^\s*-\s*file:\s*(\S+)", stripped)
            if m:
                targets.append(m.group(1).strip())
    flow["mutation_targets"] = targets

    return flow


def find_flows(fixtures_root: Path) -> list[dict]:
    flows_dir = fixtures_root / "flows"
    if not flows_dir.exists():
        return []
    flows = []
    for yaml_path in sorted(flows_dir.glob("*.yaml")):
        f = load_flow(yaml_path)
        if f:
            flows.append(f)
    return flows


def normalize_path(p: str) -> str:
    return p.strip().lstrip("./")


def select_seeds(flows: list[dict], changed_files: list[str]) -> list[dict]:
    """Return [{flow, step, matched_files}, ...] for flows whose mutation_targets
    overlap the changed set. `step` defaults to the flow's last step (post-state).
    """
    changed_norm = {normalize_path(p) for p in changed_files}
    selected = []
    for flow in flows:
        targets = {normalize_path(t) for t in flow["mutation_targets"]}
        matched = changed_norm & targets
        if not matched:
            # Also match by directory prefix — a change to
            # Palace/Accounts/Library/* matches a target path of
            # Palace/Accounts/Library/AccountsManager.swift
            matched = {
                t for t in targets
                for c in changed_norm
                if c.startswith(t.rsplit("/", 1)[0] + "/")
            }
        if not matched:
            continue
        last_step = flow["steps"][-1] if flow["steps"] else None
        selected.append({
            "flow": flow["name"],
            "step": last_step,
            "seed": f"{flow['name']}/{last_step}" if last_step else flow["name"],
            "status": flow["status"],
            "matched_files": sorted(matched),
        })
    return selected


def main() -> int:
    p = argparse.ArgumentParser(description="Map changed files to chaos-qa seed fixtures.")
    p.add_argument("files", nargs="*", help="Changed file paths.")
    p.add_argument("--all", action="store_true", help="List every flow regardless of changed-file match.")
    p.add_argument("--fixtures-root", type=Path,
                   default=Path(".specterqa/fixtures"),
                   help="Path to .specterqa/fixtures/ (default: relative to cwd).")
    p.add_argument("--json", action="store_true", help="Output as JSON instead of one-seed-per-line.")
    p.add_argument("--include-pending", action="store_true",
                   help="Include flows with status=PENDING_CAPTURE (default: skip).")
    args = p.parse_args()

    flows = find_flows(args.fixtures_root)
    if not flows:
        print(f"warning: no flow YAMLs found at {args.fixtures_root}/flows/", file=sys.stderr)
        return 0

    if not args.include_pending:
        flows = [f for f in flows if f["status"] not in ("PENDING_CAPTURE",)]

    if args.all:
        selected = [{
            "flow": f["name"],
            "step": f["steps"][-1] if f["steps"] else None,
            "seed": f"{f['name']}/{f['steps'][-1]}" if f["steps"] else f["name"],
            "status": f["status"],
            "matched_files": [],
        } for f in flows]
    else:
        if not args.files:
            print("error: provide changed files or --all", file=sys.stderr)
            return 2
        selected = select_seeds(flows, args.files)

    if args.json:
        print(json.dumps(selected, indent=2))
    else:
        for s in selected:
            print(s["seed"])

    return 0 if selected else 0  # always 0; empty corpus is a valid result


if __name__ == "__main__":
    sys.exit(main())

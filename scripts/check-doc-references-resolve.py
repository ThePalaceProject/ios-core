#!/usr/bin/env python3
"""
check-doc-references-resolve.py — fail when a tracked doc names a script or
workflow that does not exist.

WHY THIS EXISTS. A maintainer-tooling extraction removed a pile of scripts and
workflows from this repository and left the documentation pointing at them. That
is not cosmetic: the coverage summary told every reviewer "the excluded paths are
covered by simdrive E2E journeys (see `chaos-replay-on-pr.yml`)" when that
workflow did not exist and nothing replayed a journey in CI. A reviewer was being
told the remainder was covered when it was covered by nothing.

Three separate reviewers blocked that change, and the author's own audit went
green twice while the defect was live — once because it scanned one file and the
claim was repo-wide, once because it was re-run against the branch it had already
left. A check that has to be remembered, aimed by hand, is the failure mode. This
one is mechanical, runs over every tracked doc, and fails closed.

BASELINE. A pre-existing backlog of dangling references is recorded in
`doc-references-baseline.json` next to this script. Those are tolerated so the
gate can land without a doc-rewrite marathon, but NOTHING NEW may be added — a
reference not in the baseline fails the run. Fixing a baselined entry and pruning
it from the file is always welcome; the gate verifies the baseline itself does
not go stale by failing on entries that now resolve.

Usage:
    check-doc-references-resolve.py                 # scan every tracked doc
    check-doc-references-resolve.py --update-baseline
    check-doc-references-resolve.py --root <path>   # for tests

Exit codes: 0 clean, 1 new dangling reference (or a stale baseline entry).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

BASELINE_NAME = "doc-references-baseline.json"

# `scripts/foo.py`, optionally prefixed by the maintainer-local harness root.
# The harness prefix means "deliberately not in this repo" and is never dangling.
SCRIPT_RE = re.compile(r"(?P<harness>~/harness/[A-Za-z0-9_./-]*?)?(?P<path>scripts/[A-Za-z0-9_.-]+\.(?:py|sh|rb))")
WORKFLOW_RE = re.compile(r"(?<![A-Za-z0-9_.-])(?P<wf>[A-Za-z0-9_-]+\.yml)")

# Directories whose contents are archival records of what was true at the time,
# not live instructions. Rewriting history to keep a linter quiet is worse than
# the dangling link.
SKIP_PREFIXES = (".forgeos/", ".claude/", "tools/ledger/vendor/")

# A .yml named in prose is only a workflow reference if it plausibly IS one; many
# docs mention unrelated yaml (manifests, configs) that live elsewhere.
NON_WORKFLOW_YML = {"qaatlas.yml", "codeatlas.yml", "manifest.yml", "docker-compose.yml"}


def tracked_docs(root: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", root, "ls-files", "*.md", "*.yml", "*.json"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    # The baseline records the very strings this detector looks for, so scanning
    # it would report every baselined entry a second time, attributed to the
    # baseline itself. (Caught by test_baselined_reference_is_tolerated, which
    # went red the moment the baseline became a tracked file.)
    skip_self = f"scripts/{BASELINE_NAME}"
    return [
        f for f in out
        if f and not f.startswith(SKIP_PREFIXES) and f != skip_self
    ]


def find_dangling(root: str) -> list[dict]:
    findings: list[dict] = []
    workflow_dir = os.path.join(root, ".github", "workflows")
    for rel in tracked_docs(root):
        full = os.path.join(root, rel)
        try:
            with open(full, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue

        for m in SCRIPT_RE.finditer(text):
            if m.group("harness"):
                continue  # maintainer-local by construction
            path = m.group("path")
            if not os.path.exists(os.path.join(root, path)):
                findings.append({"doc": rel, "kind": "script", "target": path})

        for m in WORKFLOW_RE.finditer(text):
            wf = m.group("wf")
            if wf in NON_WORKFLOW_YML:
                continue
            if not os.path.exists(os.path.join(workflow_dir, wf)):
                findings.append({"doc": rel, "kind": "workflow", "target": wf})

    # Stable, de-duplicated.
    seen, unique = set(), []
    for f in sorted(findings, key=lambda x: (x["doc"], x["kind"], x["target"])):
        key = (f["doc"], f["kind"], f["target"])
        if key not in seen:
            seen.add(key)
            unique.append(f)
    return unique


def load_baseline(root: str) -> list[dict]:
    path = os.path.join(root, "scripts", BASELINE_NAME)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return json.load(fh).get("known_dangling", [])


def key(f: dict) -> tuple:
    return (f["doc"], f["kind"], f["target"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    found = find_dangling(root)

    if args.update_baseline:
        out = os.path.join(root, "scripts", BASELINE_NAME)
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "_comment": (
                        "Pre-existing dangling doc references, tolerated so the gate could land. "
                        "Nothing new may be added. Fix an entry and delete its line — the gate "
                        "fails on baseline entries that now resolve, so this cannot go stale."
                    ),
                    "known_dangling": found,
                },
                fh, indent=2, sort_keys=True,
            )
            fh.write("\n")
        print(f"baseline written: {len(found)} known dangling reference(s)")
        return 0

    baseline = load_baseline(root)
    baseline_keys = {key(f) for f in baseline}
    found_keys = {key(f) for f in found}

    new = [f for f in found if key(f) not in baseline_keys]
    stale = [f for f in baseline if key(f) not in found_keys]

    if new:
        print("A tracked doc names a script or workflow that does not exist:\n")
        for f in new:
            print(f"  {f['doc']}  ->  {f['kind']} '{f['target']}' (missing)")
        print(
            "\nEither restore the target, correct the reference, or — if it moved to the\n"
            "maintainer-local harness — write it as ~/harness/... so it reads as\n"
            "deliberately-not-here rather than as a broken link."
        )
    if stale:
        print("\nBaseline entries that now resolve — delete them from "
              f"scripts/{BASELINE_NAME}:\n")
        for f in stale:
            print(f"  {f['doc']}  ->  {f['kind']} '{f['target']}'")

    if new or stale:
        return 1
    print(f"doc references resolve ({len(baseline)} baselined, 0 new)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

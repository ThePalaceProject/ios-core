#!/usr/bin/env python3
"""
Infer ForgeOS `modules_affected` from the current git diff.

Usage:
    scripts/forgeos-modules-from-diff.py                # working tree vs HEAD
    scripts/forgeos-modules-from-diff.py origin/develop # diff vs a base ref
    scripts/forgeos-modules-from-diff.py --staged       # staged-only
    scripts/forgeos-modules-from-diff.py --json         # raw JSON list
    scripts/forgeos-modules-from-diff.py --format args  # space-joined for shell

Mapping (Palace iOS):
    Palace/Packages/<SPM>/...        -> <SPM>           (SPM extractions)
    Palace/<Module>/...              -> <Module>        (top-level UIKit/SwiftUI modules)
    PalaceTests/<Module>/...         -> <Module>        (tests fold into their module)
    PalaceConfig/...                 -> config
    Palace.xcodeproj/...             -> project
    scripts/...                      -> tooling
    docs/...                         -> documentation
    .forgeos/...                     -> governance
    .claude/...                      -> tooling
    everything else                  -> (dropped)

Wires into:
    forge_session_end(modules_affected=[...])
    forge_propose_changeset(modules_affected=[...])

So `forge_get_context` can query SharedMind by domain on the changeset.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _git_diff_files(base_ref: str | None, staged: bool) -> list[str]:
    cmd = ["git", "-C", str(REPO_ROOT), "diff", "--name-only"]
    if staged:
        cmd.append("--cached")
    if base_ref:
        cmd.append(base_ref)
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(f"git diff failed: {out.stderr.strip()}\n")
        sys.exit(2)
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def _map_path(path: str) -> str | None:
    if path.startswith("Palace/Packages/"):
        rest = path[len("Palace/Packages/"):]
        return rest.split("/", 1)[0] or None
    if path.startswith("Palace/"):
        rest = path[len("Palace/"):]
        head = rest.split("/", 1)[0]
        # Strip files at the Palace/ root (e.g. Palace/Info.plist) — no module
        if "/" not in rest:
            return None
        # Skip localization buckets (e.g. en.lproj/, fr.lproj/)
        if head.endswith(".lproj"):
            return "localization"
        return head
    if path.startswith("PalaceTests/"):
        rest = path[len("PalaceTests/"):]
        head = rest.split("/", 1)[0]
        if "/" not in rest:
            return None
        return head
    if path.startswith("PalaceConfig/"):
        return "config"
    if path.startswith("Palace.xcodeproj/"):
        return "project"
    if path.startswith("scripts/"):
        return "tooling"
    if path.startswith("docs/"):
        return "documentation"
    if path.startswith(".forgeos/"):
        return "governance"
    if path.startswith(".claude/"):
        return "tooling"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("base_ref", nargs="?", default=None,
                        help="base ref for the diff (default: working-tree vs HEAD)")
    parser.add_argument("--staged", action="store_true",
                        help="diff only staged changes (overrides base_ref)")
    parser.add_argument("--format", choices=["json", "lines", "args"], default="json",
                        help="json (default), lines (one module per line), args (space-joined)")
    parser.add_argument("--include-files", action="store_true",
                        help="emit {modules, files_changed} object instead of bare list (json only)")
    args = parser.parse_args()

    files = _git_diff_files(args.base_ref, args.staged)
    modules: list[str] = []
    seen: set[str] = set()
    for f in files:
        mod = _map_path(f)
        if mod and mod not in seen:
            seen.add(mod)
            modules.append(mod)
    modules.sort()

    if args.format == "json":
        if args.include_files:
            print(json.dumps({"modules": modules, "files_changed": files}, indent=2))
        else:
            print(json.dumps(modules))
    elif args.format == "lines":
        for m in modules:
            print(m)
    else:  # args
        print(" ".join(modules))
    return 0


if __name__ == "__main__":
    sys.exit(main())

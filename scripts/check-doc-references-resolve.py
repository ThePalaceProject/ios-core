#!/usr/bin/env python3
"""
check-doc-references-resolve.py — fail when a tracked doc names a script,
workflow, or SOURCE FILE that does not exist.

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

THE SOURCE ARM. The same rot reaches source paths, and from a second direction:
the decomposition waves moved whole files into `Palace/Packages/*`, and the docs
kept pointing at `Palace/Book/Models/TPPBookRegistry.swift` long after it became
`Palace/Packages/PalaceBookRegistry/Sources/...`. A reader who follows one of
those lands nowhere, which is strictly worse than no pointer — a doc that names
a path is making a claim about the tree, and 37 of those claims were false when
this arm was added. Same baseline discipline: pre-existing entries tolerated,
nothing new.

Three things are NOT dangling and are exempt by construction rather than by
baseline, so the baseline keeps meaning "drift to fix":
  * an ellipsis path (`Palace/Reader2/.../LicensesService.swift`) — a deliberate
    abbreviation, not a claim about a real path;
  * a DELIBERATELY-UNTRACKED file (`APIKeys.swift`, `TPPSecrets.swift`) — the repo
    rule is that these are never committed, so absence is compliance;
  * a documented placeholder in a usage example (`Palace/Path/ChangedFile.swift`)
    — it is teaching the shape of a command, not naming a file.

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
# A .yml OR .yaml reference, with the same harness escape the script arm has.
# Matching only `.yml` left every `.yaml` reference invisible — including a pile
# of `.simdrive/journeys/*.yaml` paths that have not existed since the QA
# harness was extracted. A detector blind to half its own file extension reports
# clean for the wrong reason.
WORKFLOW_RE = re.compile(
    r"(?P<harness>~/harness/[A-Za-z0-9_./-]*?)?"
    r"(?P<dir>(?:[A-Za-z0-9_.-]+/)+)?"
    r"(?<![A-Za-z0-9_.-])(?P<wf>[A-Za-z0-9_-]+\.ya?ml)")

# A source path under one of the app's real top-level source roots. Bounded to
# those roots so prose like "the models/Book.swift pattern" is not scanned as a
# claim about this tree.
SOURCE_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])"
    r"(?P<path>(?:Palace|PalaceTests|PalaceUIKit|PalaceConfig)/"
    r"[A-Za-z0-9_./+-]+\.(?:swift|m|h|mm))")

# Never committed by repo rule (see CLAUDE.md "Secrets"). Absence is the rule
# working, not a broken reference.
DELIBERATELY_UNTRACKED = (
    "APIKeys.swift",
    "TPPSecrets.swift",
)

# Placeholders in usage examples. Literal, small, and reviewable on purpose — a
# heuristic ("skip anything under a segment called Path") would silently swallow
# a real directory someone adds later.
PLACEHOLDER_PATHS = frozenset({
    "Palace/Path.swift",
    "Palace/Path/Changed.swift",
    "Palace/Path/ChangedFile.swift",
    "Palace/SomeFile.swift",
    "Palace/Foo/Bar.swift",
    "PalaceTests/Foo/BarTests.swift",
})


# Directories whose contents are archival records of what was true at the time,
# not live instructions. Rewriting history to keep a linter quiet is worse than
# the dangling link.
# `.forgeos/` holds intent files and swarm transcripts — records of what was
# true at the time. Rewriting history to keep a linter quiet is worse than the
# dangling link. `.claude/` is NOT archival — skills and agents are live
# instructions — so it is scanned. (Verified against the real tree: unskipping
# adds zero findings.) `.claude/worktrees/` is excluded separately: those are
# sibling checkouts, not this repo's content.
SKIP_PREFIXES = (".forgeos/", ".claude/worktrees/", "tools/ledger/vendor/",
                 # Detector INPUT fixtures: deliberately-fake paths are the point.
                 "scripts/_fixtures/")

# A .yml named in prose is not necessarily a WORKFLOW: this repo also tracks
# dependabot.yml, orchestrator configs, and atlas manifests, none of which live
# under .github/workflows/. Resolving only against that directory reported all of
# them as dangling. So a yaml reference is satisfied by a file of that basename
# ANYWHERE in the tree, and only a name that exists nowhere is a finding.


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


def tracked_paths(root: str) -> set:
    """Every tracked path. Both arms resolve against this rather than the
    filesystem: an untracked local file satisfies a reference on the author's
    machine and not in CI, which is the same class of defect as a gate that
    passes only where it was written."""
    out = subprocess.run(
        ["git", "-C", root, "ls-files"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return {f for f in out if f}


def find_dangling(root: str) -> list[dict]:
    findings: list[dict] = []
    tracked = tracked_paths(root)
    yaml_basenames = {os.path.basename(f) for f in tracked
                      if f.endswith((".yml", ".yaml"))}
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
            if path not in tracked:
                findings.append({"doc": rel, "kind": "script", "target": path})

        for m in SOURCE_RE.finditer(text):
            path = m.group("path")
            if path in tracked:
                continue
            # "Palace/Reader2/.../Foo.swift" abbreviates a path rather than
            # naming one. Checked on the matched text, not the basename, so an
            # ellipsis anywhere in the path exempts it.
            if "..." in path:
                continue
            if path in PLACEHOLDER_PATHS:
                continue
            if path.endswith(DELIBERATELY_UNTRACKED):
                continue
            findings.append({"doc": rel, "kind": "source", "target": path})

        for m in WORKFLOW_RE.finditer(text):
            if m.group("harness"):
                continue  # maintainer-local by construction
            # A reference carrying a directory component names a SPECIFIC file
            # and must resolve as written: basename-only matching let
            # `.github/workflows/test-matrix.yml` pass because an unrelated
            # `test-matrix.yml` existed under tools/. Bare names still resolve by
            # basename, since prose usually names a workflow without its path.
            wf = m.group("wf")
            full = (m.group("dir") or "") + wf
            # NOT `.lstrip("./")` — lstrip takes a character SET, so it eats the
            # leading dot of `.github/` too and every workflow reference in the
            # repo reads as missing. Strip the prefix, not the characters.
            while full.startswith("./"):
                full = full[2:]
            # A URL names a file on a server, not a path in this checkout, so it
            # resolves by name. (`github.com/org/repo/actions/workflows/x.yml`.)
            looks_like_url = any(tok in (m.group("dir") or "")
                                 for tok in ("://", "github.com", "www."))
            if "/" in full and not looks_like_url:
                if full not in tracked:
                    findings.append({"doc": rel, "kind": "workflow", "target": full})
            elif wf not in yaml_basenames:
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
    ap.add_argument("--accept-new", action="store_true",
                    help="allow --update-baseline to ADD entries (it refuses by default)")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    found = find_dangling(root)

    if args.update_baseline:
        # Regenerating silently absorbs any NEW dangling reference, which would
        # make the gate self-defeating: the fix for a red run must never be to
        # re-run it with a flag. Report the delta so the change is visible in
        # the diff AND in the console, and require --accept-new to grow it.
        existing = {key(f) for f in load_baseline(root)}
        added = [f for f in found if key(f) not in existing]
        removed = [f for f in load_baseline(root) if key(f) not in {key(x) for x in found}]
        for f in added:
            print(f"  + {f['doc']} -> {f['kind']} '{f['target']}'")
        for f in removed:
            print(f"  - {f['doc']} -> {f['kind']} '{f['target']}' (now resolves)")
        if added and not args.accept_new:
            print(f"\nRefusing to grow the baseline by {len(added)} entry(ies).\n"
                  "Fix the reference, or pass --accept-new if it is genuinely "
                  "pre-existing and you intend to record it.")
            return 1
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
        print("A tracked doc names a script, workflow, or source file that does not exist:\n")
        for f in new:
            print(f"  {f['doc']}  ->  {f['kind']} '{f['target']}' (missing)")
        print(
            "\nEither restore the target, correct the reference, or — if it moved to the\n"
            "maintainer-local harness — write it as ~/harness/... so it reads as\n"
            "deliberately-not-here rather than as a broken link. For a source path that\n"
            "MOVED (the decomposition waves relocated files into Palace/Packages/*),\n"
            "repoint it; `git log --diff-filter=D --name-only -- <old path>` finds it."
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

#!/usr/bin/env python3
"""
check-doc-index-complete.py — fail when a doc in an indexed directory is not
named in that directory's index, or when the index names a doc that is gone.

WHY THIS EXISTS. `docs/architecture/README.md` is the entry point a human or an
agent is told to start from. On 2026-08-24 it described **6 of 53** documents.
The other 47 were reachable only by grepping the whole tree, which ranks a spent
plan exactly level with a maintained decision record and surfaces both alongside
10.9 MB of archived campaign transcripts.

That is the quiet failure mode of "write everything down": the corpus grows, the
map does not, and retrieval degrades until the useful documents are effectively
invisible. Nobody notices, because nothing is broken — a doc nobody finds costs
every future search while helping no one, and looks identical to a doc that does
not exist.

So the index is a build artifact of the directory, not a document someone
remembers to update. Add a doc, add its line. Delete a doc, delete its line.

Both directions are checked, because they fail differently: an unlisted doc is
invisible, and a listed-but-deleted doc sends a reader somewhere that is not
there — the same lie `check-doc-references-resolve.py` exists to stop, one level
up.

Usage:
    check-doc-index-complete.py                # check every indexed directory
    check-doc-index-complete.py --root <path>  # for tests
Exit codes: 0 clean, 1 an index is incomplete or stale.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

# directory -> the index that must name everything under it.
INDEXED = {
    "docs/architecture": "docs/architecture/README.md",
    ".forgeos/wall-failures": ".forgeos/wall-failures/INDEX.md",
}


def tracked_under(root: str, prefix: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", root, "ls-files", f"{prefix}/*.md"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return sorted(f for f in out if f)


def check_dir(root: str, prefix: str, index_rel: str) -> list[str]:
    problems: list[str] = []
    index_path = os.path.join(root, index_rel)
    if not os.path.exists(index_path):
        return [f"{index_rel} does not exist — {prefix}/ has no index."]
    with open(index_path, encoding="utf-8") as fh:
        index_text = fh.read()

    docs = [d for d in tracked_under(root, prefix) if d != index_rel]

    # Forward: every doc is named. Matching on the path RELATIVE to the index
    # directory, which is how a working markdown link is written — so a link
    # that satisfies this gate is also a link that resolves for a reader.
    index_dir = os.path.dirname(index_rel)
    for doc in docs:
        rel = os.path.relpath(doc, index_dir) if index_dir else doc
        if rel not in index_text:
            problems.append(f"{index_rel} does not name {doc}")

    # Reverse: every doc the index names still exists. Only paths that look like
    # links into this directory are checked; prose mentioning some other file is
    # the reference gate's business, not this one.
    tracked = set(tracked_under(root, prefix))
    for token in _link_targets(index_text):
        target = os.path.normpath(os.path.join(index_dir, token))
        if target.startswith(prefix + "/") and target not in tracked:
            problems.append(f"{index_rel} names {target}, which does not exist")
    return problems


def _link_targets(text: str) -> set:
    """Markdown link targets ending in .md, de-duplicated."""
    import re
    return {m.group(1) for m in re.finditer(r"\]\(([^)\s]+\.md)\)", text)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), ".."))
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    all_problems: list[str] = []
    for prefix, index_rel in sorted(INDEXED.items()):
        if not os.path.isdir(os.path.join(root, prefix)):
            continue  # directory not present in this checkout (e.g. a fixture)
        all_problems.extend(check_dir(root, prefix, index_rel))

    if all_problems:
        print("Documentation index is out of sync with the directory:\n")
        for p in all_problems:
            print(f"  {p}")
        print(
            "\nThe index is how anyone finds these documents — an unlisted doc is\n"
            "invisible, and a listed-but-missing one sends the reader nowhere.\n"
            "Add the line when you add the doc; delete it when you delete the doc."
        )
        return 1

    total = sum(len(tracked_under(root, p)) for p in INDEXED
                if os.path.isdir(os.path.join(root, p)))
    print(f"doc indexes complete ({total} indexed doc(s), 0 unlisted, 0 stale)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

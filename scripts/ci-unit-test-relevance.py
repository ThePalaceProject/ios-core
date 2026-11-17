#!/usr/bin/env python3
"""Decide whether a pull request's changes can affect the unit-test result.

The Unit Tests workflow costs ~50 macOS runner-minutes. A PR that changes only
a different workflow, tooling pytests, docs or agent metadata cannot change what
the Swift suite does, so the build and test jobs are skipped for it and the
`build-and-test` gate reports success. Everything else runs.

prior-art-checked: the workflow's `paths-ignore` covered only `**.md` and
`docs/**`, and a workflow-level ignore leaves a required check pending forever;
nothing else in scripts/ classifies changed paths.

The rule is deliberately one-sided. A path is SKIPPABLE only if it matches the
explicit list below; any path the list does not name makes the run happen. A
file this script has never heard of therefore runs the suite, which is the safe
direction: a wrong "run" costs minutes, a wrong "skip" lands an untested change.

scripts/ is the one directory that is partly each. A script the unit-test path
executes (the test runner, the DRM setup, the xcresult parsers, this file) is
relevant, so the relevant set is computed rather than listed: every scripts/
path named by the unit-test workflow, its composite actions or the Xcode
project, and, transitively, every scripts/ file named inside one of those. A
new script wired into the workflow becomes relevant without editing this file.

    python3 scripts/ci-unit-test-relevance.py [--changed FILE] [--github-output]

Reads changed paths one per line (FILE, or stdin). Prints `run=true|false` and
one reason line per path that forced a run. An empty list runs: no evidence of
what changed is not evidence that nothing did.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

WORKFLOW = ".github/workflows/unit-testing.yml"

# Paths that cannot change the unit-test result. fnmatch patterns against the
# repo-relative path; `*` matches across `/` here, so `docs/*` is the subtree.
SKIPPABLE = (
    "*.md",                 # prose anywhere; no .md is bundled or read by a test
    "docs/*",
    ".github/*",            # other workflows, templates, dependabot — see ALWAYS_RELEVANT
    "scripts/*",            # tooling — see relevant_scripts() for the exceptions
    ".claude/*", ".cursor/*", ".forgeos/*", ".regression/*", ".palace-state/*",
    ".simdrive/*",
    "tools/*",              # local orchestration helpers, not invoked by CI tests
    "fastlane/*", "Gemfile", "Gemfile.lock",   # release lanes; the test path does not use fastlane
    "LICENSE", "qaatlas.yml", "muter.conf.yml", ".jira-config.template",
)

# Relevant even though a SKIPPABLE pattern matches them.
ALWAYS_RELEVANT = (
    WORKFLOW,
    ".github/actions/*",
    # Not run by this workflow any more, but it is the local CI-parity runner
    # and mirrors the shard runner's flags; a change to it is usually a change
    # meant for CI too, and running costs less than guessing.
    "scripts/xcode-test-optimized.sh",
)

# Files whose scripts/ references define the relevant part of scripts/.
ROOTS = (
    WORKFLOW,
    ".github/actions",
    "Palace.xcodeproj/project.pbxproj",
    "Palace.xcodeproj/xcshareddata",
)

SCRIPT_REF = re.compile(r"scripts/[A-Za-z0-9_.\-/]+")
BARE_NAME = re.compile(r"[A-Za-z0-9_.\-]+\.(?:sh|py|rb|json|txt|yml|yaml|plist)\b")


def _read(path: Path) -> str:
    """File text without the lines that only mention a script (see _is_prose)."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return "\n".join(ln for ln in text.splitlines() if not _is_prose(ln))


# Lines that mention a script without running it: comments, and text the
# workflow prints into a summary or PR comment ("run scripts/verify-pr.sh
# locally"). Following those pulled verify-pr.sh, and through it most of
# scripts/, into the relevant set.
_PROSE = re.compile(r"^\s*(#|//|\*)|\becho\b|\bprintf\b|\bbody \+=")


def _is_prose(line: str) -> bool:
    return bool(_PROSE.search(line))


def _root_files(repo: Path) -> list[Path]:
    out = []
    for r in ROOTS:
        p = repo / r
        if p.is_dir():
            out.extend(sorted(x for x in p.rglob("*") if x.is_file()))
        elif p.is_file():
            out.append(p)
    return out


def relevant_scripts(repo: Path = REPO) -> set[str]:
    """-> repo-relative scripts/ paths the unit-test path can execute or read.

    A reference inside a script may be a bare sibling name (`$DIR/helper.sh`),
    so a scripts/ file's own text is also searched for names of files in the
    same directory. Over-inclusion only costs a run.
    """
    found: set[str] = set()
    queue: list[Path] = _root_files(repo)
    seen: set[Path] = set()
    while queue:
        f = queue.pop()
        if f in seen:
            continue
        seen.add(f)
        text = _read(f)
        cands = {m.group(0).rstrip(".") for m in SCRIPT_REF.finditer(text)}
        if f.is_relative_to(repo / "scripts"):
            cands |= {str((f.parent / n).relative_to(repo)) for n in BARE_NAME.findall(text)}
        for c in cands:
            p = repo / c
            if p.is_file():
                rel = str(p.relative_to(repo))
                if rel not in found:
                    found.add(rel)
                    queue.append(p)
            elif p.is_dir():
                for x in p.rglob("*"):
                    if x.is_file():
                        rel = str(x.relative_to(repo))
                        if rel not in found:
                            found.add(rel)
                            queue.append(x)
    return found


def _match(path: str, patterns) -> bool:
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def classify(changed: list[str], relevant: set[str]) -> tuple[bool, list[str]]:
    """-> (run, reasons). reasons names each path that forced the run."""
    paths = [p.strip() for p in changed if p.strip()]
    if not paths:
        return True, ["no changed paths were supplied; running rather than guessing"]
    reasons = []
    for p in paths:
        if _match(p, ALWAYS_RELEVANT):
            reasons.append(f"{p}: part of the unit-test workflow")
        elif p in relevant:
            reasons.append(f"{p}: executed or read by the unit-test path")
        elif not _match(p, SKIPPABLE):
            reasons.append(f"{p}: not on the skippable list")
    return bool(reasons), reasons


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed", help="file with one changed path per line (default: stdin)")
    ap.add_argument("--github-output", action="store_true",
                    help="also append run=<bool> to $GITHUB_OUTPUT")
    args = ap.parse_args(argv[1:])
    text = Path(args.changed).read_text() if args.changed else sys.stdin.read()
    run, reasons = classify(text.splitlines(), relevant_scripts(REPO))
    print(f"run={'true' if run else 'false'}")
    for r in reasons[:50]:
        print(f"  {r}")
    if len(reasons) > 50:
        print(f"  ... and {len(reasons) - 50} more")
    if not run:
        print("  every changed path is on the skippable list; the build and test jobs will not run")
    if args.github_output:
        out = os.environ.get("GITHUB_OUTPUT")
        if not out:
            print("::error::--github-output given but GITHUB_OUTPUT is not set")
            return 1
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"run={'true' if run else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

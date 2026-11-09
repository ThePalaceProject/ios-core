#!/usr/bin/env python3
"""Read the DRM connector record and check a local connector tree against it.

The record is the input defaults of .github/actions/checkout-adobe/action.yml:
`repo`, `ref` (a full commit SHA) and `generation`. CI checks out that commit
through the action, local setup clones it with `clone`, and `check` compares
the tree a local build links against it. See
docs/architecture/adobe-drm-connector-linking.md.

  drm_connector.py get repo|sha|generation
  drm_connector.py clone DEST
  drm_connector.py check

`check` exit status: 0 the tree is at the recorded commit and clean, 1 it is
not, 2 there is no connector tree (a noDRM setup), 3 no usable verdict.

prior-art-checked: the harness has no reader for this repository's connector record.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ACTION_PATH = Path(".github/actions/checkout-adobe/action.yml")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")

EXIT_MATCH, EXIT_DRIFT, EXIT_NO_TREE, EXIT_ERROR = 0, 1, 2, 3


class RecordError(Exception):
    pass


def read_record(repo_root: Path) -> dict:
    """Return {"repo", "sha", "generation"} from the action's input defaults."""
    path = repo_root / ACTION_PATH
    try:
        text = path.read_text()
    except OSError as error:
        raise RecordError(f"cannot read {path}: {error}") from error

    defaults: dict[str, str] = {}
    current = None
    in_inputs = False
    for line in text.splitlines():
        if re.match(r"^\S", line):
            in_inputs = line.startswith("inputs:")
            current = None
            continue
        if not in_inputs:
            continue
        name = re.match(r"^  ([A-Za-z_-]+):\s*$", line)
        if name:
            current = name.group(1)
            continue
        default = re.match(r'^    default:\s*"?([^"#\s]*)"?', line)
        if default and current:
            defaults[current] = default.group(1)

    missing = [key for key in ("repo", "ref", "generation") if not defaults.get(key)]
    if missing:
        raise RecordError(f"{path} has no default for: {', '.join(missing)}")
    sha = defaults["ref"]
    if not SHA_RE.match(sha):
        raise RecordError(f"{path}: ref default {sha!r} is not a full 40-character commit SHA")
    if not defaults["generation"].isdigit():
        raise RecordError(f"{path}: generation default {defaults['generation']!r} is not an integer")
    return {"repo": defaults["repo"], "sha": sha, "generation": defaults["generation"]}


def _git(*args: str, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=False)


def clone(record: dict, dest: Path) -> int:
    """Clone the connector repository and check out the recorded commit.

    `git clone --branch` takes only branch and tag names, so the commit is
    checked out after the clone. GIT_LFS_SKIP_SMUDGE keeps the default branch's
    LFS objects from being downloaded first; `lfs pull` then fetches only the
    recorded commit's.
    """
    url = f"git@github.com:{record['repo']}.git"
    env = {**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"}
    steps = [
        ["git", "clone", url, str(dest)],
        ["git", "-C", str(dest), "checkout", "--detach", record["sha"]],
        ["git", "-C", str(dest), "lfs", "pull"],
    ]
    for step in steps:
        print("+ " + " ".join(step), flush=True)
        if subprocess.run(step, env=env, check=False).returncode != 0:
            print(f"drm-connector: failed: {' '.join(step)}", file=sys.stderr)
            return 1
    return 0


def check(record: dict, repo_root: Path) -> int:
    """Compare the connector tree a local build links against the record."""
    override = os.environ.get("ADEPT_RMSDK")
    link = Path(override) if override else repo_root / "adobe-rmsdk"
    source = "ADEPT_RMSDK" if override else str(link)
    if not os.path.lexists(link):
        print(f"drm-connector: no connector tree at {link} (noDRM setup); nothing to check")
        return EXIT_NO_TREE
    # Resolve the link before asking git: `adobe-rmsdk/..` names the app
    # checkout, not the connector checkout the link points into.
    resolved = Path(os.path.realpath(link))
    if not resolved.is_dir():
        print(f"drm-connector: {source} points at {resolved}, which is not a directory")
        return EXIT_ERROR
    top = _git("rev-parse", "--show-toplevel", cwd=resolved)
    if top.returncode != 0:
        print(f"drm-connector: {resolved} is not inside a git checkout; cannot read its revision")
        return EXIT_ERROR
    tree = Path(top.stdout.strip()).resolve()
    if tree == repo_root.resolve():
        print(f"drm-connector: {source} resolves into this repository, not a connector checkout")
        return EXIT_ERROR

    head = _git("rev-parse", "HEAD", cwd=tree)
    if head.returncode != 0:
        print(f"drm-connector: cannot read HEAD of {tree}")
        return EXIT_ERROR
    actual = head.stdout.strip()
    sha = record["sha"]
    if actual != sha:
        print(
            f"drm-connector: {tree} is at {actual}, but {ACTION_PATH} records {sha}.\n"
            "  Local DRM builds would link a different connector from CI. To match the record:\n"
            f"    git -C {tree} fetch origin\n"
            f"    git -C {tree} checkout --detach {sha}\n"
            f"    git -C {tree} lfs pull"
        )
        return EXIT_DRIFT

    status = _git("status", "--porcelain", "--untracked-files=no", cwd=tree)
    if status.returncode != 0:
        print(f"drm-connector: cannot read the status of {tree}")
        return EXIT_ERROR
    changed = status.stdout.strip().splitlines()
    if changed:
        print(
            f"drm-connector: {tree} is at the recorded commit but has {len(changed)} "
            f"modified tracked file(s), e.g. {changed[0].strip()}.\n"
            f"  To restore them: git -C {tree} checkout -- . && git -C {tree} lfs pull"
        )
        return EXIT_DRIFT

    print(f"drm-connector: {tree} is at the recorded commit {actual} (generation {record['generation']})")
    return EXIT_MATCH


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="DRM connector record and drift check")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    sub = parser.add_subparsers(dest="command", required=True)
    get = sub.add_parser("get")
    get.add_argument("field", choices=["repo", "sha", "generation"])
    clone_cmd = sub.add_parser("clone")
    clone_cmd.add_argument("dest", type=Path)
    sub.add_parser("check")
    args = parser.parse_args(argv)

    try:
        record = read_record(args.repo_root)
    except RecordError as error:
        print(f"drm-connector: {error}", file=sys.stderr)
        return EXIT_ERROR

    if args.command == "get":
        print(record[args.field])
        return 0
    if args.command == "clone":
        return clone(record, args.dest)
    return check(record, args.repo_root)


if __name__ == "__main__":
    sys.exit(main())

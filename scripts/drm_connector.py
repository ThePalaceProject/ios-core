#!/usr/bin/env python3
"""Read the DRM build-input records and check local checkouts against them.

Two private repositories feed a DRM build, and each is recorded as the input
defaults of a composite action:

  connector     .github/actions/checkout-adobe/action.yml        repo, ref, generation
  certificates  .github/actions/checkout-certificates/action.yml repo, ref, paths, tooling

`ref` is always a full commit SHA. CI checks out that commit through the
action, local setup clones it with `clone`, and `check` compares the local
checkouts a DRM build reads against the records: the connector by commit (it is
binaries only), the certificates by the content of the build files in `paths`,
because that repository also holds tooling (`tooling`) developed in place. See
docs/architecture/adobe-drm-connector-linking.md.

  drm_connector.py get [--input NAME] repo|sha|generation
  drm_connector.py clone [--input NAME] DEST
  drm_connector.py check

`check` exit status: 0 every checkout matches its record, 1 one does not (or is
missing), 2 there is no connector tree (a noDRM setup), 3 no usable verdict. It
prints commits and paths only, never file contents.

prior-art-checked: no existing script under scripts/ reads the connector record.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

INPUTS = {
    "connector": (Path(".github/actions/checkout-adobe/action.yml"), ("repo", "ref", "generation")),
    "certificates": (Path(".github/actions/checkout-certificates/action.yml"), ("repo", "ref", "paths")),
}
ACTION_PATH = INPUTS["connector"][0]
SHA_RE = re.compile(r"^[0-9a-f]{40}$")

EXIT_MATCH, EXIT_DRIFT, EXIT_NO_TREE, EXIT_ERROR = 0, 1, 2, 3


class RecordError(Exception):
    pass


def read_record(repo_root: Path, name: str = "connector") -> dict:
    """Return {"repo", "sha"[, "generation"]} from an action's input defaults."""
    action, required = INPUTS[name]
    path = repo_root / action
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
        field = re.match(r"^  ([A-Za-z_-]+):\s*$", line)
        if field:
            current = field.group(1)
            continue
        default = re.match(r'^    default:\s*(?:"([^"]*)"|([^"#\s]+))', line)
        if default and current:
            defaults[current] = default.group(1) if default.group(1) is not None else default.group(2)

    missing = [key for key in required if not defaults.get(key)]
    if missing:
        raise RecordError(f"{path} has no default for: {', '.join(missing)}")
    sha = defaults["ref"]
    if not SHA_RE.match(sha):
        raise RecordError(f"{path}: ref default {sha!r} is not a full 40-character commit SHA")
    record = {"repo": defaults["repo"], "sha": sha, "path": action}
    if "paths" in required:
        record["paths"] = defaults["paths"].split()
        record["tooling"] = defaults.get("tooling", "").split()
    if "generation" in required:
        if not defaults["generation"].isdigit():
            raise RecordError(f"{path}: generation default {defaults['generation']!r} is not an integer")
        record["generation"] = defaults["generation"]
    return record


def _git(*args: str, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=False)


def clone(record: dict, dest: Path) -> int:
    """Clone a recorded repository and check out the recorded commit.

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


def _compare(tree: Path, record: dict, detail: str = "") -> int:
    """Compare a checkout's HEAD and tracked files with a record."""
    head = _git("rev-parse", "HEAD", cwd=tree)
    if head.returncode != 0:
        print(f"drm-connector: cannot read HEAD of {tree}")
        return EXIT_ERROR
    actual = head.stdout.strip()
    sha = record["sha"]
    if actual != sha:
        print(
            f"drm-connector: {tree} is at {actual}, but {record['path']} records {sha}.\n"
            "  Local DRM builds would use a different revision from CI. To match the record:\n"
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

    print(f"drm-connector: {tree} is at the recorded commit {actual}{detail}")
    return EXIT_MATCH


def check_connector(record: dict, repo_root: Path) -> int:
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
    return _compare(tree, record, f" (generation {record['generation']})")


def check_certificates(record: dict, repo_root: Path) -> int:
    """Compare the build files of the certificates checkout with the record.

    Only the files in `paths` are compared, committed or not; other commits and
    edits in that repository (its tooling) are not drift.
    """
    # Same location rule as scripts/build-carthage.sh.
    base = repo_root if os.environ.get("BUILD_CONTEXT") == "ci" else repo_root.parent
    tree = (base / "mobile-certificates").resolve()
    sha = record["sha"]
    if not (tree / ".git").exists():
        print(f"drm-connector: no certificates checkout at {tree}; a DRM build needs one with the build files of {sha}")
        return EXIT_DRIFT
    if _git("cat-file", "-e", f"{sha}^{{commit}}", cwd=tree).returncode != 0:
        print(
            f"drm-connector: {tree} does not have the recorded commit {sha}.\n"
            f"  Fetch it with: git -C {tree} fetch origin"
        )
        return EXIT_DRIFT
    missing = [path for path in record["paths"]
               if _git("cat-file", "-e", f"{sha}:{path}", cwd=tree).returncode != 0]
    if missing:
        print(f"drm-connector: {record['path']} lists {', '.join(missing)}, which {sha} does not contain")
        return EXIT_ERROR
    # Working tree against the recorded commit: committed and uncommitted changes.
    diff = _git("diff", "--name-only", sha, "--", *record["paths"], cwd=tree)
    if diff.returncode != 0:
        print(f"drm-connector: cannot compare {tree} with {sha}")
        return EXIT_ERROR
    differing = diff.stdout.split()
    if differing:
        print(
            f"drm-connector: {tree} has build files that differ from {sha}, which "
            f"{record['path']} records: {', '.join(differing)}.\n"
            "  Local DRM builds would use different certificates or LCP settings from CI.\n"
            "  To use the recorded versions (this discards local changes to those files):\n"
            f"    git -C {tree} checkout {sha} -- {' '.join(differing)}"
        )
        return EXIT_DRIFT
    head = _git("rev-parse", "HEAD", cwd=tree).stdout.strip()
    print(f"drm-connector: {tree} build files match {sha} ({len(record['paths'])} files; checkout HEAD {head})")
    return EXIT_MATCH


def check(repo_root: Path) -> int:
    connector_status = check_connector(read_record(repo_root, "connector"), repo_root)
    if connector_status == EXIT_NO_TREE:
        return EXIT_NO_TREE
    certificates_status = check_certificates(read_record(repo_root, "certificates"), repo_root)
    return max(connector_status, certificates_status)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="DRM build-input records and drift check")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    sub = parser.add_subparsers(dest="command", required=True)
    get = sub.add_parser("get")
    get.add_argument("--input", choices=sorted(INPUTS), default="connector")
    get.add_argument("field", choices=["repo", "sha", "generation"])
    clone_cmd = sub.add_parser("clone")
    clone_cmd.add_argument("--input", choices=sorted(INPUTS), default="connector")
    clone_cmd.add_argument("dest", type=Path)
    sub.add_parser("check")
    args = parser.parse_args(argv)

    try:
        if args.command == "check":
            return check(args.repo_root)
        record = read_record(args.repo_root, args.input)
    except RecordError as error:
        print(f"drm-connector: {error}", file=sys.stderr)
        return EXIT_ERROR

    if args.command == "get":
        if args.field not in record:
            print(f"drm-connector: the {args.input} record has no {args.field}", file=sys.stderr)
            return EXIT_ERROR
        print(record[args.field])
        return 0
    return clone(record, args.dest)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Tests for check-doc-index-complete.py.

The gate exists because the architecture index described 6 of 53 documents, so
47 decision records were reachable only by grepping the whole tree. These tests
care about both failure directions and, as always, about the clean path — a gate
that false-positives on a correct index gets disabled, and a disabled gate looks
exactly like a passing one.
"""

import os
import subprocess
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
DETECTOR = os.path.join(HERE, "..", "check-doc-index-complete.py")

ARCH = "docs/architecture"


def make_repo(tmp_path, files: dict):
    for rel, body in files.items():
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(body), encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    return tmp_path


def run(root):
    return subprocess.run(
        [sys.executable, DETECTOR, "--root", str(root)],
        capture_output=True, text=True)


def test_complete_index_passes(tmp_path):
    """THE PATH THAT MATTERS MOST."""
    root = make_repo(tmp_path, {
        f"{ARCH}/README.md": "# Index\n- [a](./a.md)\n- [b](./b.md)\n",
        f"{ARCH}/a.md": "# A\n",
        f"{ARCH}/b.md": "# B\n",
    })
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_unlisted_doc_blocks(tmp_path):
    """The actual rot: a doc lands, the index does not grow, nobody finds it."""
    root = make_repo(tmp_path, {
        f"{ARCH}/README.md": "# Index\n- [a](./a.md)\n",
        f"{ARCH}/a.md": "# A\n",
        f"{ARCH}/orphan.md": "# Orphan\n",
    })
    r = run(root)
    assert r.returncode == 1
    assert "orphan.md" in r.stdout


def test_index_naming_a_deleted_doc_blocks(tmp_path):
    """The other direction: the index sends a reader somewhere that is not
    there. Same lie as a dangling script reference, one level up."""
    root = make_repo(tmp_path, {
        f"{ARCH}/README.md": "# Index\n- [a](./a.md)\n- [ghost](./ghost.md)\n",
        f"{ARCH}/a.md": "# A\n",
    })
    r = run(root)
    assert r.returncode == 1
    assert "ghost.md" in r.stdout


def test_nested_doc_must_be_listed_by_relative_path(tmp_path):
    """Docs live in subdirectories (areas/, reviews/). Matching on the path
    relative to the index means a link that satisfies the gate is also a link
    that RESOLVES — a bare basename would pass while linking nowhere."""
    root = make_repo(tmp_path, {
        f"{ARCH}/README.md": "# Index\n- [checklist](./areas/auth/verification-checklist.md)\n",
        f"{ARCH}/areas/auth/verification-checklist.md": "# Auth\n",
    })
    assert run(root).returncode == 0

    root2 = make_repo(tmp_path / "two", {
        f"{ARCH}/README.md": "# Index\n- [checklist](verification-checklist.md)\n",
        f"{ARCH}/areas/auth/verification-checklist.md": "# Auth\n",
    })
    r = run(root2)
    assert r.returncode == 1, "a basename-only mention links nowhere and must not satisfy the gate"


def test_missing_index_blocks(tmp_path):
    """A directory of docs with no index is the worst case, not an exemption."""
    root = make_repo(tmp_path, {f"{ARCH}/a.md": "# A\n"})
    r = run(root)
    assert r.returncode == 1
    assert "no index" in r.stdout


def test_absent_directory_is_skipped_not_failed(tmp_path):
    """A checkout without the directory at all (a fixture, a partial clone) must
    not fail — that would be a gate blocking for a reason unrelated to docs."""
    root = make_repo(tmp_path, {"README.md": "# Repo\n"})
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_prose_mention_of_an_unrelated_file_is_not_a_stale_entry(tmp_path):
    """The reverse check only looks at links INTO the indexed directory. A
    pointer at some other part of the repo belongs to the reference gate."""
    root = make_repo(tmp_path, {
        f"{ARCH}/README.md": "# Index\n- [a](./a.md)\nSee [posture](../Testing/TESTING_POSTURE.md).\n",
        f"{ARCH}/a.md": "# A\n",
        "docs/Testing/TESTING_POSTURE.md": "# Posture\n",
    })
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_real_repo_is_clean(tmp_path):
    """Dry-run against the actual tree — CLAUDE.md rule 4(c). A gate landed with
    live false positives is a gate someone disables within the week."""
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    r = subprocess.run([sys.executable, DETECTOR, "--root", repo],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout

#!/usr/bin/env python3
"""
Every bash test under scripts/tests/ must be invoked by a CI workflow.

WHY THIS EXISTS. `test_ratchet_aggregation_behaviour.sh` shipped invoked by
NOTHING. It is the check two reviewers between them walked through seven ways
when it asserted by grepping source text, and its replacement — the one that
catches all seven — ran zero times. Its only mention anywhere in the repo was a
COMMENT in a sibling test, which is a mention and not a call.

That is the same defect as the three decomposition ratchets that shipped with
baselines and passing unit tests while nothing invoked them, and it happened
inside the branch that exists to remove exactly this. Pytest collects `*.py`
under this directory automatically, so a Python test cannot be orphaned this
way; a bash test has to be named in a workflow by hand, and hands forget.

This is the check that cannot be forgotten, because it enumerates the directory
rather than a list someone maintains.
"""

import os
import re
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
WORKFLOW_DIR = os.path.join(REPO, ".github", "workflows")


def bash_tests() -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-files", "scripts/tests/*.sh"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return [f for f in out if f]


def workflow_text() -> str:
    parts = []
    for name in sorted(os.listdir(WORKFLOW_DIR)):
        if name.endswith((".yml", ".yaml")):
            with open(os.path.join(WORKFLOW_DIR, name), encoding="utf-8") as fh:
                parts.append(fh.read())
    return "\n".join(parts)


def invocations(text: str, basename: str) -> list[str]:
    """Lines that RUN the script, not lines that merely name it.

    A comment mentioning the file satisfies a naive substring search — which is
    how this class of defect hides. Require the name to appear in a line that
    actually executes something, and never in a comment.
    """
    hits = []
    for line in text.split("\n"):
        stripped = line.strip()
        if basename not in stripped:
            continue
        if stripped.startswith("#"):
            continue
        if re.search(r"(?:bash|sh|source|\./)\s*\S*" + re.escape(basename), stripped):
            hits.append(stripped)
    return hits


@pytest.mark.parametrize("path", bash_tests())
def test_bash_test_is_invoked_by_a_workflow(path):
    basename = os.path.basename(path)
    hits = invocations(workflow_text(), basename)
    assert hits, (
        f"{path} is not invoked by any workflow — it runs zero times.\n"
        f"A test nothing calls is indistinguishable from a test that always passes.\n"
        f"Add a step to .github/workflows/tooling-checks.yml that runs it."
    )


@pytest.mark.parametrize("path", bash_tests())
def test_bash_test_invocation_fails_closed(path):
    """Guarding a TRACKED file with `if [ -f … ] else echo skipping` means
    deleting the test turns the gate green. Absence must be an error."""
    basename = os.path.basename(path)
    text = workflow_text()
    idx = text.find(basename)
    assert idx != -1
    window = text[max(0, idx - 700): idx + 400]
    if "if [ -f" in window or "if [ ! -f" in window:
        assert ("exit 1" in window or "::error::" in window), (
            f"{path} is guarded by a file-existence check that does not fail.\n"
            f"It is a tracked file: absence means the gate was deleted, not that "
            f"it is optional."
        )


def test_there_is_at_least_one_bash_test():
    """Control. If the glob silently returned nothing, every parametrised test
    above would vacuously pass and this file would assert precisely nothing —
    the failure mode it exists to catch, in itself."""
    assert len(bash_tests()) >= 5, (
        f"expected several bash tests, found {len(bash_tests())} — the "
        f"enumeration is broken, so the checks above are vacuous"
    )

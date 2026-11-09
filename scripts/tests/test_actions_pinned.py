"""Every third-party Action under .github/ is pinned to a full commit SHA with
its full release version (vX.Y.Z) as a trailing comment, so a moved tag cannot
change what CI runs. Dependabot bumps the SHA and the comment together
(.github/dependabot.yml).

prior-art-checked: the harness has no check of this repository's workflow pins.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$")
PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
TAG_COMMENT = re.compile(r"^\s+#\s+v\d+\.\d+\.\d+\s*$")


def unpinned_uses(root: Path) -> list[str]:
    found = []
    for path in sorted((root / ".github").rglob("*.yml")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = USES.match(line)
            if not match:
                continue
            target, rest = match.groups()
            if target.startswith("./") or target.startswith("docker://"):
                continue
            if not PINNED.match(target) or not TAG_COMMENT.match(rest):
                found.append(f"{path.relative_to(root)}:{number}: {line.strip()}")
    return found


def test_every_third_party_action_is_pinned_to_a_commit_sha():
    assert unpinned_uses(REPO) == []


def test_the_scan_finds_actions_in_this_tree():
    # Guards against a scan that matches nothing and so reports no offenders.
    count = sum(
        1
        for path in (REPO / ".github").rglob("*.yml")
        for line in path.read_text().splitlines()
        if USES.match(line) and not USES.match(line).group(1).startswith("./")
    )
    assert count >= 100


def write(root: Path, text: str) -> None:
    path = root / ".github" / "workflows" / "w.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def test_a_tag_reference_is_reported(tmp_path):
    write(tmp_path, "    steps:\n      - uses: actions/checkout@v7\n")
    assert unpinned_uses(tmp_path) == [".github/workflows/w.yml:2: - uses: actions/checkout@v7"]


def test_a_short_sha_is_reported(tmp_path):
    write(tmp_path, "      - uses: actions/checkout@3d3c42e # v7.0.1\n")
    assert len(unpinned_uses(tmp_path)) == 1


def test_a_major_only_version_comment_is_reported(tmp_path):
    # Dependabot keeps a vX.Y.Z comment in step with the SHA it bumps.
    write(tmp_path, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n")
    assert len(unpinned_uses(tmp_path)) == 1


def test_a_full_sha_without_its_tag_comment_is_reported(tmp_path):
    write(tmp_path, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n")
    assert len(unpinned_uses(tmp_path)) == 1


def test_a_pinned_action_and_a_local_action_pass(tmp_path):
    write(tmp_path,
          "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
          "        uses: ./.github/actions/checkout-adobe\n")
    assert unpinned_uses(tmp_path) == []

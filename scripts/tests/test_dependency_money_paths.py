"""Tests for scripts/check-dependency-money-paths.sh.

The gate blocks a Readium pin change that carries no money-path validation
entry. The failure it exists to prevent is the 3.2.0 bump, which moved Readium
3.7 -> 3.9 and silently broke LCP audiobook streaming because nothing exercised
that path against the new pin.

The clean-diff case is tested explicitly and deliberately: a detector that
blocks a pull request it should ignore is worse than no detector, and a fixture
that only ever stages a violation cannot see that.
"""

import json
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check-dependency-money-paths.sh"

PASS = 0
BLOCKED = 1
USAGE = 2


def write_resolved(path: Path, version: str, revision: str = "deadbeef") -> Path:
    """Writes a Package.resolved v2 document pinning swift-toolkit.

    An empty `version` omits the key entirely, which is how SwiftPM records a
    pin taken by bare revision (a fork branch, or a tag that is not valid
    SemVer). That shape decides which token the gate demands, so it has to be
    representable here.
    """
    state = {"revision": revision}
    if version:
        state["version"] = version
    doc = {
        "originHash": "x",
        "pins": [
            {
                "identity": "firebase-ios-sdk",
                "kind": "remoteSourceControl",
                "location": "https://github.com/firebase/firebase-ios-sdk.git",
                "state": {"revision": "abc123", "version": "11.0.0"},
            },
            {
                "identity": "swift-toolkit",
                "kind": "remoteSourceControl",
                "location": "https://github.com/readium/swift-toolkit.git",
                "state": state,
            },
        ],
        "version": 3,
    }
    path.write_text(json.dumps(doc, indent=2))
    return path


def write_ledger(path: Path, *versions: str) -> Path:
    body = ["# Readium money-path validation ledger", ""]
    for v in versions:
        body += [f"## {v}", "", "- Validated by: iOS maintainer", ""]
    path.write_text("\n".join(body))
    return path


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True,
        text=True,
    )


@pytest.fixture()
def workspace(tmp_path: Path) -> Path:
    return tmp_path


def test_script_parses():
    """A gate that does not parse silently stops gating (see PR #1045)."""
    assert subprocess.run(["bash", "-n", str(SCRIPT)]).returncode == 0


# --- the clean path: the detector must not block unrelated work ---------------


def test_unchanged_pin_passes(workspace: Path):
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.9.0")
    ledger = write_ledger(workspace / "ledger.md")  # deliberately empty

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == PASS, result.stderr
    assert "unchanged" in result.stdout


def test_unrelated_dependency_change_passes(workspace: Path):
    """Only the tracked package matters; other pins moving is not our business."""
    old = write_resolved(workspace / "old.json", "3.9.0")
    new_doc = json.loads(old.read_text())
    for pin in new_doc["pins"]:
        if pin["identity"] == "firebase-ios-sdk":
            pin["state"]["version"] = "12.0.0"
    new = workspace / "new.json"
    new.write_text(json.dumps(new_doc))
    ledger = write_ledger(workspace / "ledger.md")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == PASS, result.stderr


# --- the blocking path -------------------------------------------------------


def test_version_bump_without_ledger_entry_blocks(workspace: Path):
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.12.0")
    ledger = write_ledger(workspace / "ledger.md", "3.9.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED
    assert "3.12.0" in result.stderr


def test_version_bump_with_ledger_entry_passes(workspace: Path):
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.12.0")
    ledger = write_ledger(workspace / "ledger.md", "3.9.0", "3.12.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == PASS, result.stderr


def test_revision_bump_at_same_version_blocks(workspace: Path):
    """A branch or revision move can change behaviour without changing the
    version string, which is exactly how an unreviewed toolkit change lands."""
    old = write_resolved(workspace / "old.json", "3.9.0", revision="aaa111")
    new = write_resolved(workspace / "new.json", "3.9.0", revision="bbb222")
    ledger = write_ledger(workspace / "ledger.md", "3.9.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED, (
        "a revision move at the same version must still require validation"
    )


def test_stale_entry_for_a_different_version_does_not_satisfy(workspace: Path):
    """Copying last release's entry forward must not pass the gate."""
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.13.0")
    ledger = write_ledger(workspace / "ledger.md", "3.9.0", "3.12.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED


def test_mention_in_an_entry_body_does_not_satisfy(workspace: Path):
    """PP-5091. The token has to appear in an entry *heading*.

    The matcher used to be an unanchored whole-file grep, so any passing mention
    counted. The ledger's fork entry describes its pin as "Readium 3.11.0 + the
    upstream fix-issue-579 series", which means a later move to a genuine
    upstream 3.11.0 would have been waved through on the strength of a different
    entry's prose — the gate built to stop false greens producing one. Deleting
    the heading anchor in `ledger_records_version` turns this test red.
    """
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.11.0")
    ledger = workspace / "ledger.md"
    ledger.write_text(
        "# Readium money-path validation ledger\n"
        "\n"
        "## fork @ 58413f868\n"
        "\n"
        "- Pin: fork = Readium 3.11.0 + the upstream fix-issue-579 series.\n"
    )

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED, (
        "a version named only in an older entry's prose must not satisfy the gate"
    )


def test_token_in_a_descriptive_heading_satisfies(workspace: Path):
    """Headings are not always a bare version.

    A fork pinned by revision is recorded under a heading that names the repo and
    the SHA, and a fork pinned by tag under one that names both the tag and the
    SHA. Anchoring to headings must not narrow the gate to `## <semver>` only —
    that would block the very entry shape the ledger already uses.
    """
    old = write_resolved(workspace / "old.json", "", revision="aaa111")
    new = write_resolved(workspace / "new.json", "", revision="bbb222")
    ledger = workspace / "ledger.md"
    ledger.write_text(
        "# Readium money-path validation ledger\n"
        "\n"
        "## 3.11.0-palace.1 — ThePalaceProject/swift-toolkit @ bbb222\n"
        "\n"
        "- Validated by: iOS maintainer\n"
    )

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == PASS, result.stderr


def test_prefix_of_a_longer_heading_token_does_not_satisfy(workspace: Path):
    """A fork's heading names a tag built on an upstream version.

    `## 3.11.0-palace.1 — …/swift-toolkit @ 58413f868…` contains "3.11.0" as a
    substring, so a plain substring test would let a later move to genuine
    upstream 3.11.0 be satisfied by the fork's entry — an entry describing
    different code. The token has to stand as a whole token in the heading.
    """
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.11.0")
    ledger = workspace / "ledger.md"
    ledger.write_text(
        "# Readium money-path validation ledger\n"
        "\n"
        "## 3.11.0-palace.1 — ThePalaceProject/swift-toolkit @ 58413f868\n"
        "\n"
        "- Validated by: iOS maintainer\n"
    )

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED, (
        "an upstream version must not be satisfied by a fork tag that merely "
        "starts with it"
    )


def test_pin_by_revision_moving_to_the_same_code_under_a_tag_still_requires_an_entry(
    workspace: Path,
):
    """Same 40-char revision, newly carrying a `version` because the pin moved
    from a bare revision to an exact tag. The content did not change, but the
    *pin* did, so the ledger must say so — the gate cannot tell "re-expressed the
    same commit" from "moved to a tag that points somewhere else" and must not
    try."""
    old = write_resolved(workspace / "old.json", "", revision="58413f868")
    new = write_resolved(workspace / "new.json", "3.11.0-palace.1", revision="58413f868")
    ledger = write_ledger(workspace / "ledger.md", "ThePalaceProject/swift-toolkit @ 58413f868")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED, (
        "gaining a version key is a pin change; the old revision-only entry does "
        "not describe the new pin form"
    )


def test_missing_ledger_blocks_when_pin_moved(workspace: Path):
    old = write_resolved(workspace / "old.json", "3.9.0")
    new = write_resolved(workspace / "new.json", "3.12.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(workspace / "absent.md"),
    )

    assert result.returncode == BLOCKED


# --- input handling ----------------------------------------------------------


def test_no_arguments_is_usage_error():
    assert run().returncode == USAGE


def test_dependency_added_where_previously_absent_blocks(workspace: Path):
    """First introduction of the dependency is a pin change like any other."""
    old = workspace / "old.json"
    old.write_text(json.dumps({"pins": [], "version": 3}))
    new = write_resolved(workspace / "new.json", "3.12.0")
    ledger = write_ledger(workspace / "ledger.md")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode == BLOCKED


def test_malformed_resolved_does_not_crash(workspace: Path):
    """A corrupt file must not take the whole gate down with a traceback."""
    old = workspace / "old.json"
    old.write_text("{not json")
    new = write_resolved(workspace / "new.json", "3.12.0")
    ledger = write_ledger(workspace / "ledger.md", "3.12.0")

    result = run(
        "--old-resolved", str(old),
        "--new-resolved", str(new),
        "--ledger", str(ledger),
    )

    assert result.returncode in (PASS, BLOCKED)
    assert "Traceback" not in result.stderr


# --- the real repository state ----------------------------------------------


def test_repository_ledger_records_the_current_pin(workspace: Path):
    """Dry run against the tree: the committed ledger must already satisfy the
    committed pin, so the gate does not fire on unrelated pull requests."""
    repo = Path(__file__).resolve().parents[2]
    resolved = repo / "Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    ledger = repo / "docs/architecture/readium-money-path-validation.md"
    if not resolved.exists():
        pytest.skip("Package.resolved not present in this checkout")

    doc = json.loads(resolved.read_text())
    pins = doc.get("pins") or doc.get("object", {}).get("pins") or []
    state = next(
        (p["state"] for p in pins
         if (p.get("identity") or "").lower() == "swift-toolkit"),
        {},
    )
    # A fork pinned by revision has no semver `version`; the runtime gate
    # (check-dependency-money-paths.sh) keys on revision in that case, so mirror it.
    version = state.get("version") or state.get("revision", "")
    assert version, "swift-toolkit pin not found in Package.resolved"

    # Ask the gate, rather than reimplementing its matcher here. A local
    # reimplementation drifts silently and always in the reassuring direction:
    # this check previously did a substring search over headings, so once the
    # gate began demanding a whole token it would have kept passing on a pin the
    # gate would block in CI. Feed the committed pin in as a change from "absent"
    # so the gate is forced to consult the ledger.
    absent = workspace / "absent.json"
    absent.write_text(json.dumps({"pins": [], "version": 3}))
    result = run(
        "--old-resolved", str(absent),
        "--new-resolved", str(resolved),
        "--ledger", str(ledger),
    )
    assert result.returncode == PASS, (
        f"the committed ledger does not satisfy the gate for the committed pin "
        f"{version}:\n{result.stderr}"
    )

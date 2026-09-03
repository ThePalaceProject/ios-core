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
    """Writes a Package.resolved v2 document pinning swift-toolkit."""
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
                "state": {"revision": revision, "version": version},
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


def test_repository_ledger_records_the_current_pin():
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
        (p.get("state") or {} for p in pins
         if (p.get("identity") or "").lower() == "swift-toolkit"),
        None,
    )
    assert state is not None, "swift-toolkit pin not found in Package.resolved"

    # A pin is identified by its VERSION when it tracks a release, and by its
    # REVISION when it tracks a fork — as the 3.2.4 hotfix does, pinning
    # ThePalaceProject/swift-toolkit at the fix-issue-579 series because the
    # streaming fix is not in any upstream release. Reading only `version` made
    # this gate unable to express a fork pin at all: it failed with "pin not
    # found" when the pin was right there, which reads as a missing dependency
    # rather than an unrecorded one. Accept either identifier and require the
    # ledger to name whichever one is actually in use.
    identifier = state.get("version") or state.get("revision") or ""
    assert identifier, (
        "swift-toolkit pin has neither a version nor a revision: "
        f"{state!r}"
    )
    assert identifier in ledger.read_text(), (
        f"ledger has no entry for the pinned Readium {identifier}. A Readium "
        "move must be recorded in readium-money-path-validation.md with the "
        "money paths re-validated against it — that is the point of the pin "
        "gate, and a fork revision is no exception."
    )

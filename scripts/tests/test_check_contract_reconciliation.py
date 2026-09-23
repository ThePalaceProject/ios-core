"""
test_check_contract_reconciliation.py — pytest for the M1 contract-
reconciliation detector (scripts/check-contract-reconciliation.py).

The detector parses claim phrases ("removes X", "renames X to Y",
"adds field A to type B", "fixes N findings", ...) out of a
commit-message / PR-body / intent / swarm-contract source, then greps
the staged unified diff for evidence each claim is reflected. A claim
with no supporting diff evidence exits 1; a fully-supported set of
claims exits 0.

Interface (matched exactly against the script's argparse):
  --commit-msg <file>   claim source (also --pr-body/--intent/--swarm-contract)
  --diff <file>         unified-diff input; `-` or omit reads stdin
  exit 0 = all claims reconcile; exit 1 = ≥1 unsupported; exit 2 = I/O error

Both the caught-violation path AND the clean-pass path are asserted for
each grammar exercised — the clean-pass assertion is the one that would
catch a wiring bug where the detector rejects an input it should accept.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-contract-reconciliation.py"


def _run(commit_msg: Path, diff: Path) -> subprocess.CompletedProcess:
    """Invoke the detector with a commit-msg source and a diff file."""
    return subprocess.run(
        [
            sys.executable,
            str(_SCRIPT),
            "--commit-msg",
            str(commit_msg),
            "--diff",
            str(diff),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )


def _write(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return p


# --- REM grammar: "removes X" ---------------------------------------------

def test_rem_claim_unsupported_by_diff_is_caught(tmp_path):
    """Commit body claims `removes FooBar` but the diff only adds an
    unrelated line — no `-class FooBar` and no FooBar file deletion.
    The unsupported claim must exit 1 and name the claim."""
    msg = _write(tmp_path, "msg.txt",
                 "Refactor cleanup\n\nThis change removes FooBar from the app.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Other.swift b/Palace/Foo/Other.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Other.swift\n"
                  "+++ b/Palace/Foo/Other.swift\n"
                  "@@ -1,2 +1,3 @@\n"
                  " import Foundation\n"
                  "+let unrelated = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" in result.stdout
    assert "FooBar" in result.stdout


def test_rem_claim_supported_by_file_deletion_passes(tmp_path):
    """Same `removes FooBar` claim, but now the diff deletes FooBar.swift
    and removes `class FooBar`. The claim reconciles — must exit 0 with
    no UNSUPPORTED marker. This is the wiring-bug guard: a clean input
    the detector must accept."""
    msg = _write(tmp_path, "msg.txt",
                 "Refactor cleanup\n\nThis change removes FooBar from the app.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/FooBar.swift b/Palace/Foo/FooBar.swift\n"
                  "deleted file mode 100644\n"
                  "index 111..000\n"
                  "--- a/Palace/Foo/FooBar.swift\n"
                  "+++ /dev/null\n"
                  "@@ -1,3 +0,0 @@\n"
                  "-class FooBar {\n"
                  "-    let x = 1\n"
                  "-}\n")
    result = _run(msg, diff)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" not in result.stdout


# --- ADDFLD grammar: "adds field A to type B" -----------------------------

def test_addfld_claim_unsupported_by_diff_is_caught(tmp_path):
    """Commit body claims `adds field enableRetry to type NetworkConfig`
    but the diff never declares that member — must exit 1."""
    msg = _write(tmp_path, "msg.txt",
                 "Add config flag\n\n"
                 "This adds field enableRetry to type NetworkConfig for retries.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Net/Other.swift b/Palace/Net/Other.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Net/Other.swift\n"
                  "+++ b/Palace/Net/Other.swift\n"
                  "@@ -1,2 +1,3 @@\n"
                  " import Foundation\n"
                  "+let unrelated = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" in result.stdout
    assert "enableRetry" in result.stdout


def test_addfld_claim_supported_by_added_member_passes(tmp_path):
    """Same claim, but the diff adds `var enableRetry` inside a file
    referencing NetworkConfig. The claim reconciles — must exit 0."""
    msg = _write(tmp_path, "msg.txt",
                 "Add config flag\n\n"
                 "This adds field enableRetry to type NetworkConfig for retries.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Net/NetworkConfig.swift b/Palace/Net/NetworkConfig.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Net/NetworkConfig.swift\n"
                  "+++ b/Palace/Net/NetworkConfig.swift\n"
                  "@@ -1,3 +1,4 @@\n"
                  " struct NetworkConfig {\n"
                  "     var timeout = 30\n"
                  "+    var enableRetry = false\n"
                  " }\n")
    result = _run(msg, diff)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" not in result.stdout


# --- No-claim path --------------------------------------------------------

def test_no_parseable_claims_passes(tmp_path):
    """A commit body with no claim-shaped phrases yields zero claims and
    must exit 0 regardless of diff contents — the detector only gates
    claims it can parse."""
    msg = _write(tmp_path, "msg.txt",
                 "Tidy imports\n\nGeneral housekeeping, nothing structural.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Other.swift b/Palace/Foo/Other.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Other.swift\n"
                  "+++ b/Palace/Foo/Other.swift\n"
                  "@@ -1,2 +1,3 @@\n"
                  " import Foundation\n"
                  "+let unrelated = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" not in result.stdout


def test_anti_claims_section_is_not_parsed_as_claims(tmp_path):
    """An `## Anti-claims` section states what the change deliberately does
    NOT do. Parsing it as a claim inverts its meaning and blocks the commit
    for doing exactly what it promised.

    Real incident (PP-5025, PR #1418): `Does **NOT** remove the licensor
    guard` under `## Anti-claims` was parsed as `claim=REM args=('the',)`,
    and the gate false-blocked five consecutive review rounds. A gate that
    cries wolf five times on one PR stops being read — the green-board
    contract in CLAUDE.md names that mechanism directly.
    """
    msg = _write(tmp_path, "msg.txt",
                 "Fix the thing\n\n"
                 "## Claims\n\n"
                 "- Adds `Widget.reset()`.\n\n"
                 "## Anti-claims\n\n"
                 "- Does **NOT** remove the licensor guard.\n"
                 "- Does NOT delete SignInModalHostingController.\n"
                 "- Removes nothing from the borrow path.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Widget.swift b/Palace/Foo/Widget.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Widget.swift\n"
                  "+++ b/Palace/Foo/Widget.swift\n"
                  "@@ -1,2 +1,3 @@\n"
                  " import Foundation\n"
                  "+func reset() {}\n")
    result = _run(msg, diff)
    assert result.returncode == 0, (
        "anti-claims must not be parsed as claims\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "UNSUPPORTED" not in result.stdout


def test_claims_after_an_anti_claims_section_are_still_parsed(tmp_path):
    """The strip must end at the next heading, not swallow the rest of the
    document. A control for the fix above: if stripping ran to end-of-file,
    a genuinely unsupported claim in a LATER section would stop being
    caught and the gate would silently weaken."""
    msg = _write(tmp_path, "msg.txt",
                 "Fix the thing\n\n"
                 "## Anti-claims\n\n"
                 "- Does NOT touch the reader.\n\n"
                 "## Claims\n\n"
                 "- Removes LegacyDownloadCoordinator.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Widget.swift b/Palace/Foo/Widget.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Widget.swift\n"
                  "+++ b/Palace/Foo/Widget.swift\n"
                  "@@ -1,2 +1,3 @@\n"
                  " import Foundation\n"
                  "+let unrelated = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 1, (
        "a real claim after the anti-claims section must still be gated — "
        "otherwise the strip weakened the detector\n"
        f"stdout: {result.stdout!r}"
    )


def test_subheading_inside_anti_claims_does_not_end_the_region(tmp_path):
    """A `###` sub-heading inside `## Anti-claims` is still anti-claims.

    Blast-radius review reproduced the original false positive returning via
    this route: terminating the region on ANY heading meant `### DRM` ended it
    and the very next line — `Does **NOT** remove the licensor guard` — parsed
    as `claim=REM args=('the',)` again. Only a heading at the same or shallower
    level ends the region.
    """
    msg = _write(tmp_path, "msg.txt",
                 "Fix the thing\n\n"
                 "## Anti-claims\n\n"
                 "### DRM\n\n"
                 "- Does **NOT** remove the licensor guard.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Widget.swift b/Palace/Foo/Widget.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Widget.swift\n"
                  "+++ b/Palace/Foo/Widget.swift\n"
                  "@@ -1,2 +1,3 @@\n import Foundation\n+let x = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 0, (
        "a sub-heading must not end the anti-claims region\n"
        f"stdout: {result.stdout!r}"
    )


def test_fenced_hash_line_inside_anti_claims_does_not_swallow_later_claims(tmp_path):
    """THE dangerous one: a false NEGATIVE, not a false positive.

    Architect and blast-radius independently reproduced this. When the
    anti-claims check ran before fence tracking, a `#`-initial line inside a
    fenced block (a shell comment — ordinary, and present in this repo's own
    intent files) terminated the region mid-fence. Only one of the two fence
    markers got swallowed, `in_fence` inverted, and the REST of the document
    was skipped — so a genuinely unsupported claim in a later `## Claims`
    section went ungated while the gate reported "no claims parsed".

    A gate that misses real drift while reporting green is worse than one that
    cries wolf, so this test guards the direction that matters most.
    """
    msg = _write(tmp_path, "msg.txt",
                 "Fix the thing\n\n"
                 "## Anti-claims\n\n"
                 "- Does NOT touch the reader.\n\n"
                 "```\n"
                 "# regenerate with:\n"
                 "scripts/foo.sh\n"
                 "```\n\n"
                 "## Claims\n\n"
                 "- Removes LegacyDownloadCoordinator.\n")
    diff = _write(tmp_path, "diff.txt",
                  "diff --git a/Palace/Foo/Widget.swift b/Palace/Foo/Widget.swift\n"
                  "index 111..222 100644\n"
                  "--- a/Palace/Foo/Widget.swift\n"
                  "+++ b/Palace/Foo/Widget.swift\n"
                  "@@ -1,2 +1,3 @@\n import Foundation\n+let x = 1\n")
    result = _run(msg, diff)
    assert result.returncode == 1, (
        "a fenced '#' line must not swallow the rest of the document — "
        "this is the false-negative direction and is worse than a false positive\n"
        f"stdout: {result.stdout!r}"
    )


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))

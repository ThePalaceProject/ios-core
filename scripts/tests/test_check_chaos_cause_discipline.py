"""
test_check_chaos_cause_discipline.py — pytest for the CHAOS-CAUSE detector.

scripts/check-chaos-cause-discipline.py enforces the split between what a
chaos-qa agent OBSERVED and what it BELIEVES caused the observation.

Why this gate exists (rc-3.3.0-20260820): chaos rows carried `Verified: true`
— which the contract scopes to the OBSERVATION — while their `Title` asserted
an unobserved internal mechanism. Downstream that reads as a verified cause.
Three of the campaign's clusters had a sound observation and a wrong stated
cause (a "malformed URL" that returned HTTP 200, "duplicate return calls"
backed by a single log line, a "removed guard" that was never removed).

The BLOCKING rule is structural, never linguistic: every finding must
consciously declare a Cause Status. Prose heuristics are advisory only, so
the gate cannot false-positive on wording.

Coverage (both paths mandatory per CLAUDE.md gate rule #4):
  - REAL violation: cause asserted with no status            → exit 1
  - REAL violation: illegal Cause Status value               → exit 1
  - REAL violation: `verified:<path>` naming a missing file  → exit 1
  - REAL violation: cause named but status says `none`       → exit 1
  - CLEAN pass: every row declares a legal status            → exit 0
    (the wiring assertion — a gate that rejects its own valid input is
    the defect class CLAUDE.md rule #4 exists to catch)
  - LEGACY: header predates the columns → exit 0 without --strict,
    exit 1 with --strict.
  - Advisory: mechanism vocabulary in Title is REPORTED but does not by
    itself fail the run.
"""

from __future__ import annotations

import csv
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DETECTOR = REPO_ROOT / "scripts" / "check-chaos-cause-discipline.py"

# The raw chaos-qa CSV schema, with the two columns this gate introduces.
HEADER = [
    "ID", "Title", "Area", "Test ID", "Classification", "Severity",
    "Verified", "Baseline Behavior", "Candidate Behavior",
    "Suspected Cause", "Cause Status",
    "Steps", "Screenshot Baseline", "Screenshot Candidate", "Notes",
    "PR", "Jira Ticket",
]

LEGACY_HEADER = [c for c in HEADER if c not in ("Suspected Cause", "Cause Status")]


def _row(**over) -> dict:
    base = {c: "" for c in HEADER}
    base.update({
        "ID": "F-001",
        "Title": "Reader stays blank after tapping the centre of the page",
        "Area": "chaos-rapid-tap",
        "Test ID": "cold-launch",
        "Classification": "chaos",
        "Severity": "minor",
        "Verified": "true",
        "Cause Status": "none",
    })
    base.update(over)
    return base


def _write_csv(path: Path, rows: list[dict], header: list[str] = HEADER) -> Path:
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in header})
    return path


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DETECTOR), *args],
        capture_output=True, text=True,
    )


def test_detector_exists_and_is_executable():
    assert DETECTOR.is_file(), f"missing detector: {DETECTOR}"


# --- The clean path (wiring assertion) -------------------------------------

def test_clean_findings_pass(tmp_path):
    """Valid rows must pass. A gate that rejects its own valid input is broken."""
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(ID="F-001", **{"Cause Status": "none"}),
        _row(ID="F-002",
             **{"Suspected Cause": "possibly the download is restarted by the "
                                   "download-center rather than duplicated",
                "Cause Status": "unverified"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0, f"clean input rejected:\n{r.stdout}\n{r.stderr}"
    assert "CHAOS-CAUSE:" not in r.stdout


def test_empty_findings_file_is_clean(tmp_path):
    """Header-only CSV (a pass that found nothing) is a clean pass."""
    csv_path = _write_csv(tmp_path / "findings.csv", [])
    r = _run(str(csv_path))
    assert r.returncode == 0, r.stdout + r.stderr


def test_blank_title_rows_are_ignored(tmp_path):
    """Partial/blank rows are not findings and must not trip the gate."""
    csv_path = _write_csv(tmp_path / "findings.csv",
                          [_row(ID="", Title="", **{"Cause Status": ""})])
    r = _run(str(csv_path))
    assert r.returncode == 0, r.stdout + r.stderr


def test_verified_cause_with_existing_artifact_passes(tmp_path):
    artifact = tmp_path / "curl-fulcrum.txt"
    artifact.write_text("HTTP/2 200\ncontent-type: image/jpeg\n")
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Suspected Cause": "double-slash URL rejected by the CDN",
                "Cause Status": f"verified:{artifact}"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0, f"backed cause rejected:\n{r.stdout}\n{r.stderr}"


# --- Real violations --------------------------------------------------------

def test_missing_cause_status_fails(tmp_path):
    """Every finding must consciously declare a cause status."""
    csv_path = _write_csv(tmp_path / "findings.csv",
                          [_row(**{"Cause Status": ""})])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "CHAOS-CAUSE:" in r.stdout
    assert "C1" in r.stdout


def test_illegal_cause_status_value_fails(tmp_path):
    csv_path = _write_csv(tmp_path / "findings.csv",
                          [_row(**{"Cause Status": "probably"})])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "C2" in r.stdout


def test_verified_cause_with_missing_artifact_fails(tmp_path):
    """`verified:` is a claim about an artifact; the artifact must exist."""
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Suspected Cause": "duplicate fulfillment task",
                "Cause Status": f"verified:{tmp_path / 'nope.txt'}"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "C3" in r.stdout


def test_cause_named_but_status_none_fails(tmp_path):
    """Naming a mechanism and declaring 'no cause' is a contradiction."""
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Suspected Cause": "a race in the borrow debounce",
                "Cause Status": "none"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "C4" in r.stdout


def test_multiple_files_all_scanned(tmp_path):
    good = _write_csv(tmp_path / "a.csv", [_row()])
    bad = _write_csv(tmp_path / "b.csv", [_row(**{"Cause Status": ""})])
    r = _run(str(good), str(bad))
    assert r.returncode == 1
    assert "b.csv" in r.stdout
    assert "a.csv" not in r.stdout


# --- Legacy schema ----------------------------------------------------------

def test_legacy_header_passes_without_strict(tmp_path):
    """Pre-existing corpora lack the columns; they are reported, not failed."""
    rows = [{c: "" for c in LEGACY_HEADER} | {"ID": "F-001", "Title": "x"}]
    csv_path = _write_csv(tmp_path / "legacy.csv", rows, header=LEGACY_HEADER)
    r = _run(str(csv_path))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "LEGACY" in r.stdout


def test_legacy_header_fails_under_strict(tmp_path):
    """A NEW chaos run must emit the columns; --strict is how the runner asks."""
    rows = [{c: "" for c in LEGACY_HEADER} | {"ID": "F-001", "Title": "x"}]
    csv_path = _write_csv(tmp_path / "legacy.csv", rows, header=LEGACY_HEADER)
    r = _run("--strict", str(csv_path))
    assert r.returncode == 1
    assert "LEGACY" in r.stdout


# --- Advisory lint ----------------------------------------------------------

def test_mechanism_vocabulary_in_title_is_advisory_only(tmp_path):
    """Prose heuristics REPORT but never fail — that keeps the gate FP-free."""
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(Title="Rapid-tap on Borrow triggers a duplicate fulfillment request",
             **{"Cause Status": "unverified"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0, "advisory lint must not fail the run"
    assert "CHAOS-CAUSE-ADVISORY:" in r.stdout


def test_advisory_suppressed_when_cause_is_verified(tmp_path):
    artifact = tmp_path / "task-uuid-count.txt"
    artifact.write_text("2 distinct CFNetwork task UUIDs\n")
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(Title="Rapid-tap on Borrow triggers a duplicate fulfillment request",
             **{"Suspected Cause": "two fulfillment tasks in flight",
                "Cause Status": f"verified:{artifact}"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0
    assert "CHAOS-CAUSE-ADVISORY:" not in r.stdout


# --- Advisory: prose measurements vs the artifact beside them ---------------

def test_prose_timing_with_a_replay_is_advised(tmp_path):
    """A number quoted in prose next to a replay YAML that can settle it.

    rc-3.3.0: a finding's prose said the taps landed "in <300ms"; the replay's
    own captured_at stamps showed ~1.6s gaps over 6.4s. The wrong number was
    propagated into two hypotheses and a dispatch before anyone opened the YAML.
    """
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Cause Status": "unverified",
                "Notes": "5 taps within <300ms. replay=/tmp/r/chaos-tap.yaml"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0, "must stay advisory"
    assert "CHAOS-CAUSE-ADVISORY:" in r.stdout
    assert "replay" in r.stdout.lower()


def test_prose_timing_without_a_replay_is_not_advised(tmp_path):
    """No replay means no artifact to check against — nothing to advise."""
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Cause Status": "unverified", "Notes": "5 taps within <300ms."}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0
    assert "CHAOS-CAUSE-ADVISORY:" not in r.stdout


def test_replay_without_prose_timing_is_not_advised(tmp_path):
    csv_path = _write_csv(tmp_path / "findings.csv", [
        _row(**{"Cause Status": "unverified",
                "Notes": "replay=/tmp/r/chaos-tap.yaml"}),
    ])
    r = _run(str(csv_path))
    assert r.returncode == 0
    assert "CHAOS-CAUSE-ADVISORY:" not in r.stdout


# --- C0: structural integrity comes before field interpretation -------------
#
# csv.DictReader does NOT raise on a row wider than its header — the excess is
# silently swallowed into restkey(None) and every named column after the break
# is SHIFTED. Found in the live corpus: all 3 rows of
# chaos/C-ipad-26/audiobook/2026-08-20T15-10-32Z/findings.csv are over-wide
# (25/18/16 cols against a 15-col header) from unquoted commas, so `Steps` held
# " categories=Adult/Law" and `Notes` held " publisher=U.S. Supreme Court".
#
# This matters to THIS gate specifically: `Cause Status` sits late in the
# schema, i.e. inside the shift zone, so a corrupt row can present a legal
# status it never actually declared.

def _write_raw(path: Path, header: list[str], rows: list[list[str]]) -> Path:
    path.write_text(",".join(header) + "\n"
                    + "\n".join(",".join(r) for r in rows) + "\n")
    return path


def test_over_wide_row_fails_even_when_fields_look_legal(tmp_path):
    """The false negative this check exists for: shifted-but-legal reads clean."""
    row = ["F-001", "Reader goes blank", "chaos-rapid-tap", "cold-launch",
           "chaos", "major", "true", "", "observed A", "", "none", "steps",
           "", "", "notes", "", "", "SPILLED-1", "SPILLED-2"]
    csv_path = _write_raw(tmp_path / "wide.csv", HEADER, [row])
    r = _run(str(csv_path))
    assert r.returncode == 1, "a structurally corrupt row passed clean"
    assert "C0" in r.stdout
    assert "19" in r.stdout and "17" in r.stdout   # actual vs expected width


def test_under_wide_row_fails(tmp_path):
    row = ["F-001", "Reader goes blank", "chaos-rapid-tap"]
    csv_path = _write_raw(tmp_path / "narrow.csv", HEADER, [row])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "C0" in r.stdout


def test_c0_suppresses_downstream_field_checks(tmp_path):
    """Once the shape is wrong every field reading is untrustworthy, so the
    gate must not also emit a confident-but-meaningless C2/C4 about them."""
    row = ["F-001", "Borrow duplicates", "chaos-rapid-tap", "cold-launch",
           "chaos", "major", "true", "", "observed A", " then B", " then C",
           "steps", "", "", "notes", "", "", "SPILL"]
    csv_path = _write_raw(tmp_path / "shift.csv", HEADER, [row])
    r = _run(str(csv_path))
    assert r.returncode == 1
    assert "C0" in r.stdout
    assert "C2" not in r.stdout, "reported a shifted value as an illegal value"
    assert "C4" not in r.stdout


def test_correct_width_row_passes(tmp_path):
    """Clean-path assertion for C0."""
    row = ["F-001", "Reader goes blank", "chaos-rapid-tap", "cold-launch",
           "chaos", "major", "true", "", "observed A", "", "none", "steps",
           "", "", "notes", "", ""]
    csv_path = _write_raw(tmp_path / "ok.csv", HEADER, [row])
    r = _run(str(csv_path))
    assert r.returncode == 0, f"well-formed row rejected:\n{r.stdout}"
    assert "C0" not in r.stdout


def test_legacy_file_reports_corruption_without_failing(tmp_path):
    """Historical corpora stay passable, but the corruption is surfaced."""
    row = ["F-001", "t", "a", "c", "chaos", "major", "true", "", "obs",
           "s", "", "", "n", "", "", "SPILL"]
    csv_path = _write_raw(tmp_path / "legacy.csv", LEGACY_HEADER, [row])
    r = _run(str(csv_path))
    assert r.returncode == 0, "legacy contract broken"
    assert "C0" in r.stdout
    r2 = _run("--strict", str(csv_path))
    assert r2.returncode == 1


def test_missing_file_is_usage_error(tmp_path):
    r = _run(str(tmp_path / "absent.csv"))
    assert r.returncode == 2

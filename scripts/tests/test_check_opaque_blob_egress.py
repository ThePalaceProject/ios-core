"""Tests for check-opaque-blob-egress.py.

The pytest neighbour every detector in `scripts/` has (see
`scripts/tests/test_check_*.py`), required by CLAUDE.md rule 4.

The clean-diff arm matters as much as the violation arm. A detector that only
ever sees a violation in its tests can reject the interface it is actually
invoked with, and nobody finds out until it blocks every commit — that is the
wiring bug CLAUDE.md rule 4 exists for.

The first two tests are the real ones: the detector must fire on the line that
shipped in PR #1508 and must NOT fire on the line that replaced it.
"""

from __future__ import annotations

import importlib.util
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check-opaque-blob-egress.py"


def load_module():
    spec = importlib.util.spec_from_file_location("obe", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


obe = load_module()


# --------------------------------------------------------------- the predicate

def test_the_line_that_shipped_is_flagged():
    """The motivating defect, verbatim from 92142e6cf."""
    src = textwrap.dedent('''
        return ManagedLibraryDiagnostic(
            kind: .libraryNotFound,
            detail: "configuration \\(fingerprint) resolved to no library"
        )
    ''')
    assert len(obe.scan_text(src, "X.swift")) == 1


def test_the_line_that_replaced_it_is_not_flagged():
    """The fix must pass, or the gate punishes the correct code.

    `configuredValue` contains 'config' but does not END at it. An earlier,
    looser predicate flagged this line and missed the one above.
    """
    src = textwrap.dedent('''
        return ManagedLibraryDiagnostic(
            kind: .libraryNotFound,
            detail: "configured library \\(configuredValue) is not in the registry"
        )
    ''')
    assert obe.scan_text(src, "X.swift") == []


@pytest.mark.parametrize("identifier", [
    "payload", "rawPayload", "managedDictionary", "fingerprint",
    "identity", "userInfo", "responseBody", "self.configuration",
])
def test_blob_names_reaching_a_sink_are_flagged(identifier):
    src = f'TPPErrorLogger.logError(withCode: .x, summary: "s", metadata: ["d": "\\({identifier})"])'
    assert len(obe.scan_text(src, "X.swift")) == 1, identifier


@pytest.mark.parametrize("identifier", [
    "configuredValue", "identityProvider", "bodyText", "bookIdentifier",
    "payloadSize", "dictionaryKey",
])
def test_narrower_names_are_not_flagged(identifier):
    """Names that merely contain a blob noun describe a field, not a blob."""
    src = f'TPPErrorLogger.logError(withCode: .x, summary: "s", metadata: ["d": "\\({identifier})"])'
    assert obe.scan_text(src, "X.swift") == [], identifier


def test_a_blob_away_from_any_sink_is_not_flagged():
    """Interpolating a payload into a local log line is not egress."""
    src = 'Log.info(#file, "parsed \\(dictionary)")'
    assert obe.scan_text(src, "X.swift") == []


def test_a_multiline_call_still_associates():
    src = textwrap.dedent('''
        TPPErrorLogger.logError(
            withCode: .appLogicInconsistency,
            summary: "something",
            metadata: [
                "detail": "\\(payload)"
            ]
        )
    ''')
    assert len(obe.scan_text(src, "X.swift")) == 1


def test_suppression_requires_a_reason_marker():
    src = 'detail: "\\(payload)" // no-opaque-egress: every key here is ours'
    assert obe.scan_text(src, "X.swift") == []


# ------------------------------------------------------------------ the wiring

def _run(stdin: str, *args):
    return subprocess.run(
        ["python3", str(SCRIPT), *args],
        input=stdin, capture_output=True, text=True,
    )


def test_clean_diff_passes():
    """The arm that catches an interface mismatch before it blocks everything."""
    diff = textwrap.dedent('''
        diff --git a/Palace/A.swift b/Palace/A.swift
        --- a/Palace/A.swift
        +++ b/Palace/A.swift
        @@ -1,0 +2,1 @@
        +let x = 1
    ''').strip()
    r = _run(diff, "--quiet")
    assert r.returncode == 0, r.stdout + r.stderr


def test_empty_diff_passes():
    r = _run("", "--quiet")
    assert r.returncode == 0, r.stdout + r.stderr


def test_test_files_are_exempt():
    """A test may construct a foreign payload on purpose; that is its job."""
    assert not obe.is_production_swift("PalaceTests/Mocks/ForeignPayloadCanary.swift")
    assert obe.is_production_swift("Palace/AppInfrastructure/X.swift")


def test_the_tree_is_clean_today():
    """Calibration, asserted rather than claimed in a comment.

    If this fails, either somebody introduced a disclosure or the predicate
    drifted. Both are worth stopping for.
    """
    root = Path(__file__).resolve().parents[2] / "Palace"
    findings = obe.scan_tree(str(root))
    assert findings == [], "\n".join(str(f) for f in findings)

#!/usr/bin/env python3
"""
_checklib.py — shared primitives for the M1 pre-commit / verify-pr checks.

Extracted from the byte-identical copies that lived in check-blast-radius.py,
check-adjacency-staleness.py, check-intent-recorded.py,
check-superpartner-spectrum.py, and check-contract-reconciliation.py.

Three things live here, and only these three:

  1. read_diff(path)          — read a unified diff from a path / stdin / "-".
  2. SEVERITY_RANK + at_or_above(level, floor)
                              — the low/medium/high severity ladder.
  3. iter_hunk_lines(text)    — ONE diff-hunk parser yielding DiffLine records
                              (kind ∈ {"+","-"," "}, post-image file path,
                              post-image line number, text without the marker).

The per-check `_scan` / `_collect` semantic logic stays in each script; this
module only owns the mechanical, copy-pasted plumbing. iter_hunk_lines yields
*every* line (added / removed / context) so each consumer can rebuild exactly
the per-line state it needs (preceding-comment tracking, removed-line capture,
per-file LOC stats) without changing observable behavior.

Line-number semantics (matches the prior hand-rolled parsers):
  - The post-image counter resets to `start - 1` at each `@@ ... +start @@`
    hunk header and increments on added ("+") and context (" ") lines.
  - Removed ("-") lines do NOT advance the post-image counter; their `line_no`
    is reported as the current post-image position (the line they sit before).
  - `+++`/`---` file-marker lines are never yielded as content.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


# --- Severity ladder -------------------------------------------------------

SEVERITY_RANK = {"low": 0, "medium": 1, "high": 2}

# Backwards-compatible private alias for scripts that referenced the underscore
# name before extraction. New code should use SEVERITY_RANK.
_SEVERITY_RANK = SEVERITY_RANK


def at_or_above(level: str, floor: str) -> bool:
    """True if `level` is at or above `floor` on the severity ladder.

    Unknown level → 0 (lowest); unknown floor → 2 (highest). This matches the
    prior `_at_or_above` in every check script exactly.
    """
    return SEVERITY_RANK.get(level, 0) >= SEVERITY_RANK.get(floor, 2)


# --- Diff input ------------------------------------------------------------

def read_diff(path: str | None) -> str:
    """Read a unified diff from `path`, or stdin when `path` is None or "-".

    Exits with code 2 (the check-script convention) if a named file is missing.
    """
    if path is None or path == "-":
        return sys.stdin.read()
    p = Path(path)
    if not p.is_file():
        print(f"ERROR: diff file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return p.read_text(encoding="utf-8", errors="replace")


# --- Unified hunk parsing --------------------------------------------------

_FILE_HDR_RE = re.compile(r"^\+\+\+ b/(.+)$")
_HUNK_HDR_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


@dataclass
class DiffLine:
    kind: str        # "+" added, "-" removed, " " context
    file_path: str   # post-image path (from the `+++ b/...` header)
    line_no: int     # post-image line number (see module docstring)
    text: str        # line content with the leading +/-/space removed


def iter_hunk_lines(diff_text: str):
    """Yield a DiffLine for every added / removed / context line in `diff_text`.

    Lines that appear before any `+++ b/...` header (e.g. the `diff --git` and
    `index` preamble) are skipped, mirroring the prior parsers' `current_path is
    None` guard.
    """
    current_path: str | None = None
    current_line_no = 0
    for raw in diff_text.splitlines():
        m_file = _FILE_HDR_RE.match(raw)
        if m_file:
            current_path = m_file.group(1)
            current_line_no = 0
            continue
        if current_path is None:
            continue
        m_hunk = _HUNK_HDR_RE.match(raw)
        if m_hunk:
            current_line_no = int(m_hunk.group(1)) - 1
            continue
        if raw.startswith("+++") or raw.startswith("---"):
            continue
        if raw.startswith("+"):
            current_line_no += 1
            yield DiffLine("+", current_path, current_line_no, raw[1:])
            continue
        if raw.startswith("-"):
            # Removed lines do not advance the post-image counter; report them
            # at the current post-image position.
            yield DiffLine("-", current_path, current_line_no, raw[1:])
            continue
        if raw.startswith(" "):
            current_line_no += 1
            yield DiffLine(" ", current_path, current_line_no, raw[1:])
            continue
        # Any other line (e.g. "\ No newline at end of file") is ignored.

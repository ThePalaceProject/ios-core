#!/usr/bin/env python3
"""Fail a harness script that can `exit 0` while it did no work.

THE DEFECT (2026-08-20, release regression on the 3.3.0 candidate). Two steps of
the regression harness reported success while achieving nothing:

  * 21 area-worker shards skipped all 96 journeys, printed
    ``passed: 0 / failed: 0 / findings: 0``, and exited 0. The empty result
    merged into findings.csv and report.html as a CLEAN regression.
  * a chaos fan whose subagent was denied every simdrive tool logged
    "returned cleanly", synthesised a 0-finding summary, and moved on.

Both are one shape: **the script counted its work, printed the count, and then
returned success without ever asking whether the count was zero.** "Ran and
found nothing" and "never ran" were rendered identically downstream. The
information existed in the local output; nothing acted on it.

WHAT THIS FLAGS. A shell script that

  1. maintains a work counter (a variable whose name ends in ``_count`` /
     ``_COUNT`` / ``_counter``),
  2. SUMMARISES it — prints it in an echo/printf, i.e. it is a reported result,
     not an internal loop index, and
  3. can reach a terminal ``exit 0`` (or simply falls off the end) without any
     conditional that compares a counter against zero and exits non-zero.

WHAT IT DOES NOT FLAG, deliberately:

  * a script with a zero-guard — the guard need only compare a counter to zero
    (or to a before/after baseline) and take a non-zero exit in that branch.
    ``regression-area-worker.sh``'s NO-COVERAGE block is the reference shape.
  * a script whose counters are never printed. An internal counter is not a
    reported result and gating on it would be noise.
  * ``exit 0`` inside ``--help`` / ``--dry-run`` early-outs: those are not
    terminal (the script has more to say after them), and a usage dump is not a
    claim about work done.
  * anything inside a heredoc — embedded Python/SQL is not this script's control
    flow. Heredoc bodies are stripped before analysis.

Usage::

    python3 scripts/check-silent-success.py FILE [FILE ...]
    python3 scripts/check-silent-success.py --default-set   # the harness scan set

Exit 0 clean, 1 on a finding, 2 on a usage error.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: Scripts whose success value is consumed by a campaign that renders a verdict.
#: These are the ones where a false green is expensive; the check is deliberately
#: NOT run over every script in the repo.
DEFAULT_SET_GLOBS = [
    "scripts/regression-*.sh",
    "scripts/run-chaos-pass.sh",
]

COUNTER_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*_(?:count|counter)$", re.IGNORECASE)

#: Counters that measure what was FOUND, not what was RUN. A real pass
#: legitimately finds nothing, so gating on these would block clean runs — the
#: discriminator has to be executed work. `finding_count` alone is never enough
#: to demand a guard; `pass_count` / `skip_count` are.
RESULT_COUNTER = re.compile(r"(?:finding|issue|bug|defect|error|warn)", re.IGNORECASE)

_ASSIGN = re.compile(r"^\s*(?:local\s+|declare\s+(?:-\w+\s+)?|export\s+)?"
                     r"([A-Za-z_][A-Za-z0-9_]*)\s*=")
_ARITH = re.compile(r"\(\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+\+|--|\+=|-=)")
_ECHO = re.compile(r"^\s*(?:echo|printf)\b")
_EXIT = re.compile(r"^(\s*)exit\s+(\d+)\s*(?:#.*)?$")
_ZERO_CMP = re.compile(
    r"-(?:eq|ne|gt|ge|lt|le)\s+[\"']?0[\"']?"     # [ $n -eq 0 ]
    r"|[\"']?0[\"']?\s+-(?:eq|ne|gt|ge|lt|le)\b"  # [ 0 -lt $n ]
    r"|[=!]=\s*[\"']?0[\"']?"                     # (( n == 0 )) / [ "$n" != "0" ]
    r"|-(?:eq|ne|gt|ge|lt|le)\s+1\b"              # -lt 1 is "is zero"
)
_COND_START = re.compile(r"^\s*(?:if|elif)\b|^\s*\[\[?.*\]\]?\s*(?:&&|\|\|)")


def _strip_heredocs(text: str) -> List[str]:
    """Blank out heredoc BODIES so embedded languages are not read as shell."""
    lines = text.splitlines()
    out: List[str] = []
    delim: Optional[str] = None
    dash = False
    open_re = re.compile(r"<<(-?)\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")
    for line in lines:
        if delim is not None:
            candidate = line.strip() if dash else line.rstrip()
            if candidate == delim:
                delim = None
            out.append("")
            continue
        out.append(line)
        m = open_re.search(line)
        if m:
            dash = bool(m.group(1))
            delim = m.group(2)
    return out


def _strip_comment(line: str) -> str:
    """Drop a trailing comment, respecting quotes.

    A detector that reads comments reports the DISCUSSION of a defect as the
    defect (this repo has been bitten by exactly that). Whole-line comments and
    trailing comments both go.
    """
    out = []
    quote: Optional[str] = None
    prev = ""
    for ch in line:
        if quote:
            if ch == quote and prev != "\\":
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (not out or out[-1] in " \t"):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def _analyse(lines: List[str]) -> Dict:
    counters: set[str] = set()
    summarised: set[str] = set()
    exits: List[Tuple[int, int, int]] = []          # (idx, indent, code)
    guards: List[Tuple[int, str]] = []              # (idx, counter)

    for i, raw in enumerate(lines):
        line = _strip_comment(raw)
        if not line.strip():
            continue

        m = _ASSIGN.match(line)
        if m and COUNTER_NAME.match(m.group(1)):
            counters.add(m.group(1))
        for m in _ARITH.finditer(line):
            if COUNTER_NAME.match(m.group(1)):
                counters.add(m.group(1))
        # `x_count=$((x_count + 1))` is caught by _ASSIGN above.

        e = _EXIT.match(line)
        if e:
            exits.append((i, len(e.group(1)), int(e.group(2))))

    for i, raw in enumerate(lines):
        line = _strip_comment(raw)
        if _ECHO.match(line):
            for name in counters:
                if f"${name}" in line or f"${{{name}}}" in line:
                    summarised.add(name)
        if _COND_START.match(line) and _ZERO_CMP.search(line):
            for name in counters:
                if f"${name}" in line or f"${{{name}}}" in line or \
                        re.search(rf"\b{re.escape(name)}\b\s*[=!<>]", line):
                    guards.append((i, name))

    return {
        "counters": counters,
        "summarised": summarised,
        "exits": exits,
        "guards": guards,
    }


_INLINE_EXIT = re.compile(r"\bexit\s+([1-9]\d*)\b")
_DIE_CALL = re.compile(r"(?:^|;|&&|\|\||\bthen\b)\s*(?:die|abort|fatal)\b")


def _guard_exits_nonzero(lines: List[str], start: int) -> bool:
    """Does the conditional beginning at `start` take a non-zero exit?"""
    # `if [ "$n" -eq 0 ]; then exit 3; fi` — the whole guard on one line.
    head = _strip_comment(lines[start])
    if _INLINE_EXIT.search(head) or _DIE_CALL.search(head):
        return True

    base_indent = len(lines[start]) - len(lines[start].lstrip())
    for j in range(start + 1, len(lines)):
        line = _strip_comment(lines[j])
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip())
        if stripped.startswith("fi") and indent <= base_indent:
            return False
        m = _EXIT.match(line)
        if m and int(m.group(2)) != 0:
            return True
        # `die ...` / `abort ...` helpers exit non-zero by construction.
        if re.match(r"^\s*(?:die|abort|fatal)\b", line):
            return True
    return False


def _terminal_exit_zero(lines: List[str], exits: List[Tuple[int, int, int]]) -> Optional[int]:
    """Line index of a terminal `exit 0`, or None.

    Terminal = a top-level (unindented) `exit 0` with no further executable
    statement after it, or the script simply running off the end. An early
    `exit 0` in a `--help` branch is not terminal.
    """
    last_code = None
    for i in range(len(lines) - 1, -1, -1):
        stripped = _strip_comment(lines[i]).strip()
        if stripped:
            last_code = i
            break
    if last_code is None:
        return None
    for idx, indent, code in exits:
        if idx == last_code and indent == 0 and code == 0:
            return idx
    # Falls off the end without an explicit exit: that is also exit 0.
    if not _EXIT.match(_strip_comment(lines[last_code])):
        return last_code
    return None


def check_file(path: str, rel: str) -> List[str]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        return [f"{rel}: could not read ({exc})"]

    lines = _strip_heredocs(text)
    info = _analyse(lines)

    work = {n for n in info["summarised"] if not RESULT_COUNTER.search(n)}
    if not work:
        return []

    terminal = _terminal_exit_zero(lines, info["exits"])
    if terminal is None:
        return []

    for idx, name in info["guards"]:
        if _guard_exits_nonzero(lines, idx):
            return []

    reported = ", ".join(sorted(work))
    return [
        f"{rel}:{terminal + 1}: reaches a terminal `exit 0` with no zero-work "
        f"guard, while summarising {reported}. A run in which those counters are "
        f"0 exits SUCCESS and is indistinguishable downstream from a run that "
        f"did the work and found nothing. Add a conditional that compares a "
        f"counter against 0 and exits non-zero (see the NO-COVERAGE block in "
        f"scripts/regression-area-worker.sh)."
    ]


def resolve_default_set() -> List[str]:
    out: List[str] = []
    for pattern in DEFAULT_SET_GLOBS:
        out.extend(sorted(glob.glob(os.path.join(REPO, pattern))))
    return out


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", help="shell scripts to check")
    ap.add_argument("--default-set", action="store_true",
                    help=f"check the harness scan set ({', '.join(DEFAULT_SET_GLOBS)})")
    args = ap.parse_args(argv[1:])

    files = list(args.files)
    if args.default_set or not files:
        files.extend(resolve_default_set())
    if not files:
        print("error: no files to check", file=sys.stderr)
        return 2

    problems: List[str] = []
    for path in files:
        rel = os.path.relpath(path, REPO)
        if rel.startswith(".."):        # outside the repo (a test fixture)
            rel = path
        problems.extend(check_file(path, rel))

    if problems:
        print(f"{len(problems)} script(s) can report success on zero work:\n")
        for p in problems:
            print(f"  {p}\n")
        print("A green result is self-camouflaging: the run that proves nothing "
              "looks exactly like the run that proves everything passed.")
        return 1

    print(f"ok: {len(files)} script(s); none can exit 0 on zero counted work")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

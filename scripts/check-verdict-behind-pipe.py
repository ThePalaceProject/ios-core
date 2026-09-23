#!/usr/bin/env python3
"""check-verdict-behind-pipe.py — a verdict must not be read from the wrong command.

In a shell pipeline the exit status belongs to the LAST command, not to the one
whose success you care about. `xcodebuild ... | tee build.log` reports whether
`tee` could write a file. `git ls-files | grep -q foo` after a build reports
whether grep matched, which is a different question from whether the build
worked. Without `set -o pipefail` the status of everything upstream is discarded
silently, and the discard looks exactly like a pass.

The same defect wears a second costume: `$?` read after a trailing `echo`. A
compound command that ends by announcing its own completion overwrites the
status being announced, so the check reports on the announcement.

Both fail toward "fine" — which is the property that makes them expensive. A
mechanism that fails loudly costs an hour; one that fails quietly costs whatever
is built on top of it, for as long as nobody looks, and nobody looks because it
passed.

Three instances inside one day (2026-08-26) are what turned this from a written
warning into a gate: a build reported as succeeding when xcodebuild had bailed;
a release-archaeology sweep that returned false zeros; and a verify-pr run whose
real exit of 1 was masked by a trailing echo. In each case the agent had read
the warning already. Warnings lose to habit; gates do not.

WHAT IT FLAGS

  P1  A pipeline whose exit status is consumed, in a script that never sets
      `-o pipefail`. Consumption means: used as an `if`/`while`/`until`
      condition, joined with `&&`/`||`, or followed by a read of `$?`.

  P2  A read of `$?` where the preceding line is a command that cannot fail
      (`echo`, `printf`, `:`, `true`). The status being tested is the
      announcement's, never the work's.

WHAT IT DELIBERATELY DOES NOT FLAG

  - Pipelines whose status is discarded entirely (`cmd | tee log` on its own
    line). Nothing is claimed, so nothing can be falsely claimed.
  - `grep`/`test` pipelines inside a condition where grep IS the question
    (`ps aux | grep -q foo`) — these are matched by an allowlist of terminal
    commands whose own status is the intended verdict, provided the upstream
    is a pure data source.
  - Scripts that set `-o pipefail` anywhere before the pipeline. pipefail makes
    the pipeline's status honest, which is the fix, so its presence is a pass.

USAGE

  check-verdict-behind-pipe.py                 # scan the whole tree
  check-verdict-behind-pipe.py --diff [BASE]   # only files changed vs BASE
  check-verdict-behind-pipe.py FILE [FILE...]  # explicit files

Exit 0 clean, 1 on any violation. There is deliberately NO baseline: the tree
scans clean today, and an amnesty file that can never fire is dead machinery
that reads like a safety net. If a future violation genuinely needs amnesty,
add it then — with the reason attached.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Commands whose own exit status is legitimately the verdict when they terminate
# a pipeline — the upstream is feeding them data, not doing the work being judged.
TERMINAL_PREDICATES = {"grep", "egrep", "fgrep", "rg", "test", "["}

# Commands that only emit data and cannot meaningfully fail. When EVERY upstream
# stage is one of these, the pipeline's status is already the last stage's, and
# the last stage is the work — so `$?` is honest and there is nothing to flag.
#
# This distinction is the whole precision of the gate. `echo "$JSON" | bash hook`
# then `$?` reads the hook's status, which is correct; `xcodebuild | tee log`
# then `$?` reads tee's, which is not. Both are "a pipeline followed by $?", and
# only the position of the real work separates them. Flagging the first would
# make this gate cry wolf on the repo's own hook fixture — a detector reporting
# a verdict it has not earned, which is the exact defect it exists to catch.
PURE_EMITTERS = {"echo", "printf", ":", "true", "yes"}

# Commands that cannot meaningfully fail, so a `$?` measuring one measures nothing.
ALWAYS_SUCCEEDS = re.compile(r"^\s*(echo|printf|:|true)\b")

PIPEFAIL = re.compile(r"set\s+[-+][a-zA-Z]*\s*-?o\s+pipefail|set\s+-o\s+pipefail")

# A line that consumes a status: an if/while/until condition, or a && / || join.
CONDITION_START = re.compile(r"^\s*(if|while|until|elif)\s+")
# `|| true`, `|| :` — an explicit discard. Nothing is claimed, so nothing can be
# falsely claimed, and flagging it would push authors toward removing a
# deliberate and correct suppression.
EXPLICIT_DISCARD = re.compile(r"\|\|\s*(true|:)\s*[;)}&|]|\|\|\s*(true|:)\s*$")
STATUS_READ = re.compile(r"\$\?")

SHEBANG = re.compile(rb"^#!.*\b(bash|sh|zsh)\b")


def quote_state_after(line: str, start: str | None) -> str | None:
    """The open-quote character left dangling at end of line, or None.

    Shell strings span lines freely, and a multi-line single-quoted block is how
    every embedded language gets passed to a tool — jq programs, python -c,
    awk scripts, SQL. Inside one, `|` and `$?` belong to that language. Tracking
    quote state only within a line reads jq's `($pr | length)` as a shell
    pipeline and reports a confident finding about code that is not shell.
    """
    quote = start
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            break
        i += 1
    return quote

# `<<EOF`, `<<-'EOF'`, `<<"EOF"` — the tag closes the block when it appears
# alone on a line (`<<-` also allows leading tabs, which .strip() covers).
HEREDOC_OPEN = re.compile(r"<<-?\s*(?P<tag>[\'\"]?[A-Za-z_][A-Za-z0-9_]*[\'\"]?)\s*$")


def is_shell_script(path: Path) -> bool:
    if path.suffix in {".sh", ".bash", ".zsh"}:
        return True
    try:
        with path.open("rb") as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


def strip_comment(line: str) -> str:
    """Remove a trailing comment, respecting quotes crudely but adequately.

    Crude is correct here: the goal is to avoid flagging a pipe that only ever
    appears inside prose, and a quote-aware scan is enough for that. A shell
    parser would be more precise and would also be a dependency this repo does
    not have.
    """
    out: list[str] = []
    quote: str | None = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                quote = None
            out.append(ch)
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out)


def status_read_unquoted(code: str) -> bool:
    """True when `$?` appears outside quotes — an actual read, not prose.

    A test fixture here documents this very bug pattern inside an echo. Flagging
    a script for *describing* the defect it guards against is the cry-wolf
    failure that gets a gate switched off.
    """
    quote: str | None = None
    i = 0
    while i < len(code):
        ch = code[i]
        if quote:
            if ch == quote and code[i - 1] != "\\":
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        if ch == "$" and i + 1 < len(code) and code[i + 1] == "?":
            return True
        i += 1
    return False


def command_precedes_status_read(code: str) -> bool:
    """True when a command runs on this same line before `$?` is read.

    `"$DET" args >/dev/null 2>&1; rc=$?` is correct — the status belongs to the
    detector invocation immediately to its left, whatever sat on the line above.
    Only a `$?` with no same-line command before it inherits the previous line.
    """
    head = code.split("$?", 1)[0]
    return bool(re.search(r"[;&]\s*\S", head))


def last_stage_command(code: str) -> str:
    """The bare command name at the end of the final pipeline stage."""
    return bare_command(split_pipeline(code)[-1])


def has_pipe(code: str) -> bool:
    """A real pipe, not `||` and not a quoted bar."""
    return len(split_pipeline(code)) > 1


def upstream_is_pure(code: str) -> bool:
    """True when every stage before the last only emits data.

    `echo "$JSON" | bash hook` — the hook is the work and its status is what
    `$?` returns, so there is nothing to warn about. `xcodebuild | tee log` —
    the work is upstream and its status is thrown away. Same syntax, opposite
    verdicts, and this is the function that tells them apart.
    """
    stages = split_pipeline(code)
    if len(stages) < 2:
        return False
    return all(bare_command(s) in PURE_EMITTERS for s in stages[:-1])


def split_pipeline(code: str) -> list[str]:
    """Split on real pipes only — not `||`, not a bar inside quotes."""
    stages: list[str] = []
    quote: str | None = None
    buf: list[str] = []
    i = 0
    while i < len(code):
        ch = code[i]
        if quote:
            if ch == quote and code[i - 1] != "\\":
                quote = None
            buf.append(ch)
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "|":
            if i + 1 < len(code) and code[i + 1] == "|":
                buf.append("||")
                i += 2
                continue
            stages.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    stages.append("".join(buf))
    return stages


def bare_command(stage: str) -> str:
    """The command name at the head of a pipeline stage, stripped of prefixes."""
    s = stage.strip()
    # Strip an assignment target, a condition keyword, and any opening bracket.
    s = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*=\$?\(", "", s)
    s = re.sub(r"^(if|while|until|elif|then|do)\s+", "", s.strip())
    s = s.lstrip("$({[ \t!")
    for token in s.split():
        if "=" in token and not token.startswith("-"):
            continue
        return os.path.basename(token.strip("\"'"))
    return ""


def scan_file(path: Path) -> list[tuple[int, str, str]]:
    """Return (lineno, pattern_id, source_line) for each violation."""
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return []

    lines = text.splitlines()
    pipefail_at = None
    for idx, raw in enumerate(lines):
        if PIPEFAIL.search(strip_comment(raw)):
            pipefail_at = idx
            break

    findings: list[tuple[int, str, str]] = []
    prev_code = ""
    heredoc_terminator: str | None = None
    open_quote: str | None = None

    for idx, raw in enumerate(lines):
        # Continuation of a multi-line quoted string: data, not shell.
        if open_quote is not None:
            open_quote = quote_state_after(raw, open_quote)
            continue
        line_end_quote = quote_state_after(raw, None)
        # Inside a heredoc the text is data for another language — jq, python,
        # awk, SQL — whose `|` and `$?` mean something else entirely. Scanning
        # it as shell produces confident nonsense.
        if heredoc_terminator is not None:
            if raw.strip() == heredoc_terminator:
                heredoc_terminator = None
            continue

        opener = HEREDOC_OPEN.search(strip_comment(raw))
        if opener:
            heredoc_terminator = opener.group("tag").strip("\'\"")
            continue

        code = strip_comment(raw).rstrip()
        if line_end_quote is not None:
            # This line OPENS a multi-line string. Its shell prefix is still
            # scannable, but the dangling quote must be carried forward.
            open_quote = line_end_quote
        if not code.strip():
            continue

        protected = pipefail_at is not None and idx > pipefail_at

        # P1 — a pipeline whose status is consumed, with pipefail not in force.
        if not protected and has_pipe(code):
            consumed = bool(CONDITION_START.match(code)) or "&&" in code or "||" in code
            if EXPLICIT_DISCARD.search(code):
                consumed = False
            if (consumed
                    and last_stage_command(code) not in TERMINAL_PREDICATES
                    and not upstream_is_pure(code)):
                findings.append((idx + 1, "P1", raw.strip()))

        # P2 — `$?` read immediately after a command that cannot fail.
        if status_read_unquoted(code) and ALWAYS_SUCCEEDS.match(prev_code) \
                and not command_precedes_status_read(code):
            findings.append((idx + 1, "P2", raw.strip()))

        # P1b — `$?` read on the line after an unprotected pipeline.
        if not protected and status_read_unquoted(code) and has_pipe(prev_code) \
                and not command_precedes_status_read(code):
            if (last_stage_command(prev_code) not in TERMINAL_PREDICATES
                    and not upstream_is_pure(prev_code)):
                findings.append((idx + 1, "P1", raw.strip()))

        prev_code = code

    return findings


def changed_files(base: str) -> list[Path]:
    try:
        merge_base = subprocess.run(
            ["git", "merge-base", base, "HEAD"],
            capture_output=True, text=True, cwd=REPO_ROOT, check=False,
        ).stdout.strip() or base
        out = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=ACMR", f"{merge_base}..HEAD"],
            capture_output=True, text=True, cwd=REPO_ROOT, check=False,
        ).stdout
    except OSError:
        return []
    return [REPO_ROOT / p for p in out.split() if p]


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, cwd=REPO_ROOT, check=False
    ).stdout
    return [REPO_ROOT / p for p in out.split() if p]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", help="explicit files to scan")
    ap.add_argument("--diff", nargs="?", const="origin/develop", default=None,
                    help="scan only files changed vs BASE (default origin/develop)")
    args = ap.parse_args()

    if args.files:
        candidates = [Path(f) for f in args.files]
    elif args.diff:
        candidates = changed_files(args.diff)
    else:
        candidates = tracked_files()

    targets = [p for p in candidates if p.is_file() and is_shell_script(p)]

    findings: list[tuple[str, int, str, str]] = []
    for path in sorted(targets):
        rel = os.path.relpath(path, REPO_ROOT)
        for lineno, pat, src in scan_file(path):
            findings.append((rel, lineno, pat, src))

    new = sorted({f"{rel}:{pat}:{src}" for rel, _, pat, src in findings})

    if not new:
        print(f"[verdict-behind-pipe] clean — {len(targets)} shell script(s) scanned")
        return 0

    if new:
        print("[verdict-behind-pipe] a verdict is being read from the wrong command:\n",
              file=sys.stderr)
        for rel, lineno, pat, src in findings:
            if f"{rel}:{pat}:{src}" in new:
                why = ("the pipeline's status is the LAST stage's, and pipefail is not set"
                       if pat == "P1" else
                       "$? here is the preceding echo/printf's status, not the work's")
                print(f"  {rel}:{lineno}\n      {src}\n      -> {why}\n", file=sys.stderr)
        print("  Fix: `set -o pipefail` near the top, or capture the status of the\n"
              "  command you actually mean (`cmd > log; rc=$?`), or use PIPESTATUS.\n",
              file=sys.stderr)


    return 1


if __name__ == "__main__":
    sys.exit(main())

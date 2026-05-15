#!/usr/bin/env python3
"""post-mutation-pr-comment.py — render a PR comment from palace_mutate JSON reports.

Reads every per-file JSON report produced by palace_mutate.py / verify-pr.sh
out of a reports directory (default: .forgeos/mutation-reports) and emits a
markdown table:

    | File | Killed | Survived | Kill Rate |
    |---|---|---|---|
    | Palace/SignInLogic/TPPSignInBusinessLogic.swift | 4 | 0 | 100% |
    | Palace/MyBooks/BorrowOperation.swift           | 3 | 1 |  75% |

A second pass groups critical-path files (Palace/Audiobooks/,
Palace/SignInLogic/, Palace/MyBooks/Download*) at the top so reviewers see
the user-money paths first; non-critical files follow.

Usage:
    # Just print the table to stdout (for local inspection):
    scripts/post-mutation-pr-comment.py --reports-dir .forgeos/mutation-reports

    # Post directly to a PR using gh:
    scripts/post-mutation-pr-comment.py \
      --reports-dir .forgeos/mutation-reports \
      --pr 1234 \
      --post

The CI workflow .github/workflows/mutation-on-pr.yml shells out to this
script with --post so the comment lands automatically on every PR run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

# Mirrors verify-pr.sh CRITICAL_MUTATION_PATHS_REGEX. Kept inline (not
# imported) because verify-pr.sh is bash and this script needs to run in
# isolation from CI without touching the orchestration shell.
CRITICAL_PREFIXES = (
    "Palace/Audiobooks/",
    "Palace/SignInLogic/",
    "Palace/MyBooks/Download",
)


def is_critical(path: str) -> bool:
    return any(path.startswith(p) for p in CRITICAL_PREFIXES)


def load_reports(reports_dir: Path) -> list[dict]:
    """Load every *.json file in reports_dir, returning rows for the table.

    Each row: {file, killed, survived, errored, kill_rate, critical}.
    Files that fail to parse are surfaced as-is so the table never lies about
    "0 survivors" when the truth is "report unreadable".
    """
    rows: list[dict] = []
    if not reports_dir.is_dir():
        return rows
    for path in sorted(reports_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            rows.append({
                "file": path.stem,
                "killed": None,
                "survived": None,
                "errored": None,
                "kill_rate": None,
                "critical": False,
                "error": str(exc),
            })
            continue

        summary = data.get("summary", {}) or {}
        killed = int(summary.get("killed", 0) or 0)
        survived = int(summary.get("survived", 0) or 0)
        errored = int(summary.get("errored", 0) or 0)
        total = killed + survived
        rate = (killed / total * 100.0) if total > 0 else None
        file_path = data.get("file") or path.stem
        rows.append({
            "file": file_path,
            "killed": killed,
            "survived": survived,
            "errored": errored,
            "kill_rate": rate,
            "critical": is_critical(file_path),
            "error": None,
        })
    return rows


def render_table(rows: list[dict], threshold: float) -> str:
    """Return a markdown comment body. Empty reports → friendly skip note."""
    if not rows:
        return (
            "### Mutation gate — no kill-rate data\n"
            "\n"
            "No per-file JSON reports were produced for this run. Either no "
            "production Swift files changed, or palace_mutate.py was unable to "
            "run (check the workflow log).\n"
        )

    lines: list[str] = []
    lines.append("### Mutation gate — kill rates per changed file")
    lines.append("")
    lines.append(f"Threshold: **{threshold:g}%** "
                 "(critical paths strict, others advisory)")
    lines.append("")
    lines.append("| File | Killed | Survived | Kill Rate | Verdict |")
    lines.append("|---|---:|---:|---:|---|")

    # Sort: critical first, then by kill rate ascending so the weakest
    # files are most visible (the gate is about exposing weak coverage).
    def sort_key(r: dict):
        critical_rank = 0 if r["critical"] else 1
        rate = r["kill_rate"] if r["kill_rate"] is not None else -1.0
        return (critical_rank, rate, r["file"])

    rows_sorted = sorted(rows, key=sort_key)

    strict_failures = 0
    advisory_warnings = 0
    for r in rows_sorted:
        if r.get("error"):
            lines.append(f"| {r['file']} | — | — | parse error | "
                         f"`{r['error']}` |")
            continue
        if r["kill_rate"] is None:
            verdict = "no mutants"
        elif r["kill_rate"] >= threshold:
            verdict = "PASS" if not r["critical"] else "PASS (critical)"
        elif r["critical"]:
            verdict = f"FAIL (critical, < {threshold:g}%)"
            strict_failures += 1
        else:
            verdict = f"advisory (< {threshold:g}%)"
            advisory_warnings += 1

        rate_cell = (
            f"{r['kill_rate']:.0f}%" if r["kill_rate"] is not None else "—"
        )
        critical_marker = " *(critical path)*" if r["critical"] else ""
        lines.append(
            f"| `{r['file']}`{critical_marker} | "
            f"{r['killed']} | {r['survived']} | {rate_cell} | {verdict} |"
        )

    lines.append("")

    # Footer summary so the reader doesn't have to scan every row to know
    # whether anything blocks merge.
    if strict_failures > 0:
        lines.append(
            f"**{strict_failures} critical-path file(s) below "
            f"{threshold:g}% — gate blocks merge.**"
        )
    elif advisory_warnings > 0:
        lines.append(
            f"{advisory_warnings} advisory warning(s) — review encouraged "
            "but not blocking."
        )
    else:
        lines.append("All changed files meet the kill-rate floor.")
    return "\n".join(lines)


def post_comment(pr: str, body: str) -> int:
    """Post via gh pr comment. Returns the exit code of the gh invocation."""
    proc = subprocess.run(
        ["gh", "pr", "comment", pr, "--body-file", "-"],
        input=body,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
    else:
        sys.stdout.write(proc.stdout)
    return proc.returncode


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--reports-dir",
        type=Path,
        default=Path(".forgeos/mutation-reports"),
        help="Directory containing per-file palace_mutate JSON reports.",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=50.0,
        help="Kill-rate floor for verdict column (default 50%%).",
    )
    parser.add_argument(
        "--pr",
        type=str,
        help="PR number to comment on (with --post).",
    )
    parser.add_argument(
        "--post",
        action="store_true",
        help="Actually post the comment via gh pr comment.",
    )
    parser.add_argument(
        "--fail-on-critical",
        action="store_true",
        help="Exit non-zero when any critical-path row falls below threshold.",
    )
    args = parser.parse_args(argv)

    rows = load_reports(args.reports_dir)
    body = render_table(rows, args.threshold)
    print(body)

    if args.post:
        if not args.pr:
            sys.stderr.write("--post requires --pr <NUMBER>\n")
            return 2
        rc = post_comment(args.pr, body)
        if rc != 0:
            return rc

    if args.fail_on_critical:
        for r in rows:
            if (
                r.get("critical")
                and r.get("kill_rate") is not None
                and r["kill_rate"] < args.threshold
            ):
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

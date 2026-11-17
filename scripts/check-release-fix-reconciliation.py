#!/usr/bin/env python3
"""
check-release-fix-reconciliation.py — block shipping a release that is missing
crash / critical-path fixes which have already landed on the integration branch.

WHY THIS EXISTS (the 3.2.0 saveSync-deadlock retro)
  The #1 crash on 3.2.0 (a BookRegistrySync.saveSync dispatch-reentrancy
  deadlock, 6 patrons) was ALREADY fixed on develop — PR #1097 landed there on
  2026-06-22, sixteen days before 3.2.0 shipped on 2026-07-08. It slipped only
  because the release branch was cut on 2026-06-17 (before the fix) and NOTHING
  reconciled "what crash/critical-path fixes landed on develop after the cut"
  against the pending release. The fix existed, was tested, and sat in the
  dashboard — the release process just never connected it to the release.

  This gate closes that gap: before promoting a release, diff
  `release..develop` for crash / critical-path fix commits that have NO
  equivalent on the release branch, and force an explicit cherry-pick-or-waive
  decision on each. Unreconciled critical fixes block the release.

HOW
  `git cherry <release-ref> <develop-ref>` is the load-bearing primitive: it
  compares by PATCH-ID, so a commit that was cherry-picked into the release
  (different SHA, same change) is correctly reported as already present ("-").
  Only commits with no equivalent on the release ("+") are candidates. We then
  keep the ones that (a) touch a critical-path file OR (b) read as a crash/bug
  fix from the subject line, and fail on any that are not explicitly waived.

REVERSE DIRECTION (the PP-5389 retro)
  A fix can also land on the release branch and never reach develop: #1717
  (e84eb80ae) defaulted LCP streaming on for release/3.4.0 only, its ticket
  was closed, and develop kept the old default. So the gate also runs
  `git cherry <develop-ref> <release-ref>` and flags every non-merge release
  commit with no patch-equivalent on develop. No subject or path filter
  applies here: #1717 had no fix wording, and on recent releases this set is
  small (3.2.0: 0, 3.3.0: 0, 3.4.0: 1). A forward-port whose patch differs
  (conflict resolution) still counts when a develop commit since the merge
  base names the release commit's `#<pr>` or full SHA (`cherry-pick -x`).
  Release-only commits such as build bumps are waived like any other.

WAIVERS
  A waiver file (default `config/ci/release-waivers/<release>.txt`, override with
  --waiver-file) lists, one per line, `<sha-or-pr> <reason>`. A candidate is
  reconciled if its abbreviated SHA, full SHA, or `#<pr>` appears as the first
  token of a waiver line. Blank lines and `#`-comments are ignored. Waiving
  leaves an audit trail — the point is a deliberate decision, not silence.

USAGE
  check-release-fix-reconciliation.py --release-ref release/3.2.0 \
      [--develop-ref origin/develop] [--waiver-file PATH] [--quiet]

EXIT CODES
  0  every crash/critical-path fix on develop is either present on the release
     or explicitly waived, and every release commit is on develop or waived.
  1  one or more unreconciled commits in either direction (printed).
  2  usage / git error (bad ref, not a repo).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys


# Critical-path file globs — a fix touching any of these is release-sensitive.
# Mirrors the project's critical-path posture (auth / DRM / borrow / return /
# download / audiobook / registry / migration / network executor). Override
# with --critical-path-regex for a different tree.
DEFAULT_CRITICAL_PATH_REGEX = (
    r"(SignIn|Accounts|Keychain|DRM|LCP|Adobe|Borrow|Return|Download"
    r"|Audiobook|BookRegistry|Registry|Migration|TPPNetworkExecutor"
    r"|TPPNetworkResponder|TPPNetworkQueue|Fulfillment|Bookmark)"
)

# Subject-line signals that a commit is a crash / correctness fix even when it
# does not touch a path we flagged (e.g. a fix in a util the app depends on).
DEFAULT_FIX_SUBJECT_REGEX = (
    r"\b(fix|crash|deadlock|race|data.?race|leak|hang|freeze|reentran"
    r"|concurren|EXC_|SIG[A-Z]+|use.after.free|npe|nil.?unwrap)\b"
)


def _run_git(args: list[str]) -> str:
    """Run a git command, returning stdout. Raises on non-zero exit."""
    proc = subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}"
        )
    return proc.stdout


def _cherry_candidates(release_ref: str, develop_ref: str) -> list[str]:
    """SHAs on develop_ref with NO patch-equivalent on release_ref.

    `git cherry <upstream> <head>` prints `+ <sha>` for head commits missing
    from upstream and `- <sha>` for those already present (by patch-id).
    """
    out = _run_git(["cherry", release_ref, develop_ref])
    shas = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("+ "):
            shas.append(line[2:].strip())
    return shas


def _commit_subject(sha: str) -> str:
    return _run_git(["log", "-1", "--format=%s", sha]).strip()


def _commit_files(sha: str) -> list[str]:
    out = _run_git(["show", "--name-only", "--format=", sha])
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def _commit_pr_number(sha: str) -> str | None:
    """Extract a squash-merge PR number `(#1234)` from the subject, if any."""
    subject = _commit_subject(sha)
    m = re.search(r"\(#(\d+)\)", subject)
    return m.group(1) if m else None


def _load_waivers(path: str | None, release_ref: str) -> set[str]:
    """First token of each non-comment line: an SHA (any length) or `#<pr>`."""
    if path is None:
        safe = release_ref.replace("/", "-")
        path = os.path.join("config", "ci", "release-waivers", f"{safe}.txt")
    tokens: set[str] = set()
    if not os.path.exists(path):
        return tokens
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            # Skip blanks and comments — but `#1234` (hash + digit) is a PR-number
            # waiver token, NOT a comment. Only `#` followed by whitespace or a
            # non-digit is a comment.
            if not line:
                continue
            if line.startswith("#") and not line[1:2].isdigit():
                continue
            tokens.add(line.split()[0])
    return tokens


def _is_waived(sha: str, pr: str | None, waivers: set[str]) -> bool:
    if not waivers:
        return False
    # Match on full sha, any abbreviation that is a prefix, or #<pr>.
    for token in waivers:
        t = token.lstrip("#")
        if sha == token or sha.startswith(t) or (pr is not None and t == pr):
            return True
    return False


def evaluate(
    release_ref: str,
    develop_ref: str,
    critical_path_regex: str,
    fix_subject_regex: str,
    waiver_file: str | None,
) -> tuple[list[dict], list[dict]]:
    """Return (unreconciled, waived) candidate lists.

    A candidate is a commit on develop with no patch-equivalent on the release
    that is EITHER critical-path (touches a flagged file) OR reads as a fix.
    """
    path_re = re.compile(critical_path_regex)
    subj_re = re.compile(fix_subject_regex, re.IGNORECASE)
    waivers = _load_waivers(waiver_file, release_ref)

    unreconciled: list[dict] = []
    waived: list[dict] = []

    for sha in _cherry_candidates(release_ref, develop_ref):
        subject = _commit_subject(sha)
        files = _commit_files(sha)
        touches_critical = any(path_re.search(f) for f in files)
        looks_like_fix = bool(subj_re.search(subject))
        # Flag only commits that BOTH touch a critical-path file AND read as a
        # fix. A critical-path refactor with no fix wording, or a fix far from
        # any critical path, is not release-blocking on its own — that keeps the
        # gate high-signal (it fires on "a crash fix you forgot to port", not on
        # every routine commit that grazes a flagged directory).
        if not (touches_critical and looks_like_fix):
            continue
        pr = _commit_pr_number(sha)
        record = {
            "sha": sha[:9],
            "pr": pr,
            "subject": subject,
            "critical_files": [f for f in files if path_re.search(f)],
        }
        if _is_waived(sha, pr, waivers):
            waived.append(record)
        else:
            unreconciled.append(record)

    return unreconciled, waived


def _port_references(release_ref: str, develop_ref: str) -> tuple[set[str], set[str]]:
    """PR numbers and full SHAs named in develop commit messages since the merge base."""
    base = _run_git(["merge-base", release_ref, develop_ref]).strip()
    messages = _run_git(["log", "--format=%B", f"{base}..{develop_ref}"])
    prs = set(re.findall(r"#(\d+)", messages))
    shas = set(re.findall(r"\b[0-9a-f]{40}\b", messages))
    return prs, shas


def evaluate_reverse(
    release_ref: str,
    develop_ref: str,
    waiver_file: str | None,
) -> tuple[list[dict], list[dict]]:
    """Return (unported, waived): release commits with no equivalent on develop."""
    waivers = _load_waivers(waiver_file, release_ref)
    port_prs, port_shas = _port_references(release_ref, develop_ref)

    unported: list[dict] = []
    waived: list[dict] = []

    # `git cherry` skips merge commits, so only commits with a patch are listed.
    for sha in _cherry_candidates(develop_ref, release_ref):
        pr = _commit_pr_number(sha)
        if sha in port_shas or (pr is not None and pr in port_prs):
            continue
        record = {"sha": sha[:9], "pr": pr, "subject": _commit_subject(sha)}
        if _is_waived(sha, pr, waivers):
            waived.append(record)
        else:
            unported.append(record)

    return unported, waived


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Block a release missing crash/critical-path fixes present on develop."
    )
    parser.add_argument("--release-ref", required=True,
                        help="Release branch or tag being promoted (e.g. release/3.2.0).")
    parser.add_argument("--develop-ref", default="origin/develop",
                        help="Integration branch to reconcile against (default origin/develop).")
    parser.add_argument("--critical-path-regex", default=DEFAULT_CRITICAL_PATH_REGEX)
    parser.add_argument("--fix-subject-regex", default=DEFAULT_FIX_SUBJECT_REGEX)
    parser.add_argument("--waiver-file", default=None,
                        help="Waiver list (default config/ci/release-waivers/<release>.txt).")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    try:
        unreconciled, waived = evaluate(
            args.release_ref,
            args.develop_ref,
            args.critical_path_regex,
            args.fix_subject_regex,
            args.waiver_file,
        )
        unported, waived_reverse = evaluate_reverse(
            args.release_ref, args.develop_ref, args.waiver_file,
        )
    except RuntimeError as exc:
        print(f"[release-fix-reconciliation] ERROR: {exc}", file=sys.stderr)
        return 2

    if not args.quiet and waived:
        print(f"[release-fix-reconciliation] {len(waived)} waived fix(es) "
              f"(explicitly excluded from {args.release_ref}):", file=sys.stderr)
        for r in waived:
            print(f"  ~ {r['sha']} {r['subject']}", file=sys.stderr)

    if not args.quiet and waived_reverse:
        print(f"[release-fix-reconciliation] {len(waived_reverse)} waived release-only "
              f"commit(s) (explicitly not ported to {args.develop_ref}):", file=sys.stderr)
        for r in waived_reverse:
            print(f"  ~ {r['sha']} {r['subject']}", file=sys.stderr)

    if unported:
        print(f"[release-fix-reconciliation] BLOCK: {len(unported)} commit(s) on "
              f"{args.release_ref} are not on develop ({args.develop_ref}) and are "
              f"not waived:", file=sys.stderr)
        for r in unported:
            pr = f" (#{r['pr']})" if r["pr"] and f"#{r['pr']}" not in r["subject"] else ""
            print(f"  - {r['sha']}{pr} {r['subject']}", file=sys.stderr)
        print("", file=sys.stderr)
        print("  Forward-port each to develop (name the release PR or use", file=sys.stderr)
        print("  `cherry-pick -x`), OR waive it with a reason in the waiver file.", file=sys.stderr)
        if not unreconciled:
            return 1

    if unreconciled:
        print(f"[release-fix-reconciliation] BLOCK: {len(unreconciled)} crash/"
              f"critical-path fix(es) on {args.develop_ref} are NOT on "
              f"{args.release_ref} and are not waived:", file=sys.stderr)
        for r in unreconciled:
            pr = f" (#{r['pr']})" if r["pr"] else ""
            print(f"  + {r['sha']}{pr} {r['subject']}", file=sys.stderr)
            for f in r["critical_files"][:4]:
                print(f"        {f}", file=sys.stderr)
        print("", file=sys.stderr)
        print("  Cherry-pick each into the release, OR waive with a reason in", file=sys.stderr)
        print("  the waiver file (one `<sha-or-#pr> <reason>` per line).", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"[release-fix-reconciliation] ok — {args.release_ref} is reconciled "
              f"with {args.develop_ref} (no unwaived crash/critical-path fixes, "
              f"no unported release commits).",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

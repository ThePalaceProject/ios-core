#!/usr/bin/env python3
"""
check-pre-ga-crash-triage.py — block promoting a release to GA while a crash
signature that FIRST APPEARED in this release is still un-triaged on the
RC / TestFlight builds.

WHY THIS EXISTS (the 3.2.0 saveSync-deadlock retro)
  The saveSync-deadlock crash produced events on the pre-GA RC builds
  (3.2.0 479 / 481 / 482 = 8 events) DURING the release-candidate window, before
  GA. The signal was already in Crashlytics — it just was not triaged until a
  week AFTER GA. Nothing gated GA promotion on "read the RC crash board."

  This gate does: given a Crashlytics export for the release's builds, it flags
  every FATAL signature whose `firstSeenVersion` is THIS release (i.e. a
  regression introduced by this release, not inherited) and blocks promotion
  unless each is explicitly triaged — dispositioned with a ticket or a reason.
  A crash you have looked at and decided to ship with is fine; a crash nobody
  has looked at is not.

INPUT (normalized JSON — the CI wrapper produces this from the Crashlytics API)
  Either a bare list of issue objects, or `{"issues": [...]}`, each:
    {
      "id": "8afb1c66...",            # Crashlytics issue id
      "title": "BookRegistrySync...", # human label
      "errorType": "FATAL",           # FATAL | NON_FATAL | ANR
      "firstSeenVersion": "3.2.0",    # marketing version it first appeared in
      "eventsCount": 8,               # events in the window
      "impactedUsersCount": 6
    }
  Extra keys are ignored, so the raw `crashlytics_get_report topIssues` groups
  can be flattened into this shape by the wrapper without pruning.

TRIAGE LEDGER
  Default `.forgeos/crash-triage/<release>.txt`, override with --triage-file.
  One `<issue-id> <ticket-or-reason>` per line; blank lines and `#`-comments
  ignored (an id is a hex string, never bare `#...`, so `#` is always a comment
  here — unlike the release-fix waiver which also accepts `#<pr>`). An issue is
  triaged if its id (full or as a prefix) is the first token of a ledger line.

USAGE
  check-pre-ga-crash-triage.py --release-version 3.2.0 --issues-json export.json \
      [--triage-file PATH] [--min-events N] [--include-anr] [--quiet]

EXIT CODES
  0  every new-in-release FATAL signature (>= --min-events) is triaged.
  1  one or more un-triaged new-in-release crash signatures (printed).
  2  usage / parse error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def _load_issues(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        data = data.get("issues", [])
    if not isinstance(data, list):
        raise ValueError("issues JSON must be a list or {\"issues\": [...]}")
    return data


def _load_triaged(path: str | None, release_version: str) -> set[str]:
    if path is None:
        safe = release_version.replace("/", "-")
        path = os.path.join(".forgeos", "crash-triage", f"{safe}.txt")
    ids: set[str] = set()
    if not os.path.exists(path):
        return ids
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            ids.add(line.split()[0])
    return ids


def _is_triaged(issue_id: str, triaged: set[str]) -> bool:
    for token in triaged:
        if issue_id == token or issue_id.startswith(token):
            return True
    return False


def evaluate(
    issues: list[dict],
    release_version: str,
    triaged: set[str],
    min_events: int,
    include_anr: bool,
) -> tuple[list[dict], list[dict]]:
    """Return (untriaged, triaged_new) new-in-release crash signatures.

    "New in release" = firstSeenVersion equals the release version. That is the
    regression signal: a signature inherited from an older version is not this
    release's fault to block on; one that debuts here is.
    """
    blocking_types = {"FATAL"}
    if include_anr:
        blocking_types.add("ANR")

    untriaged: list[dict] = []
    triaged_new: list[dict] = []

    for issue in issues:
        if issue.get("errorType") not in blocking_types:
            continue
        if str(issue.get("firstSeenVersion", "")) != str(release_version):
            continue
        if int(issue.get("eventsCount", 0) or 0) < min_events:
            continue
        record = {
            "id": issue.get("id", "?"),
            "title": issue.get("title", "?"),
            "events": int(issue.get("eventsCount", 0) or 0),
            "users": int(issue.get("impactedUsersCount", 0) or 0),
            "type": issue.get("errorType"),
        }
        if _is_triaged(record["id"], triaged):
            triaged_new.append(record)
        else:
            untriaged.append(record)

    # Loudest first.
    untriaged.sort(key=lambda r: r["events"], reverse=True)
    return untriaged, triaged_new


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Block GA promotion on un-triaged new-in-release crash signatures."
    )
    parser.add_argument("--release-version", required=True,
                        help="Marketing version being promoted (e.g. 3.2.0).")
    parser.add_argument("--issues-json", required=True,
                        help="Normalized Crashlytics issue export (list or {issues:[...]}).")
    parser.add_argument("--triage-file", default=None,
                        help="Triage ledger (default .forgeos/crash-triage/<version>.txt).")
    parser.add_argument("--min-events", type=int, default=1,
                        help="Ignore signatures below this event count (default 1).")
    parser.add_argument("--include-anr", action="store_true",
                        help="Also block on ANRs, not just FATAL crashes.")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    try:
        issues = _load_issues(args.issues_json)
        triaged = _load_triaged(args.triage_file, args.release_version)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[pre-ga-crash-triage] ERROR: {exc}", file=sys.stderr)
        return 2

    untriaged, triaged_new = evaluate(
        issues, args.release_version, triaged, args.min_events, args.include_anr
    )

    if not args.quiet and triaged_new:
        print(f"[pre-ga-crash-triage] {len(triaged_new)} new-in-{args.release_version} "
              f"signature(s) triaged (dispositioned, shipping):", file=sys.stderr)
        for r in triaged_new:
            print(f"  ~ {r['id'][:12]} {r['title']}  ({r['events']} events)", file=sys.stderr)

    if untriaged:
        print(f"[pre-ga-crash-triage] BLOCK: {len(untriaged)} crash signature(s) that "
              f"FIRST appeared in {args.release_version} are un-triaged:", file=sys.stderr)
        for r in untriaged:
            print(f"  ✗ {r['id'][:12]} [{r['type']}] {r['title']}", file=sys.stderr)
            print(f"        {r['events']} events / {r['users']} users", file=sys.stderr)
        print("", file=sys.stderr)
        print("  Triage each on the RC/TestFlight board BEFORE GA: file/​link a ticket", file=sys.stderr)
        print("  and add `<issue-id> <ticket-or-reason>` to the triage ledger, or fix it.", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"[pre-ga-crash-triage] ok — no un-triaged new-in-{args.release_version} "
              f"crash signatures (>= {args.min_events} events).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

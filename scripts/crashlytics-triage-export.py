#!/usr/bin/env python3
"""
crashlytics-triage-export.py — emit current FATAL Crashlytics issues in the JSON
shape that check-pre-ga-crash-triage.py consumes.

This is the bridge that wires the pre-GA crash-triage gate to live Crashlytics
data. It REUSES the sentinel's Firebase auth + fetch (scripts/crashlytics-sentinel.py)
so there is exactly one Crashlytics-access implementation in the repo — this
script only reshapes the sentinel's normalized issues into the gate's schema.

The sentinel's fetch is FATAL-filtered, so every emitted row is a FATAL crash;
`errorType` is set to "FATAL" for all of them.

Field mapping (sentinel normalized -> triage-gate schema):
    issue_id            -> id
    title               -> title
    (implicit FATAL)    -> errorType
    first_seen_version  -> firstSeenVersion
    events_count        -> eventsCount
    impacted_users      -> impactedUsersCount

USAGE
    crashlytics-triage-export.py [--days N] [--page-size N] [--snapshot FILE] > export.json
    check-pre-ga-crash-triage.py --release-version 3.2.0 --issues-json export.json

    --snapshot FILE  Use a raw Crashlytics API payload from disk instead of a
                     live fetch (offline / tests). It is normalized through the
                     same sentinel code path as the live fetch.

FAILURE CONTRACT
    On any Firebase auth / network error (or a missing service account) the
    underlying sentinel fetch returns [] with a warning on stderr, so this
    emits {"issues": []}. The triage gate then finds nothing to block on — a
    Firebase outage MUST NOT block a release (matching the sentinel's
    "outage must not page" contract). The manual maintainer triage is the
    backstop for that window. The gate is HARD only on real, fetched,
    un-triaged new-in-release signatures.

EXIT CODES
    0  export emitted (possibly empty).
    2  the sentinel module could not be loaded (repo/layout error).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


def _load_sentinel():
    """Load the hyphenated crashlytics-sentinel.py as an importable module."""
    path = Path(__file__).with_name("crashlytics-sentinel.py")
    spec = importlib.util.spec_from_file_location("crashlytics_sentinel", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load sentinel at {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def to_triage_shape(normalized: list[dict]) -> list[dict]:
    """Map the sentinel's normalized issues to the triage gate's schema.

    Pure transform — no I/O — so it is unit-testable without Firebase.
    """
    out: list[dict] = []
    for item in normalized:
        issue_id = item.get("issue_id") or item.get("id") or ""
        if not issue_id:
            continue
        out.append({
            "id": issue_id,
            "title": item.get("title", ""),
            "errorType": "FATAL",  # the sentinel fetch is FATAL-filtered
            "firstSeenVersion": item.get("first_seen_version", ""),
            "eventsCount": int(item.get("events_count", 0) or 0),
            "impactedUsersCount": int(item.get("impacted_users", 0) or 0),
        })
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--days", type=int, default=90,
                        help="Lookback window for the topIssues query (default 90 — "
                             "wide enough to catch a new-in-release signature seen "
                             "across the RC/TestFlight window).")
    parser.add_argument("--page-size", type=int, default=50,
                        help="Number of top FATAL issues to fetch (default 50 — "
                             "broader than the sentinel's top-10 so a new-in-release "
                             "crash below the top-10 isn't missed).")
    parser.add_argument("--snapshot", type=Path,
                        help="Raw Crashlytics API payload to use instead of a live "
                             "fetch (offline / tests).")
    args = parser.parse_args(argv)

    try:
        sentinel = _load_sentinel()
    except ImportError as exc:
        print(f"[crashlytics-triage-export] ERROR: {exc}", file=sys.stderr)
        return 2

    if args.snapshot:
        normalized = sentinel.load_snapshot(args.snapshot)
    else:
        normalized = sentinel.fetch_top_issues_from_firebase(
            days=args.days, page_size=args.page_size)

    print(json.dumps({"issues": to_triage_shape(normalized)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

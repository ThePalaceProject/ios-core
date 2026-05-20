#!/usr/bin/env python3
"""crashlytics-sentinel.py — detect new top-10 Crashlytics issues day 1.

Background:
    F-004 / F-005 were "NEW in 3.0.0" Crashlytics signatures we only noticed
    weeks after they appeared. This script runs daily (via cron in GitHub
    Actions) and compares the current top-10 issues from Firebase Crashlytics
    against .forgeos/crashlytics-baseline.json. Any signature that newly
    entered the top 10 since the baseline is surfaced as YAML on stdout, and
    the script exits 1 so the calling workflow opens a GitHub Issue.

Auth strategy:
    The Firebase Admin SDK / Crashlytics REST API needs a service account
    JSON. We follow the same lookup pattern as scripts/fetch-crashlytics.py:
      - $FIREBASE_SERVICE_ACCOUNT (path) if set (CI uses this)
      - ~/.palace/firebase-service-account.json
      - ~/.config/palace/firebase-service-account.json
    If none of those exist, we ALSO accept a snapshot path via --snapshot:
      this is the path the daily MCP-driven session writes its top-issues
      JSON to. That keeps the sentinel working in maintainer-internal mode
      (Firebase MCP) AND in CI mode (REST + service account).

Failure mode:
    If Firebase access fails (no credentials, REST 5xx, etc.) the script
    prints a warning and exits 0 — the cron must not pager-page on transient
    auth issues. Only NEW top-10 entries trigger exit 1.

Output (on detection):
    YAML block — list of issue dicts, one per newly-entered top-10 item.

Usage:
    # CI cron mode (uses service account from env):
    python3 scripts/crashlytics-sentinel.py

    # Local mode against a pre-fetched MCP snapshot:
    python3 scripts/crashlytics-sentinel.py \
        --snapshot ~/.palace/crashlytics-mcp-snapshot.json

    # Force a baseline update (writes baseline to current top-10, exit 0):
    python3 scripts/crashlytics-sentinel.py --refresh-baseline
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Optional

# Palace iOS app — pinned, never inferred. Matches CLAUDE.md memory entry
# crashlytics_weekly_check.md and Firebase project the-palace-project.
APP_ID = "1:716454087792:ios:11eb8d287ec88c2784f8b5"
FIREBASE_PROJECT = "the-palace-project"

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE_PATH = REPO_ROOT / ".forgeos" / "crashlytics-baseline.json"

DEFAULT_SA_PATHS = [
    Path(os.environ.get("FIREBASE_SERVICE_ACCOUNT", "")),
    Path.home() / ".palace" / "firebase-service-account.json",
    Path.home() / ".config" / "palace" / "firebase-service-account.json",
]


def warn(msg: str) -> None:
    sys.stderr.write(f"[crashlytics-sentinel] WARN: {msg}\n")


def info(msg: str) -> None:
    sys.stderr.write(f"[crashlytics-sentinel] {msg}\n")


def find_service_account() -> Optional[Path]:
    for p in DEFAULT_SA_PATHS:
        if p and p.exists():
            return p
    return None


def fetch_top_issues_from_firebase(days: int = 7, page_size: int = 10) -> list[dict]:
    """Pull top FATAL issues over the last `days` from Crashlytics Reporting API.

    Falls back to returning [] (with a warning) on any auth or network error.
    The caller treats [] as "could not refresh" and exits 0 — never page on
    transient Firebase outages.

    Endpoint: firebase Crashlytics Reporting API
      POST /v1/projects/{project}/apps/{app}/reports:get
    """
    sa_path = find_service_account()
    if not sa_path:
        warn("No Firebase service account JSON found; skipping live fetch. "
             "Pass --snapshot to feed an MCP-collected payload, or set "
             "FIREBASE_SERVICE_ACCOUNT in the workflow env.")
        return []

    try:
        # Lazy import — the script must still load without these libs so
        # --refresh-baseline / --snapshot keep working without Firebase deps.
        import jwt as pyjwt  # noqa: F401  (PyJWT)
        import urllib.parse
        import urllib.request
        import time
    except ImportError as exc:
        warn(f"Missing dependency for Firebase REST fetch: {exc}. "
             "pip install pyjwt cryptography")
        return []

    # OAuth2 JWT bearer flow, same shape as fetch-crashlytics.py.
    try:
        with sa_path.open() as f:
            sa = json.load(f)
        now = int(time.time())
        payload = {
            "iss": sa["client_email"],
            # firebase.readonly is enough to call Crashlytics Reporting.
            "scope": "https://www.googleapis.com/auth/firebase.readonly",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600,
        }
        token_jwt = pyjwt.encode(payload, sa["private_key"], algorithm="RS256")
        token_resp = urllib.request.urlopen(
            urllib.request.Request(
                "https://oauth2.googleapis.com/token",
                data=urllib.parse.urlencode({
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    "assertion": token_jwt,
                }).encode(),
            ),
            timeout=30,
        )
        access_token = json.loads(token_resp.read())["access_token"]
    except Exception as exc:  # noqa: BLE001 — must not crash the cron
        warn(f"OAuth handshake with Firebase failed: {exc}")
        return []

    # Build the Crashlytics Reporting API request. The exact endpoint shape
    # mirrors what the Firebase MCP server uses internally (topIssues, FATAL
    # filter, 7-day window). If the public API drifts, the workflow keeps
    # functioning via --snapshot fed from the MCP daily harness pass.
    end_time = dt.datetime.utcnow().replace(microsecond=0)
    start_time = end_time - dt.timedelta(days=days)
    iso_z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    body = {
        "report": "topIssues",
        "pageSize": page_size,
        "filter": {
            "issueErrorTypes": ["FATAL"],
            "interval": {
                "startTime": iso_z(start_time),
                "endTime": iso_z(end_time),
            },
        },
    }
    url = (
        f"https://firebasecrashlyticsreports.googleapis.com/v1/"
        f"projects/{FIREBASE_PROJECT}/apps/{APP_ID}/reports:get"
    )
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
            },
        )
        resp = urllib.request.urlopen(req, timeout=60)
        payload = json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001
        warn(f"Crashlytics report fetch failed: {exc}")
        return []

    return normalize_issues(payload)


def normalize_issues(raw: dict | list) -> list[dict]:
    """Coerce whatever shape Firebase returned into the baseline shape.

    Each issue dict has the keys the YAML output / baseline care about:
        issue_id, title, subtitle, events_count, impacted_users,
        first_seen_version, uri.
    Unknown fields are passed through verbatim so future Firebase fields
    don't get silently dropped.
    """
    issues_in = []
    if isinstance(raw, list):
        issues_in = raw
    elif isinstance(raw, dict):
        # Common Firebase response shapes — try in order.
        for key in ("issues", "topIssues", "items", "results"):
            if isinstance(raw.get(key), list):
                issues_in = raw[key]
                break
        if not issues_in and "rows" in raw and isinstance(raw["rows"], list):
            issues_in = raw["rows"]

    normalized: list[dict] = []
    for item in issues_in:
        if not isinstance(item, dict):
            continue
        issue_id = (
            item.get("issue_id")
            or item.get("issueId")
            or item.get("id")
            or item.get("name", "").split("/")[-1]
        )
        if not issue_id:
            continue
        title = item.get("title") or item.get("errorType") or item.get("name", "")
        subtitle = item.get("subtitle") or item.get("signature") or ""
        events = (
            item.get("events_count")
            or item.get("eventsCount")
            or item.get("events", 0)
        )
        users = (
            item.get("impacted_users")
            or item.get("impactedUsers")
            or item.get("usersAffected", 0)
        )
        first_seen = (
            item.get("first_seen_version")
            or item.get("firstSeenVersion")
            or item.get("appVersion", "")
        )
        uri = item.get("uri") or (
            f"https://console.firebase.google.com/project/{FIREBASE_PROJECT}/"
            f"crashlytics/app/ios:org.thepalaceproject.palace/issues/{issue_id}"
        )
        normalized.append({
            "issue_id": issue_id,
            "title": title,
            "subtitle": subtitle,
            "events_count": int(events or 0),
            "impacted_users": int(users or 0),
            "first_seen_version": first_seen,
            "uri": uri,
        })
    return normalized


def load_snapshot(path: Path) -> list[dict]:
    try:
        with path.open() as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"Could not read snapshot {path}: {exc}")
        return []
    return normalize_issues(data)


def load_baseline(path: Path) -> dict:
    if not path.exists():
        return {"as_of": None, "issues": []}
    try:
        with path.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"Could not read baseline {path}: {exc}; treating as empty.")
        return {"as_of": None, "issues": []}


def save_baseline(path: Path, issues: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "as_of": dt.datetime.utcnow().strftime("%Y-%m-%d"),
        "app_id": APP_ID,
        "issues": issues,
    }
    with path.open("w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def diff_new_entries(current: list[dict], baseline: list[dict]) -> list[dict]:
    """Return issues in `current` whose issue_id is not in `baseline`.

    "New top-10 entry" = appears in this fetch but did not in baseline.
    Placeholders (with placeholder=true) in baseline are treated as known
    so the first real fetch doesn't fire 10 alerts for the seed entries.
    """
    known = {b["issue_id"] for b in baseline if b.get("issue_id")}
    return [c for c in current if c.get("issue_id") not in known]


def emit_yaml(items: list[dict]) -> None:
    """Print a minimal hand-written YAML block. We avoid the PyYAML dep
    so the script runs in CI without any extra install step."""
    for it in items:
        print(f"- issue_id: \"{it['issue_id']}\"")
        print(f"  title: \"{_yaml_escape(it.get('title', ''))}\"")
        print(f"  subtitle: \"{_yaml_escape(it.get('subtitle', ''))}\"")
        print(f"  events_count: {it.get('events_count', 0)}")
        print(f"  impacted_users: {it.get('impacted_users', 0)}")
        print(f"  first_seen_version: \"{_yaml_escape(it.get('first_seen_version', ''))}\"")
        print(f"  uri: \"{it.get('uri', '')}\"")


def _yaml_escape(value: str) -> str:
    if value is None:
        return ""
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--baseline",
        type=Path,
        default=BASELINE_PATH,
        help="Path to baseline JSON (default: .forgeos/crashlytics-baseline.json).",
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        help="Use this MCP-collected JSON snapshot instead of the live Firebase fetch.",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Lookback window for the topIssues query (default: 7).",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=10,
        help="Number of top issues to fetch (default: 10).",
    )
    parser.add_argument(
        "--refresh-baseline",
        action="store_true",
        help="Overwrite the baseline with the current top-10 and exit 0. "
             "Use weekly to roll forward — never in the daily detection cron.",
    )
    args = parser.parse_args(argv)

    if args.snapshot:
        current = load_snapshot(args.snapshot)
    else:
        current = fetch_top_issues_from_firebase(
            days=args.days, page_size=args.page_size,
        )

    if not current:
        # Already warned above. Cron contract: do not pager-page on Firebase
        # outage — only on new crash signatures.
        info("No current top-10 data available; nothing to compare.")
        return 0

    if args.refresh_baseline:
        save_baseline(args.baseline, current)
        info(f"Baseline refreshed with {len(current)} issues at {args.baseline}.")
        return 0

    baseline = load_baseline(args.baseline)
    new_entries = diff_new_entries(current, baseline.get("issues", []))

    if not new_entries:
        info("No new top-10 entries since baseline.")
        return 0

    # Emit YAML for the workflow to capture into the GitHub Issue body.
    emit_yaml(new_entries)
    return 1


if __name__ == "__main__":
    sys.exit(main())

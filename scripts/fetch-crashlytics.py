#!/usr/bin/env python3
"""
fetch-crashlytics.py — Pull crash data from GA4 Analytics for Palace iOS.

Queries crash-free rate, crash-affected users, and active users by app version.
Compares against a saved baseline to detect regressions.

Prerequisites:
  - Service account at ~/.palace/firebase-service-account.json
  - Service account must have 'Analytics Viewer' role on GA4 property 271992303
    (grant via: GCP IAM → add roles/analytics.viewer to firebase-adminsdk-22e1m@the-palace-project.iam.gserviceaccount.com)
  - pip install pyjwt cryptography

Usage:
  python3 scripts/fetch-crashlytics.py                  # Fetch and display
  python3 scripts/fetch-crashlytics.py --save           # Fetch, display, save baseline
  python3 scripts/fetch-crashlytics.py --compare        # Fetch and compare against last baseline
  python3 scripts/fetch-crashlytics.py --json           # Output as JSON (for CI/ForgeOS)
  python3 scripts/fetch-crashlytics.py --days 30        # Custom lookback window (default: 90)

Baseline stored at: ~/.palace/crashlytics-baseline.json
"""

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

# Configuration
GA4_PROPERTY_ID = "271992303"
STREAM_ID = "2626321960"  # Palace iOS stream
SERVICE_ACCOUNT_PATH = os.path.expanduser("~/.palace/firebase-service-account.json")
BASELINE_PATH = os.path.expanduser("~/.palace/crashlytics-baseline.json")

# Thresholds for regression detection
CRASH_FREE_REGRESSION_THRESHOLD = 0.005  # 0.5% drop in crash-free rate = regression
CRASH_USER_SPIKE_THRESHOLD = 2.0  # 2x increase in crash-affected users = regression


def get_access_token():
    """Generate OAuth2 token from service account with analytics.readonly scope."""
    try:
        import jwt as pyjwt
    except ImportError:
        print("Error: pip install pyjwt cryptography", file=sys.stderr)
        sys.exit(1)

    with open(SERVICE_ACCOUNT_PATH) as f:
        sa = json.load(f)

    now = int(time.time())
    payload = {
        "iss": sa["client_email"],
        "scope": "https://www.googleapis.com/auth/analytics.readonly",
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }
    encoded = pyjwt.encode(payload, sa["private_key"], algorithm="RS256")

    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": encoded,
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    resp = urllib.request.urlopen(req)
    return json.loads(resp.read())["access_token"]


def query_ga4(token, days=90):
    """Query GA4 for crash data by app version."""
    end_date = datetime.now().strftime("%Y-%m-%d")
    start_date = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")

    url = f"https://analyticsdata.googleapis.com/v1beta/properties/{GA4_PROPERTY_ID}:runReport"

    report_request = {
        "dateRanges": [{"startDate": start_date, "endDate": end_date}],
        "dimensions": [{"name": "appVersion"}],
        "metrics": [
            {"name": "activeUsers"},
            {"name": "crashFreeUsersRate"},
            {"name": "crashAffectedUsers"},
        ],
        "dimensionFilter": {
            "andGroup": {
                "expressions": [
                    {
                        "filter": {
                            "fieldName": "platform",
                            "inListFilter": {"values": ["iOS"], "caseSensitive": True},
                        }
                    },
                    {
                        "filter": {
                            "fieldName": "streamId",
                            "stringFilter": {"matchType": "EXACT", "value": STREAM_ID},
                        }
                    },
                ]
            }
        },
        "orderBys": [{"metric": {"metricName": "activeUsers"}, "desc": True}],
        "limit": 50,
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(report_request).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        if e.code == 403:
            print("ERROR: Service account lacks Analytics Viewer role.", file=sys.stderr)
            print("Fix: Grant roles/analytics.viewer to", file=sys.stderr)
            print("  firebase-adminsdk-22e1m@the-palace-project.iam.gserviceaccount.com", file=sys.stderr)
            print("  on GA4 property 271992303", file=sys.stderr)
        else:
            print(f"HTTP {e.code}: {error_body[:300]}", file=sys.stderr)
        sys.exit(1)


def parse_results(ga4_response):
    """Parse GA4 response into structured version data."""
    versions = []
    for row in ga4_response.get("rows", []):
        version = row["dimensionValues"][0]["value"]
        active_users = int(row["metricValues"][0]["value"])
        crash_free_raw = row["metricValues"][1]["value"]
        crash_users = int(row["metricValues"][2]["value"])

        try:
            crash_free_rate = float(crash_free_raw)
        except (ValueError, TypeError):
            crash_free_rate = 0.0

        # Estimate fatal crashes from crash-affected users and crash-free rate
        # crash_free_rate = 1 - (crash_users / active_users)
        # So: fatal_estimate = active_users * (1 - crash_free_rate)
        fatal_estimate = round(active_users * (1 - crash_free_rate))

        versions.append({
            "version": version,
            "active_users": active_users,
            "crash_free_rate": crash_free_rate,
            "crash_free_pct": f"{crash_free_rate * 100:.2f}%",
            "crash_affected_users": crash_users,
            "fatal_estimate": fatal_estimate,
        })

    return versions


def compare_with_baseline(current, baseline_path):
    """Compare current data against saved baseline. Return list of regressions."""
    if not os.path.exists(baseline_path):
        return []

    with open(baseline_path) as f:
        baseline = json.load(f)

    baseline_map = {v["version"]: v for v in baseline.get("versions", [])}
    regressions = []

    for v in current:
        ver = v["version"]
        if ver not in baseline_map:
            continue
        old = baseline_map[ver]

        # Check crash-free rate regression
        rate_drop = old["crash_free_rate"] - v["crash_free_rate"]
        if rate_drop > CRASH_FREE_REGRESSION_THRESHOLD:
            regressions.append({
                "version": ver,
                "type": "crash_free_rate_drop",
                "old": old["crash_free_pct"],
                "new": v["crash_free_pct"],
                "delta": f"-{rate_drop * 100:.2f}%",
                "severity": "high" if rate_drop > 0.02 else "medium",
            })

        # Check crash user spike
        if old["crash_affected_users"] > 0:
            spike = v["crash_affected_users"] / old["crash_affected_users"]
            if spike > CRASH_USER_SPIKE_THRESHOLD:
                regressions.append({
                    "version": ver,
                    "type": "crash_user_spike",
                    "old": old["crash_affected_users"],
                    "new": v["crash_affected_users"],
                    "delta": f"{spike:.1f}x",
                    "severity": "high" if spike > 5.0 else "medium",
                })

    return regressions


def save_baseline(versions, baseline_path):
    """Save current data as baseline for future comparisons."""
    data = {
        "fetched_at": datetime.now().isoformat(),
        "property_id": GA4_PROPERTY_ID,
        "stream_id": STREAM_ID,
        "versions": versions,
    }
    Path(baseline_path).parent.mkdir(parents=True, exist_ok=True)
    with open(baseline_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\nBaseline saved to {baseline_path}")


def print_table(versions):
    """Print crash data as a formatted table."""
    print(f"\n{'Version':<12} {'Users':>8} {'Crash-Free':>12} {'Crash Users':>12} {'Fatal Est.':>11}")
    print("-" * 58)
    for v in versions:
        print(
            f"{v['version']:<12} "
            f"{v['active_users']:>8,} "
            f"{v['crash_free_pct']:>12} "
            f"{v['crash_affected_users']:>12,} "
            f"{v['fatal_estimate']:>11,}"
        )


def print_regressions(regressions):
    """Print regression alerts."""
    if not regressions:
        print("\n  No regressions detected vs baseline.")
        return

    print(f"\n  REGRESSIONS DETECTED: {len(regressions)}")
    for r in regressions:
        severity_icon = "!!" if r["severity"] == "high" else "!"
        print(f"  [{severity_icon}] {r['version']}: {r['type']} ({r['old']} -> {r['new']}, {r['delta']})")


def main():
    parser = argparse.ArgumentParser(description="Fetch Palace iOS crash data from GA4")
    parser.add_argument("--save", action="store_true", help="Save results as new baseline")
    parser.add_argument("--compare", action="store_true", help="Compare against last baseline")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--days", type=int, default=90, help="Lookback window in days (default: 90)")
    args = parser.parse_args()

    if not os.path.exists(SERVICE_ACCOUNT_PATH):
        print(f"Error: Service account not found at {SERVICE_ACCOUNT_PATH}", file=sys.stderr)
        sys.exit(1)

    print("Fetching crash data from GA4...", file=sys.stderr)
    token = get_access_token()
    result = query_ga4(token, days=args.days)
    versions = parse_results(result)

    if args.json:
        output = {
            "fetched_at": datetime.now().isoformat(),
            "days": args.days,
            "versions": versions,
        }
        if args.compare:
            output["regressions"] = compare_with_baseline(versions, BASELINE_PATH)
        print(json.dumps(output, indent=2))
    else:
        print(f"\nPalace iOS Crash Report — {args.days}-day window ending {datetime.now().strftime('%Y-%m-%d')}")
        print_table(versions)

        if args.compare:
            regressions = compare_with_baseline(versions, BASELINE_PATH)
            print_regressions(regressions)

    if args.save:
        save_baseline(versions, BASELINE_PATH)

    # Return non-zero if high-severity regressions found
    if args.compare:
        regressions = compare_with_baseline(versions, BASELINE_PATH)
        high_sev = [r for r in regressions if r["severity"] == "high"]
        if high_sev:
            sys.exit(1)


if __name__ == "__main__":
    main()

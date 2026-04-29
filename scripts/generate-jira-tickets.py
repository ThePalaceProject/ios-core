#!/usr/bin/env python3
"""
Create Jira tickets from a regression findings CSV via the Jira REST API.

Pure stdlib — no external dependencies required.

Usage:
    # Dry run (preview what would be created)
    python3 scripts/generate-jira-tickets.py \\
        --csv findings.csv \\
        --parent PP-4020 \\
        --jira-url https://ebce-lyrasis.atlassian.net \\
        --component iOS \\
        --dry-run

    # Create tickets and update the CSV with ticket keys
    python3 scripts/generate-jira-tickets.py \\
        --csv findings.csv \\
        --parent PP-4020 \\
        --jira-url https://ebce-lyrasis.atlassian.net \\
        --component iOS \\
        --update-csv

Environment variables:
    JIRA_EMAIL       Jira account email
    JIRA_API_TOKEN   Jira API token

Fallback: reads from .jira-config at repo root (KEY=VALUE format, one per line).

Only creates tickets for findings where:
    - Verified = true
    - Jira Ticket column is empty
    - Classification is 'regression' or 'pre-existing'
"""
import argparse
import base64
import csv
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Priority mapping (Jira-valid names only)
# ---------------------------------------------------------------------------
PRIORITY_MAP = {
    "blocker": "Blocker",
    "major": "High",
    "minor": "Normal",
    "cosmetic": "Low",
}
DEFAULT_PRIORITY = "Normal"

# Classifications eligible for ticket creation
TICKETABLE_CLASSIFICATIONS = {"regression", "pre-existing"}

# Jira constants
ISSUE_TYPE_BUG_ID = "10014"
COMPONENT_ID = "10000"
LABEL = "pp-4020"


# ---------------------------------------------------------------------------
# Credential helpers
# ---------------------------------------------------------------------------

def _repo_root() -> str:
    """Walk up from this script to find the repo root (contains .git)."""
    d = os.path.dirname(os.path.abspath(__file__))
    while d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, ".git")):
            return d
        d = os.path.dirname(d)
    return os.path.dirname(os.path.abspath(__file__))


def _load_jira_config() -> Dict[str, str]:
    """Read .jira-config from repo root as KEY=VALUE pairs."""
    config_path = os.path.join(_repo_root(), ".jira-config")
    cfg: Dict[str, str] = {}
    if not os.path.isfile(config_path):
        return cfg
    with open(config_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                cfg[key.strip()] = value.strip()
    return cfg


def get_credentials() -> Tuple[str, str]:
    """Return (email, api_token) from env vars or .jira-config fallback."""
    email = os.environ.get("JIRA_EMAIL", "")
    token = os.environ.get("JIRA_API_TOKEN", "")
    if email and token:
        return email, token

    cfg = _load_jira_config()
    email = email or cfg.get("JIRA_EMAIL", "")
    token = token or cfg.get("JIRA_API_TOKEN", "")
    if not email or not token:
        print("Error: JIRA_EMAIL and JIRA_API_TOKEN must be set "
              "(environment variables or .jira-config).", file=sys.stderr)
        sys.exit(1)
    return email, token


def make_auth_header(email: str, token: str) -> str:
    """Build Basic auth header value."""
    raw = f"{email}:{token}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


# ---------------------------------------------------------------------------
# ADF (Atlassian Document Format) helpers
# ---------------------------------------------------------------------------

def text_to_adf(text: str) -> Dict[str, Any]:
    """Convert plain text to ADF document. Double-newlines split paragraphs."""
    paragraphs = text.split("\n\n")
    content = []
    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        content.append({
            "type": "paragraph",
            "content": [{"type": "text", "text": para}],
        })
    if not content:
        content.append({
            "type": "paragraph",
            "content": [{"type": "text", "text": "(no description)"}],
        })
    return {"type": "doc", "version": 1, "content": content}


# ---------------------------------------------------------------------------
# Description builder
# ---------------------------------------------------------------------------

def build_description(finding: Dict[str, str]) -> str:
    """Build plain-text description from a finding row."""
    classification = finding.get("Classification", "").strip()
    baseline = finding.get("Baseline Behavior", "").strip()
    candidate = finding.get("Candidate Behavior", "").strip()
    steps = finding.get("Steps", "").strip()
    notes = finding.get("Notes", "").strip()
    pr = finding.get("PR", "").strip()

    parts = [
        f"{classification} found during regression testing.",
        "",
        baseline,
        "",
        "vs candidate:",
        "",
        candidate,
        "",
        f"Steps: {steps}",
        "",
        notes,
    ]

    if pr:
        parts.extend([
            "",
            f"Fixed in PR #{pr}: https://github.com/ThePalaceProject/ios-core/pull/{pr}",
        ])

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Jira REST API helpers
# ---------------------------------------------------------------------------

def jira_request(url: str, auth: str, method: str = "GET",
                 data: Optional[Dict] = None) -> Tuple[int, Any]:
    """Make a Jira REST API request. Returns (status_code, parsed_json)."""
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", auth)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(req) as resp:
            resp_body = resp.read().decode("utf-8")
            return resp.status, json.loads(resp_body) if resp_body else {}
    except urllib.error.HTTPError as e:
        resp_body = e.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(resp_body)
        except (json.JSONDecodeError, ValueError):
            parsed = {"raw": resp_body}
        return e.code, parsed


def create_issue(base_url: str, auth: str, project_key: str,
                 summary: str, description_adf: Dict,
                 priority_name: str, component_id: str,
                 label: str) -> Tuple[Optional[str], Optional[str]]:
    """Create a Jira issue. Returns (key, error_message)."""
    url = f"{base_url}/rest/api/3/issue"
    payload = {
        "fields": {
            "project": {"key": project_key},
            "issuetype": {"id": ISSUE_TYPE_BUG_ID},
            "summary": summary,
            "description": description_adf,
            "priority": {"name": priority_name},
            "components": [{"id": component_id}],
            "labels": [label],
        }
    }
    status, body = jira_request(url, auth, method="POST", data=payload)
    if 200 <= status < 300:
        return body.get("key"), None
    errors = body.get("errors", body.get("errorMessages", body))
    return None, f"HTTP {status}: {json.dumps(errors)}"


def link_issues(base_url: str, auth: str,
                inward_key: str, outward_key: str) -> Optional[str]:
    """Create a 'Relates' link between two issues. Returns error or None."""
    url = f"{base_url}/rest/api/3/issueLink"
    payload = {
        "type": {"name": "Relates"},
        "inwardIssue": {"key": inward_key},
        "outwardIssue": {"key": outward_key},
    }
    status, body = jira_request(url, auth, method="POST", data=payload)
    if 200 <= status < 300:
        return None
    return f"HTTP {status}: {json.dumps(body)}"


def transition_to_done(base_url: str, auth: str, issue_key: str) -> Optional[str]:
    """Transition an issue to Done. Returns error or None."""
    url = f"{base_url}/rest/api/3/issue/{issue_key}/transitions"
    status, body = jira_request(url, auth)
    if status != 200:
        return f"Failed to get transitions: HTTP {status}"

    transitions = body.get("transitions", [])
    done_transition = None
    for t in transitions:
        if t.get("name", "").lower() == "done":
            done_transition = t
            break

    if not done_transition:
        names = [t.get("name", "?") for t in transitions]
        return f"No 'Done' transition found. Available: {names}"

    payload = {"transition": {"id": done_transition["id"]}}
    status, body = jira_request(url, auth, method="POST", data=payload)
    if 200 <= status < 300:
        return None
    return f"Transition failed: HTTP {status}: {json.dumps(body)}"


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def load_csv(path: str) -> Tuple[List[str], List[Dict[str, str]]]:
    """Load CSV, return (fieldnames, rows)."""
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)
    return fieldnames, rows


def save_csv(path: str, fieldnames: List[str], rows: List[Dict[str, str]]) -> None:
    """Write rows back to CSV."""
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def backup_csv(path: str) -> str:
    """Backup CSV to path.{timestamp}.bak. Returns backup path."""
    ts = time.strftime("%Y%m%d%H%M%S")
    bak = f"{path}.{ts}.bak"
    shutil.copy2(path, bak)
    return bak


# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

def is_eligible(row: Dict[str, str]) -> bool:
    """Return True if this finding should get a Jira ticket."""
    verified = row.get("Verified", "").strip().lower()
    if verified != "true":
        return False
    jira_ticket = row.get("Jira Ticket", "").strip()
    if jira_ticket:
        return False
    classification = row.get("Classification", "").strip().lower()
    if classification not in TICKETABLE_CLASSIFICATIONS:
        return False
    return True


def should_transition_done(row: Dict[str, str]) -> bool:
    """Return True if this finding's ticket should be transitioned to Done."""
    classification = row.get("Classification", "").strip().lower()
    pr = row.get("PR", "").strip()
    return classification in TICKETABLE_CLASSIFICATIONS and bool(pr)


# ---------------------------------------------------------------------------
# Dry-run display
# ---------------------------------------------------------------------------

def print_dry_run_table(eligible: List[Dict[str, str]]) -> None:
    """Print a formatted table of what would be created."""
    if not eligible:
        print("No eligible findings found. Nothing to create.")
        return

    headers = ["ID", "Summary", "Priority", "Classification", "Has PR"]
    rows = []
    for row in eligible:
        fid = row.get("ID", "").strip()
        title = row.get("Title", "").strip()
        severity = row.get("Severity", "").strip().lower()
        classification = row.get("Classification", "").strip()
        pr = row.get("PR", "").strip()
        priority = PRIORITY_MAP.get(severity, DEFAULT_PRIORITY)
        summary = f"iOS: {fid}: {title}"
        rows.append([fid, summary, priority, classification, "Yes" if pr else "No"])

    # Compute column widths
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], len(cell))

    def fmt_row(cells: List[str]) -> str:
        return "  ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

    print(fmt_row(headers))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt_row(r))

    print(f"\nTotal: {len(rows)} ticket(s) would be created.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create Jira tickets from a regression findings CSV via the REST API.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Preview what would be created
  python3 scripts/generate-jira-tickets.py \\
      --csv findings.csv --parent PP-4020 \\
      --jira-url https://ebce-lyrasis.atlassian.net \\
      --component iOS --dry-run

  # Create tickets and update the CSV
  python3 scripts/generate-jira-tickets.py \\
      --csv findings.csv --parent PP-4020 \\
      --jira-url https://ebce-lyrasis.atlassian.net \\
      --component iOS --update-csv

Environment:
  JIRA_EMAIL        Jira account email
  JIRA_API_TOKEN    Jira API token
  Fallback: .jira-config at repo root (KEY=VALUE, one per line)
""",
    )
    parser.add_argument("--csv", required=True,
                        help="Path to findings CSV")
    parser.add_argument("--parent", required=True,
                        help="Parent Jira ticket to link new issues to (e.g. PP-4020)")
    parser.add_argument("--jira-url", required=True,
                        help="Jira instance base URL (e.g. https://ebce-lyrasis.atlassian.net)")
    parser.add_argument("--component", default="iOS",
                        help="Component name for display (default: iOS)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be created without making API calls")
    parser.add_argument("--update-csv", action="store_true",
                        help="Write Jira ticket keys back to the CSV (backs up first)")

    args = parser.parse_args()

    # Strip trailing slash from URL
    base_url = args.jira_url.rstrip("/")

    # Load CSV
    if not os.path.isfile(args.csv):
        print(f"Error: CSV file not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    fieldnames, rows = load_csv(args.csv)
    print(f"Loaded {len(rows)} findings from {args.csv}", file=sys.stderr)

    # Ensure Jira Ticket column exists
    if "Jira Ticket" not in fieldnames:
        fieldnames.append("Jira Ticket")
        for row in rows:
            row.setdefault("Jira Ticket", "")

    # Filter eligible
    eligible_indices = [i for i, row in enumerate(rows) if is_eligible(row)]
    eligible = [rows[i] for i in eligible_indices]

    print(f"Found {len(eligible)} eligible findings "
          f"(verified=true, no existing ticket, regression/pre-existing)",
          file=sys.stderr)

    # Dry run
    if args.dry_run:
        print_dry_run_table(eligible)
        return

    if not eligible:
        print("No eligible findings. Nothing to do.")
        return

    # Get credentials
    email, token = get_credentials()
    auth = make_auth_header(email, token)

    # Extract project key from parent ticket
    project_key = args.parent.rsplit("-", 1)[0] if "-" in args.parent else "PP"

    # Process each eligible finding
    results: List[Dict[str, str]] = []
    created_count = 0
    error_count = 0

    for idx in eligible_indices:
        row = rows[idx]
        fid = row.get("ID", "").strip()
        title = row.get("Title", "").strip()
        severity = row.get("Severity", "").strip().lower()
        priority = PRIORITY_MAP.get(severity, DEFAULT_PRIORITY)
        summary = f"iOS: {fid}: {title}"
        description_text = build_description(row)
        description_adf = text_to_adf(description_text)

        print(f"\nCreating: {summary} ...", file=sys.stderr)

        # 1. Create the issue
        issue_key, err = create_issue(
            base_url, auth, project_key, summary, description_adf,
            priority, COMPONENT_ID, LABEL,
        )
        if err:
            print(f"  FAILED: {err}", file=sys.stderr)
            results.append({"id": fid, "summary": summary, "status": "FAILED", "error": err})
            error_count += 1
            continue

        print(f"  Created: {issue_key}", file=sys.stderr)
        created_count += 1

        # Update the row
        rows[idx]["Jira Ticket"] = issue_key

        result_entry = {"id": fid, "summary": summary, "key": issue_key, "status": "CREATED"}

        # 2. Link to parent
        link_err = link_issues(base_url, auth, issue_key, args.parent)
        if link_err:
            print(f"  Link to {args.parent} failed: {link_err}", file=sys.stderr)
            result_entry["link_error"] = link_err
        else:
            print(f"  Linked to {args.parent}", file=sys.stderr)

        # 3. Transition to Done if PR exists and classification qualifies
        if should_transition_done(row):
            trans_err = transition_to_done(base_url, auth, issue_key)
            if trans_err:
                print(f"  Transition to Done failed: {trans_err}", file=sys.stderr)
                result_entry["transition_error"] = trans_err
            else:
                print(f"  Transitioned to Done", file=sys.stderr)
                result_entry["status"] = "CREATED+DONE"

        results.append(result_entry)

    # Summary
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Created: {created_count}  Errors: {error_count}  "
          f"Total eligible: {len(eligible)}", file=sys.stderr)

    # Save results file alongside the CSV
    csv_dir = os.path.dirname(os.path.abspath(args.csv))
    results_path = os.path.join(csv_dir, "created-tickets.txt")
    with open(results_path, "w") as f:
        f.write(f"Jira Ticket Creation Results\n")
        f.write(f"{'='*60}\n")
        f.write(f"CSV: {args.csv}\n")
        f.write(f"Parent: {args.parent}\n")
        f.write(f"Created: {created_count}  Errors: {error_count}\n")
        f.write(f"{'='*60}\n\n")
        for r in results:
            key = r.get("key", "N/A")
            f.write(f"{r['id']}  {key}  {r['status']}  {r['summary']}\n")
            if r.get("error"):
                f.write(f"    Error: {r['error']}\n")
            if r.get("link_error"):
                f.write(f"    Link error: {r['link_error']}\n")
            if r.get("transition_error"):
                f.write(f"    Transition error: {r['transition_error']}\n")
    print(f"Results saved to {results_path}", file=sys.stderr)

    # Update CSV if requested
    if args.update_csv:
        bak = backup_csv(args.csv)
        print(f"CSV backed up to {bak}", file=sys.stderr)
        save_csv(args.csv, fieldnames, rows)
        print(f"CSV updated with ticket keys.", file=sys.stderr)


if __name__ == "__main__":
    main()

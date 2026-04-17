#!/usr/bin/env python3
"""
update-crashlytics-report.py — Update the PP-4020 report HTML with Crashlytics data.

Reads a JSON snapshot (produced by Firebase MCP during a Claude Code session)
and injects a "Live Crashlytics Update" card into the report HTML.

Usage:
  python3 scripts/update-crashlytics-report.py <snapshot.json> [--report <report.html>]

The script replaces everything between <!-- CRASHLYTICS_LIVE_START --> and
<!-- CRASHLYTICS_LIVE_END --> markers in the report.
"""

import argparse
import json
import os
import sys
from datetime import datetime
from html import escape


REPORT_PATH = os.path.expanduser(
    "~/Desktop/regression-PP-4020/report/index.html"
)
DATA_DIR = os.path.expanduser(
    "~/Desktop/regression-PP-4020/report/assets/data"
)

START_MARKER = "<!-- CRASHLYTICS_LIVE_START -->"
END_MARKER = "<!-- CRASHLYTICS_LIVE_END -->"


def load_snapshot(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def bar_width(value: int, max_value: int) -> str:
    if max_value == 0:
        return "0%"
    return f"{max(1, int(value / max_value * 100))}%"


def bar_color(value: int, max_value: int) -> str:
    ratio = value / max_value if max_value else 0
    if ratio > 0.5:
        return "#ef4444"
    if ratio > 0.2:
        return "#f97316"
    return "#22c55e"


def origin_badge(origin: str) -> str:
    colors = {
        "pre-existing": "#ea580c",
        "2.x-new": "#dc2626",
        "internal-testing": "#6366f1",
    }
    color = colors.get(origin, "#64748b")
    label = escape(origin.replace("-", " ").title())
    return f'<span class="badge" style="background:{color}">{label}</span>'


def signal_badges(signals: list) -> str:
    badge_map = {
        "REPETITIVE": ("#b91c1c", "Repetitive"),
        "FRESH": ("#2563eb", "Fresh"),
        "REGRESSED": ("#dc2626", "Regressed"),
    }
    parts = []
    for s in signals:
        color, label = badge_map.get(s, ("#64748b", s))
        parts.append(
            f'<span class="badge" style="background:{color};font-size:0.65rem;">{label}</span>'
        )
    return " ".join(parts)


def generate_html(data: dict) -> str:
    fetched = data["fetched_at"][:10]
    window_start = data["window"]["start"][:10]
    window_end = data["window"]["end"][:10]
    fatal_total = data["fatal_total"]
    nonfatal_total = data["nonfatal_total"]

    # --- Version breakdown ---
    versions = data["fatal_by_version"]
    max_ver_events = max((v["events"] for v in versions), default=1) or 1
    ver_rows = []
    for v in versions:
        evt = v["events"]
        color = bar_color(evt, max_ver_events)
        w = bar_width(evt, max_ver_events)
        ver_rows.append(
            f'<tr style="border-bottom:1px solid var(--border);">'
            f'<td style="padding:8px;">{escape(v["version"])}</td>'
            f'<td style="text-align:right; padding:8px; color:{color}; font-weight:600;">{evt:,}</td>'
            f'<td style="padding:8px; width:40%;"><div style="background:{color}; height:14px; border-radius:3px; width:{w};"></div></td>'
            f"</tr>"
        )

    # --- Top fatal issues ---
    issues = data["top_fatal_issues"]
    max_issue_events = max((i["events"] for i in issues), default=1) or 1
    issue_rows = []
    for i in issues:
        evt = i["events"]
        color = bar_color(evt, max_issue_events)
        sigs = signal_badges(i.get("signals", []))
        issue_rows.append(
            f'<tr style="border-bottom:1px solid var(--border);">'
            f'<td style="padding:8px;">{escape(i["title"])} {sigs}</td>'
            f'<td style="text-align:right; padding:8px; color:{color}; font-weight:600;">{evt:,}</td>'
            f'<td style="text-align:right; padding:8px;">{i["users"]:,}</td>'
            f'<td style="padding:8px;">{origin_badge(i["origin"])}</td>'
            f'<td style="padding:8px; font-size:0.8rem; color:var(--text-muted);">{escape(i["first_seen"])} &ndash; {escape(i["last_seen"])}</td>'
            f"</tr>"
        )

    # --- Platform distribution ---
    plat = data["platform_distribution"]
    total_plat = sum(p["events"] for p in plat.values())

    def plat_card(name, key):
        p = plat[key]
        pct = round(p["events"] / total_plat * 100) if total_plat else 0
        color = "#f97316" if key == "macos" else "var(--text)"
        return (
            f'<div style="flex:1; background:var(--bg); padding:16px; border-radius:8px; text-align:center;">'
            f'<div style="font-size:1.3rem; font-weight:700; color:{color};">{pct}%</div>'
            f'<div style="font-size:0.8rem; color:var(--text-muted);">{name}<br>({p["events"]:,} events)</div>'
            f"</div>"
        )

    # --- Top non-fatal issues ---
    nf_issues = data["top_nonfatal_issues"][:6]
    max_nf = max((n["events"] for n in nf_issues), default=1) or 1
    nf_rows = []
    for n in nf_issues:
        evt = n["events"]
        w = bar_width(evt, max_nf)
        nf_rows.append(
            f'<tr style="border-bottom:1px solid var(--border);">'
            f'<td style="padding:8px;">{escape(n["title"])}</td>'
            f'<td style="text-align:right; padding:8px;">{evt:,}</td>'
            f'<td style="text-align:right; padding:8px;">{n["users"]:,}</td>'
            f'<td style="padding:8px; width:30%;"><div style="background:#3b82f6; height:10px; border-radius:3px; width:{w};"></div></td>'
            f"</tr>"
        )

    # --- Assemble ---
    html = f"""<!-- CRASHLYTICS_LIVE_START -->
<div class="finding-card" style="border-left:3px solid #3b82f6;">
<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
<h3 style="margin:0;">Live Crashlytics Update</h3>
<span style="font-size:0.75rem; color:var(--text-muted); background:var(--bg); padding:4px 12px; border-radius:999px;">Fetched {fetched} &middot; {window_start} to {window_end}</span>
</div>
<div style="display:grid; grid-template-columns:repeat(3, 1fr); gap:16px; margin-bottom:20px;">
<div style="background:var(--bg); padding:16px; border-radius:8px; text-align:center;">
<div style="font-size:1.5rem; font-weight:700; color:#ef4444;">{fatal_total:,}</div>
<div style="font-size:0.8rem; color:var(--text-muted);">Fatal Crashes (7d)</div>
</div>
<div style="background:var(--bg); padding:16px; border-radius:8px; text-align:center;">
<div style="font-size:1.5rem; font-weight:700; color:#f97316;">{nonfatal_total:,}</div>
<div style="font-size:0.8rem; color:var(--text-muted);">Non-Fatal Events (7d)</div>
</div>
<div style="background:var(--bg); padding:16px; border-radius:8px; text-align:center;">
<div style="font-size:1.5rem; font-weight:700; color:#3b82f6;">{len(issues)}</div>
<div style="font-size:0.8rem; color:var(--text-muted);">Active Fatal Issues</div>
</div>
</div>

<h4 style="font-size:0.85rem; color:var(--text-muted); text-transform:uppercase; letter-spacing:0.05em; margin:20px 0 8px;">Fatal Crashes by Version</h4>
<table style="width:100%; border-collapse:collapse; font-size:0.85rem; margin:0 0 20px;">
<thead><tr style="border-bottom:2px solid var(--border);">
<th style="text-align:left; padding:8px; color:var(--text-muted);">Version</th>
<th style="text-align:right; padding:8px; color:var(--text-muted);">Fatals</th>
<th style="text-align:left; padding:8px; color:var(--text-muted);"></th>
</tr></thead>
<tbody>
{"".join(ver_rows)}
</tbody>
</table>

<h4 style="font-size:0.85rem; color:var(--text-muted); text-transform:uppercase; letter-spacing:0.05em; margin:20px 0 8px;">Top Fatal Issues</h4>
<table style="width:100%; border-collapse:collapse; font-size:0.85rem; margin:0 0 20px;">
<thead><tr style="border-bottom:2px solid var(--border);">
<th style="text-align:left; padding:8px; color:var(--text-muted);">Issue</th>
<th style="text-align:right; padding:8px; color:var(--text-muted);">Fatals</th>
<th style="text-align:right; padding:8px; color:var(--text-muted);">Users</th>
<th style="text-align:left; padding:8px; color:var(--text-muted);">Origin</th>
<th style="text-align:left; padding:8px; color:var(--text-muted);">Versions</th>
</tr></thead>
<tbody>
{"".join(issue_rows)}
</tbody>
</table>

<h4 style="font-size:0.85rem; color:var(--text-muted); text-transform:uppercase; letter-spacing:0.05em; margin:20px 0 8px;">Platform Distribution (Fatal)</h4>
<div style="display:flex; gap:24px; margin:0 0 20px;">
{plat_card("iOS (iPhone)", "ios")}
{plat_card("iPadOS", "ipados")}
{plat_card("macOS (Catalyst)", "macos")}
</div>

<h4 style="font-size:0.85rem; color:var(--text-muted); text-transform:uppercase; letter-spacing:0.05em; margin:20px 0 8px;">Top Non-Fatal Issues</h4>
<table style="width:100%; border-collapse:collapse; font-size:0.85rem; margin:0 0 12px;">
<thead><tr style="border-bottom:2px solid var(--border);">
<th style="text-align:left; padding:8px; color:var(--text-muted);">Issue</th>
<th style="text-align:right; padding:8px; color:var(--text-muted);">Events</th>
<th style="text-align:right; padding:8px; color:var(--text-muted);">Users</th>
<th style="text-align:left; padding:8px; color:var(--text-muted);"></th>
</tr></thead>
<tbody>
{"".join(nf_rows)}
</tbody>
</table>

<div class="meta">Data source: Firebase Crashlytics MCP. Updated automatically during Claude Code sessions (weekly cadence). Snapshot: <code>assets/data/crashlytics-{fetched}.json</code></div>
</div>
<!-- CRASHLYTICS_LIVE_END -->"""

    return html


def find_latest_snapshot(data_dir: str) -> str:
    files = sorted(
        [f for f in os.listdir(data_dir) if f.startswith("crashlytics-") and f.endswith(".json")],
        reverse=True,
    )
    if not files:
        print(f"No snapshot files found in {data_dir}", file=sys.stderr)
        sys.exit(1)
    return os.path.join(data_dir, files[0])


def inject_into_report(html_content: str, live_html: str) -> str:
    start_idx = html_content.find(START_MARKER)
    end_idx = html_content.find(END_MARKER)

    if start_idx == -1 or end_idx == -1:
        # No markers yet — insert before the closing </div></section> of the crashlytics section
        section_end = html_content.find("</div></section>", html_content.find('id="crashlytics"'))
        if section_end == -1:
            print("Could not find crashlytics section in report", file=sys.stderr)
            sys.exit(1)
        return html_content[:section_end] + "\n" + live_html + "\n" + html_content[section_end:]
    else:
        # Replace existing markers
        return html_content[:start_idx] + live_html + html_content[end_idx + len(END_MARKER):]


def main():
    parser = argparse.ArgumentParser(description="Update PP-4020 report with Crashlytics data")
    parser.add_argument("snapshot", nargs="?", help="Path to JSON snapshot (default: latest in data dir)")
    parser.add_argument("--report", default=REPORT_PATH, help="Path to report HTML")
    parser.add_argument("--dry-run", action="store_true", help="Print HTML without writing")
    args = parser.parse_args()

    snapshot_path = args.snapshot or find_latest_snapshot(DATA_DIR)
    data = load_snapshot(snapshot_path)
    live_html = generate_html(data)

    if args.dry_run:
        print(live_html)
        return

    with open(args.report) as f:
        report = f.read()

    updated = inject_into_report(report, live_html)

    with open(args.report, "w") as f:
        f.write(updated)

    print(f"Report updated with data from {snapshot_path}")
    print(f"  Fatal: {data['fatal_total']:,} events | Non-fatal: {data['nonfatal_total']:,} events")
    print(f"  Window: {data['window']['start'][:10]} to {data['window']['end'][:10]}")


if __name__ == "__main__":
    main()

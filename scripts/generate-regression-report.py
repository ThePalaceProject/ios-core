#!/usr/bin/env python3
"""Generate an interactive HTML regression report from a findings CSV.

Pure stdlib — no external dependencies required.

Usage:
    python3 scripts/generate-regression-report.py \\
        --csv findings.csv \\
        --screenshots ./screenshots/ \\
        --output report/index.html \\
        --baseline-version 1.2.8 \\
        --candidate-version 2.2.5

    python3 scripts/generate-regression-report.py --csv findings.csv --validate --screenshots ./screenshots/
    python3 scripts/generate-regression-report.py --csv findings.csv --strict --output report.html

CSV columns:
    ID, Title, Area, Test ID, Classification, Severity, Verified,
    Baseline Behavior, Candidate Behavior, Steps,
    Screenshot Baseline, Screenshot Candidate, Notes, PR, Jira Ticket
"""
import argparse
import csv
import html
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SEVERITY_COLORS: Dict[str, str] = {
    "blocker": "#dc2626",
    "major": "#ea580c",
    "minor": "#ca8a04",
    "cosmetic": "#6b7280",
}

CLASSIFICATION_COLORS: Dict[str, str] = {
    "regression": "#dc2626",
    "pre-existing": "#ea580c",
    "fixed": "#16a34a",
    "behavior-change": "#7c3aed",
    "new-feature": "#3b82f6",
    "superseded": "#6b7280",
}

CLASSIFICATION_LABELS: Dict[str, str] = {
    "regression": "Regression",
    "pre-existing": "Pre-existing",
    "fixed": "Fixed",
    "behavior-change": "Behavior Change",
    "new-feature": "New Feature",
    "superseded": "Superseded",
}

TOC_TAGS: Dict[str, str] = {
    "regression": "REG",
    "pre-existing": "PRE",
    "fixed": "FIX",
    "behavior-change": "CHG",
    "new-feature": "NEW",
    "superseded": "SUP",
}

TOC_TAG_COLORS: Dict[str, str] = {
    "REG": "#dc2626",
    "PRE": "#ea580c",
    "FIX": "#16a34a",
    "CHG": "#7c3aed",
    "NEW": "#3b82f6",
    "SUP": "#6b7280",
}

# Sections displayed in the main body (excludes superseded).
MAIN_SECTIONS = [
    ("regressions", "Regressions", "regression",
     "Functionality that regressed between the baseline and candidate versions."),
    ("pre-existing", "Pre-existing Bugs", "pre-existing",
     "Bugs present in both versions — not introduced by the candidate."),
    ("fixed", "Fixed", "fixed",
     "Issues present in the baseline that are resolved in the candidate."),
    ("improvements", "Improvements", None,  # special: behavior-change + new-feature
     "Behavior changes and new features in the candidate version."),
]

DEFAULT_JIRA_URL = "https://ebce-lyrasis.atlassian.net/browse"


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_findings(csv_path: Path) -> List[Dict[str, str]]:
    """Read findings CSV and return a list of row dicts."""
    with csv_path.open("r", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        return list(reader)


def classify_findings(findings: List[Dict[str, str]]) -> Dict[str, List[Dict[str, str]]]:
    """Group findings by their Classification value (lowercased)."""
    groups: Dict[str, List[Dict[str, str]]] = {}
    for row in findings:
        val = row.get("Classification")
        cls = val.strip().lower() if val else ""
        groups.setdefault(cls, []).append(row)
    return groups


def _unique_prs(findings: List[Dict[str, str]]) -> int:
    """Count unique non-empty PR numbers across all findings."""
    prs = set()
    for row in findings:
        val = row.get("PR")
        pr = val.strip() if val else ""
        if pr:
            prs.add(pr)
    return len(prs)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_findings(
    findings: List[Dict[str, str]],
    screenshots_dir: Optional[Path],
    strict: bool,
) -> List[str]:
    """Return a list of error strings. Empty means valid."""
    errors: List[str] = []

    # Screenshot reference check (only when --validate is active).
    if screenshots_dir is not None:
        for row in findings:
            for col in ("Screenshot Baseline", "Screenshot Candidate"):
                ref = _cell(row, col)
                if not ref:
                    continue
                full = screenshots_dir / ref
                if not full.exists():
                    errors.append(
                        f"{row.get('ID', '?')}: referenced screenshot "
                        f"'{ref}' not found in {screenshots_dir}"
                    )

    # Strict: every finding must be verified.
    if strict:
        unverified: List[str] = []
        for row in findings:
            val = row.get("Verified")
            v = val.strip().lower() if val else ""
            if v not in ("true", "yes", "1"):
                fid_val = row.get("ID")
                unverified.append(fid_val.strip() if fid_val else "?")
        if unverified:
            errors.append(
                f"Unverified findings (--strict mode): {', '.join(unverified)}"
            )

    return errors


# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------

def esc(text: str) -> str:
    """HTML-escape a string, handling None/empty gracefully."""
    return html.escape(str(text)) if text else ""


_COLUMN_ALIASES: Dict[str, List[str]] = {
    "Baseline Behavior": ["Baseline Behavior", "1.2.8 Behavior"],
    "Candidate Behavior": ["Candidate Behavior", "2.2.5 Behavior"],
    "Screenshot Baseline": ["Screenshot Baseline", "Screenshot 1.2.8"],
    "Screenshot Candidate": ["Screenshot Candidate", "Screenshot 2.2.5"],
}


def _cell(row: Dict[str, str], key: str) -> str:
    """Safely retrieve a CSV cell, trying column aliases for backward compat."""
    val = row.get(key)
    if val is None:
        for alias in _COLUMN_ALIASES.get(key, []):
            val = row.get(alias)
            if val is not None:
                break
    return val.strip() if val else ""


def _is_image(filename: str) -> bool:
    return filename.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp"))


def _is_video(filename: str) -> bool:
    return filename.lower().endswith((".mp4", ".mov", ".m4v", ".webm"))


# ---------------------------------------------------------------------------
# CSS
# ---------------------------------------------------------------------------

def _css() -> str:
    return """\
:root {
  --bg: #0f172a;
  --surface: #1e293b;
  --text: #e2e8f0;
  --text-muted: #94a3b8;
  --border: #334155;
  --accent: #3b82f6;
}
*, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: -apple-system, system-ui, sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.6;
}
.container { max-width: 1200px; margin: 0 auto; padding: 0 24px; }

/* Header */
header {
  background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
  border-bottom: 1px solid var(--border);
  padding: 40px 0;
}
header h1 { font-size: 2rem; font-weight: 700; margin-bottom: 4px; }
header .subtitle { color: var(--text-muted); font-size: 1.1rem; }

/* Stats grid */
.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 16px;
  margin: 32px 0 0;
}
.stat-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 20px;
  text-align: center;
}
.stat-number { font-size: 2rem; font-weight: 700; }
.stat-label {
  color: var(--text-muted);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

/* Sticky nav */
nav {
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  z-index: 100;
}
nav .container { display: flex; gap: 0; overflow-x: auto; }
nav a {
  color: var(--text-muted);
  text-decoration: none;
  padding: 14px 18px;
  font-size: 0.85rem;
  font-weight: 500;
  white-space: nowrap;
  border-bottom: 2px solid transparent;
  transition: all 0.2s;
}
nav a:hover { color: var(--text); border-bottom-color: var(--accent); }

/* Sections */
.section-wrap { padding: 48px 0; border-bottom: 1px solid var(--border); }
.section-collapse summary { cursor: pointer; list-style: none; }
.section-collapse summary::-webkit-details-marker { display: none; }
.section-collapse summary h2 { font-size: 1.5rem; margin-bottom: 8px; display: inline; }
.section-desc { color: var(--text-muted); margin-bottom: 24px; font-size: 0.95rem; }

/* Finding cards */
.finding-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 24px;
  margin-bottom: 16px;
}
.finding-card:hover { border-color: #475569; }
.finding-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
  flex-wrap: wrap;
}
.finding-id {
  font-family: ui-monospace, 'SF Mono', monospace;
  font-weight: 700;
  font-size: 0.9rem;
  color: var(--accent);
}
.badge {
  display: inline-block;
  padding: 2px 10px;
  border-radius: 999px;
  font-size: 0.7rem;
  font-weight: 600;
  color: white;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.jira-link {
  color: #f59e0b;
  font-size: 0.85rem;
  font-weight: 600;
  text-decoration: none;
}
.jira-link:hover { text-decoration: underline; }
.pr-link {
  color: #06b6d4;
  font-size: 0.85rem;
  font-weight: 600;
  text-decoration: none;
}
.pr-link:hover { text-decoration: underline; }
.finding-card h3 { font-size: 1.05rem; font-weight: 600; margin-bottom: 12px; line-height: 1.4; }

/* Comparison columns */
.comparison {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
  margin: 16px 0;
}
.version {
  background: var(--bg);
  padding: 16px;
  border-radius: 8px;
}
.version.old { border-left: 3px solid #475569; }
.version.new { border-left: 3px solid var(--accent); }
.version strong {
  display: block;
  margin-bottom: 8px;
  font-size: 0.8rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
.version p { font-size: 0.9rem; line-height: 1.5; }

/* Meta (steps / notes) */
.meta {
  margin: 8px 0;
  font-size: 0.85rem;
  color: var(--text-muted);
  line-height: 1.5;
}

/* Evidence grid */
.evidence {
  margin-top: 16px;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.evidence-item {
  border-radius: 8px;
  overflow: hidden;
  border: 1px solid var(--border);
  background: var(--bg);
}
.evidence-item img {
  width: 100%;
  display: block;
  max-height: 400px;
  object-fit: contain;
  background: #000;
}
.evidence-item video {
  width: 100%;
  display: block;
  max-height: 400px;
}
.screenshot-label {
  padding: 6px 12px;
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  background: rgba(0,0,0,0.3);
}

/* Hero video */
.hero-video {
  margin: 24px 0;
  border-radius: 12px;
  overflow: hidden;
  border: 1px solid var(--border);
  background: #000;
  max-width: 900px;
}
.hero-video video { width: 100%; display: block; }

/* All-findings TOC */
.toc { columns: 2; column-gap: 32px; }
.toc a {
  display: block;
  color: var(--text-muted);
  text-decoration: none;
  padding: 3px 0;
  font-size: 0.85rem;
  font-family: ui-monospace, 'SF Mono', monospace;
}
.toc a:hover { color: var(--text); }
.toc-tag {
  font-family: -apple-system, system-ui, sans-serif;
  font-size: 0.7rem;
  font-weight: 600;
}

/* Footer */
footer {
  padding: 48px 0;
  text-align: center;
  color: #475569;
  font-size: 0.8rem;
}

/* Responsive */
@media (max-width: 768px) {
  .comparison, .evidence { grid-template-columns: 1fr; }
  .stats-grid { grid-template-columns: repeat(2, 1fr); }
  .toc { columns: 1; }
}
"""


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

def _render_stats(groups: Dict[str, List], pr_count: int) -> str:
    """Render the header stats grid."""
    n_reg = len(groups.get("regression", []))
    n_fix = len(groups.get("fixed", []))
    n_pre = len(groups.get("pre-existing", []))
    n_imp = len(groups.get("behavior-change", [])) + len(groups.get("new-feature", []))

    def _card(number: int, label: str, color: str) -> str:
        return (
            f'<div class="stat-card">'
            f'<div class="stat-number" style="color:{color}">{number}</div>'
            f'<div class="stat-label">{esc(label)}</div></div>'
        )

    return (
        '<div class="stats-grid">'
        + _card(n_reg, "Regressions", "#ef4444")
        + _card(n_fix, "Fixed", "#22c55e")
        + _card(n_pre, "Pre-existing", "#f97316")
        + _card(n_imp, "Improvements", "#a78bfa")
        + _card(pr_count, "PRs", "#06b6d4")
        + "</div>"
    )


def _render_evidence_item(label: str, filename: str, screenshots_rel: str) -> str:
    """Render a single evidence item (image or video)."""
    path = f"{screenshots_rel}/{esc(filename)}"
    if _is_video(filename):
        media = (
            f'<video controls preload="metadata">'
            f'<source src="{path}"></video>'
        )
    else:
        media = f'<img src="{path}" loading="lazy" alt="{esc(label)}">'
    return (
        f'<div class="evidence-item">'
        f'<div class="screenshot-label">{esc(label)}</div>'
        f'{media}</div>'
    )


def _render_finding(
    row: Dict[str, str],
    baseline_ver: str,
    candidate_ver: str,
    jira_url: str,
    screenshots_rel: str,
) -> str:
    """Render a single finding card."""
    fid = _cell(row, "ID")
    title = _cell(row, "Title")
    severity = _cell(row, "Severity").lower()
    classification = _cell(row, "Classification").lower()
    jira = _cell(row, "Jira Ticket")
    pr = _cell(row, "PR")

    sev_color = SEVERITY_COLORS.get(severity, "#6b7280")
    cls_color = CLASSIFICATION_COLORS.get(classification, "#6b7280")
    cls_label = CLASSIFICATION_LABELS.get(classification, classification.title())

    # Header line: ID, optional Jira, severity badge, classification badge, optional PR.
    parts = [f'<span class="finding-id">{esc(fid)}</span>']
    if jira:
        parts.append(
            f'<a class="jira-link" href="{esc(jira_url)}/{esc(jira)}" '
            f'target="_blank">{esc(jira)}</a>'
        )
    if severity:
        parts.append(f'<span class="badge" style="background:{sev_color}">{esc(severity)}</span>')
    parts.append(f'<span class="badge" style="background:{cls_color}">{esc(cls_label)}</span>')
    if pr:
        parts.append(
            f'<a class="pr-link" href="https://github.com/ThePalaceProject/ios-core/pull/{esc(pr)}" '
            f'target="_blank">PR #{esc(pr)}</a>'
        )

    header = f'<div class="finding-header">{"".join(parts)}</div>'

    # Title
    title_html = f"<h3>{esc(title)}</h3>"

    # Comparison columns
    old_b = _cell(row, "Baseline Behavior")
    new_b = _cell(row, "Candidate Behavior")
    comparison = ""
    if old_b or new_b:
        comparison = (
            '<div class="comparison">'
            f'<div class="version old"><strong>{esc(baseline_ver)}</strong><p>{esc(old_b)}</p></div>'
            f'<div class="version new"><strong>{esc(candidate_ver)}</strong><p>{esc(new_b)}</p></div>'
            "</div>"
        )

    # Steps and notes
    steps = _cell(row, "Steps")
    notes = _cell(row, "Notes")
    meta = ""
    if steps:
        meta += f'<div class="meta"><strong>Steps:</strong> {esc(steps)}</div>'
    if notes:
        meta += f'<div class="meta"><strong>Notes:</strong> {esc(notes)}</div>'

    # Evidence
    ss_base = _cell(row, "Screenshot Baseline")
    ss_cand = _cell(row, "Screenshot Candidate")
    evidence = ""
    if ss_base or ss_cand:
        items = ""
        if ss_base:
            items += _render_evidence_item(baseline_ver, ss_base, screenshots_rel)
        if ss_cand:
            items += _render_evidence_item(candidate_ver, ss_cand, screenshots_rel)
        evidence = f'<div class="evidence">{items}</div>'

    return (
        f'<div class="finding-card" id="{esc(fid)}">'
        f"{header}{title_html}{comparison}{meta}{evidence}"
        "</div>"
    )


def _render_section(
    section_id: str,
    title: str,
    description: str,
    findings: List[Dict[str, str]],
    baseline_ver: str,
    candidate_ver: str,
    jira_url: str,
    screenshots_rel: str,
) -> str:
    """Render a collapsible section with finding cards."""
    if not findings:
        return ""
    cards = "\n".join(
        _render_finding(f, baseline_ver, candidate_ver, jira_url, screenshots_rel)
        for f in findings
    )
    return (
        f'<div class="section-wrap" id="{esc(section_id)}">'
        f'<div class="container">'
        f'<details class="section-collapse" open>'
        f"<summary><h2>{esc(title)} ({len(findings)})</h2></summary>"
        f'<p class="section-desc">{esc(description)}</p>'
        f"{cards}"
        f"</details></div></div>"
    )


def _render_toc(findings: List[Dict[str, str]]) -> str:
    """Render the All Findings index as a TOC-style list."""
    lines: List[str] = []
    for row in findings:
        fid = _cell(row, "ID")
        title = _cell(row, "Title")
        cls = _cell(row, "Classification").lower()
        tag = TOC_TAGS.get(cls, "???")
        color = TOC_TAG_COLORS.get(tag, "#6b7280")
        display = title[:70] + ("..." if len(title) > 70 else "")
        lines.append(
            f'<a href="#{esc(fid)}">{esc(fid)} '
            f'<span class="toc-tag" style="color:{color}">[{tag}]</span> '
            f"{esc(display)}</a>"
        )
    return "\n".join(lines)


def _render_hero_video(video_path: str) -> str:
    """Render optional hero video at the top."""
    return (
        '<div class="section-wrap" id="hero-video"><div class="container">'
        "<h2>Video Overview</h2>"
        f'<div class="hero-video">'
        f'<video controls preload="metadata" playsinline>'
        f'<source src="{esc(video_path)}"></video></div>'
        "</div></div>"
    )


# ---------------------------------------------------------------------------
# Full report assembly
# ---------------------------------------------------------------------------

def generate_html(
    findings: List[Dict[str, str]],
    *,
    title: str,
    baseline_version: str,
    candidate_version: str,
    video_path: Optional[str],
    jira_url: str,
    screenshots_rel: str,
) -> str:
    """Assemble the complete HTML report string."""
    groups = classify_findings(findings)
    pr_count = _unique_prs(findings)

    # Build main body sections.
    body_sections: List[str] = []

    # Optional hero video.
    if video_path:
        body_sections.append(_render_hero_video(video_path))

    for sec_id, sec_title, cls_key, sec_desc in MAIN_SECTIONS:
        if cls_key is not None:
            section_findings = groups.get(cls_key, [])
        else:
            # "improvements" merges behavior-change + new-feature.
            section_findings = (
                groups.get("behavior-change", []) + groups.get("new-feature", [])
            )
        body_sections.append(
            _render_section(
                sec_id, sec_title, sec_desc, section_findings,
                baseline_version, candidate_version, jira_url, screenshots_rel,
            )
        )

    # All Findings index (includes superseded).
    toc_html = _render_toc(findings)
    superseded_count = len(groups.get("superseded", []))
    active_count = len(findings) - superseded_count
    body_sections.append(
        '<div class="section-wrap" id="all-findings"><div class="container">'
        '<details class="section-collapse" open>'
        f"<summary><h2>All Findings ({len(findings)})</h2></summary>"
        f'<p class="section-desc">{active_count} active + {superseded_count} superseded</p>'
        f'<div class="toc">{toc_html}</div>'
        "</details></div></div>"
    )

    # Navigation links (only for non-empty sections).
    nav_items: List[str] = []
    if video_path:
        nav_items.append('<a href="#hero-video">Video</a>')
    for sec_id, sec_title, cls_key, _ in MAIN_SECTIONS:
        if cls_key is not None:
            if groups.get(cls_key):
                nav_items.append(f'<a href="#{sec_id}">{sec_title}</a>')
        else:
            if groups.get("behavior-change") or groups.get("new-feature"):
                nav_items.append(f'<a href="#{sec_id}">{sec_title}</a>')
    nav_items.append('<a href="#all-findings">All Findings</a>')

    # Stats grid.
    stats = _render_stats(groups, pr_count)

    # Timestamp.
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{esc(title)}</title>
<style>
{_css()}
</style>
</head>
<body>

<header>
<div class="container">
<h1>{esc(title)}</h1>
<p class="subtitle">{esc(baseline_version)} vs {esc(candidate_version)}</p>
{stats}
</div>
</header>

<nav><div class="container">{''.join(nav_items)}</div></nav>

{''.join(s for s in body_sections if s)}

<footer>
<p>Generated {now}</p>
</footer>

</body>
</html>"""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate an interactive HTML regression report from a findings CSV."
    )
    parser.add_argument("--csv", required=True, type=Path,
                        help="Path to findings CSV (required)")
    parser.add_argument("--screenshots", type=Path, default=None,
                        help="Directory containing screenshot/video evidence assets")
    parser.add_argument("--output", type=Path, default=None,
                        help="Output HTML file path")
    parser.add_argument("--title", default="Regression Report",
                        help="Report title (default: Regression Report)")
    parser.add_argument("--baseline-version", default="baseline",
                        help="Baseline version label")
    parser.add_argument("--candidate-version", default="candidate",
                        help="Candidate version label")
    parser.add_argument("--video", default=None,
                        help="Optional hero video path (relative to output)")
    parser.add_argument("--jira-url", default=DEFAULT_JIRA_URL,
                        help=f"Jira browse URL prefix (default: {DEFAULT_JIRA_URL})")
    parser.add_argument("--validate", action="store_true",
                        help="Validate screenshot references and exit")
    parser.add_argument("--strict", action="store_true",
                        help="Exit 1 if any findings are unverified")

    args = parser.parse_args()

    # Load CSV.
    if not args.csv.exists():
        print(f"Error: CSV not found: {args.csv}", file=sys.stderr)
        sys.exit(1)
    findings = load_findings(args.csv)
    print(f"Loaded {len(findings)} findings from {args.csv}", file=sys.stderr)

    # Validation.
    errors = validate_findings(
        findings,
        screenshots_dir=args.screenshots if args.validate else None,
        strict=args.strict,
    )
    if errors:
        for err in errors:
            print(f"Error: {err}", file=sys.stderr)
        sys.exit(1)

    if args.validate:
        print("Validation passed.", file=sys.stderr)
        sys.exit(0)

    # Generation requires --output.
    if not args.output:
        print("Error: --output is required when generating a report.", file=sys.stderr)
        sys.exit(1)

    # Determine relative path from output to screenshots dir for <img src>.
    screenshots_rel = "screenshots"
    if args.screenshots and args.output:
        try:
            screenshots_rel = str(
                args.screenshots.resolve().relative_to(args.output.resolve().parent)
            )
        except ValueError:
            # Not relative — use absolute or keep default.
            screenshots_rel = str(args.screenshots.resolve())

    html_content = generate_html(
        findings,
        title=args.title,
        baseline_version=args.baseline_version,
        candidate_version=args.candidate_version,
        video_path=args.video,
        jira_url=args.jira_url,
        screenshots_rel=screenshots_rel,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(html_content, encoding="utf-8")

    # Summary.
    groups = classify_findings(findings)
    print(f"\nGenerated: {args.output}", file=sys.stderr)
    print(f"  Regressions:  {len(groups.get('regression', []))}", file=sys.stderr)
    print(f"  Fixed:        {len(groups.get('fixed', []))}", file=sys.stderr)
    print(f"  Pre-existing: {len(groups.get('pre-existing', []))}", file=sys.stderr)
    n_imp = len(groups.get("behavior-change", [])) + len(groups.get("new-feature", []))
    print(f"  Improvements: {n_imp}", file=sys.stderr)
    print(f"  Superseded:   {len(groups.get('superseded', []))}", file=sys.stderr)
    print(f"  PRs:          {_unique_prs(findings)}", file=sys.stderr)


if __name__ == "__main__":
    main()

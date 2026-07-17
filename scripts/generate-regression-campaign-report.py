#!/usr/bin/env python3
"""Regression-rebuild campaign — Stage 5 report generator.

Consumes the **post-triage** master ``findings.csv`` (the shared contract
schema; see ``scripts/regression_findings.py``) and renders a self-contained
HTML report. Distinct from ``scripts/generate-regression-report.py`` (the legacy
``/regression`` report on the old Title/Behavior schema) — this one is built for
the fleet campaign's leaner schema and adds:

  * a **device/OS coverage matrix** (cells × taxonomy),
  * **dedup-cluster grouping** (one canonical block per root cause, with the
    cells it reproduces in),
  * **taxonomy + severity + disposition** breakdowns,
  * a **visual-diff gallery** (``screenshot_pair`` = ``baseline|candidate``),
  * **evidence links** (``evidence_paths`` = ``;``-joined).

Schema (one row per raw finding)::

    id,area,device_cell,severity,classification,verified,evidence_paths,
    screenshot_pair,first_seen_commit,dedup_cluster,disposition

Usage::

    python3 scripts/generate-regression-campaign-report.py \
        --csv .regression-runs/<run-id>/findings.csv \
        --output .regression-runs/<run-id>/report.html \
        [--run-id <run-id>] [--assets-root .regression-runs/<run-id>]

Pure stdlib — no third-party dependencies.
"""
from __future__ import annotations

import argparse
import html
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

# Shared findings module (single source of truth for the schema + CSV I/O).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import regression_findings as rf  # noqa: E402

FINDINGS_COLUMNS = list(rf.FINDINGS_COLUMNS)

SEVERITY_COLORS = {
    "blocker": "#dc2626", "major": "#ea580c", "minor": "#ca8a04",
    "cosmetic": "#6b7280", "": "#9ca3af",
}
SEVERITY_ORDER = {"blocker": 0, "major": 1, "minor": 2, "cosmetic": 3, "": 4}

CLASSIFICATION_COLORS = {
    "crash": "#dc2626", "device-divergence": "#b91c1c", "visual-parity": "#7c3aed",
    "perf": "#0891b2", "defer-flag": "#ca8a04", "keychain-auth-state": "#ca8a04",
    "alert-presentation": "#ca8a04", "build-staleness": "#ca8a04",
    "other": "#6b7280", "unknown": "#9ca3af",
}
POLLUTION_CLASSES = {
    "defer-flag", "keychain-auth-state", "alert-presentation", "build-staleness",
}
DISPOSITION_LABELS = {
    "file-jira": "File Jira", "ticket-as-flake": "Flake ticket",
    "needs-verify": "Needs re-verify", "drop": "Dropped",
}
DISPOSITION_COLORS = {
    "file-jira": "#dc2626", "ticket-as-flake": "#ca8a04",
    "needs-verify": "#0891b2", "drop": "#6b7280", "": "#9ca3af",
}


def load_findings(csv_path: Path) -> List[Dict[str, str]]:
    """Read the post-triage master via the shared module (single source of
    truth), normalising so every contract column exists for rendering."""
    rows = list(rf.read_findings(str(csv_path)))
    for r in rows:
        for c in FINDINGS_COLUMNS:
            r.setdefault(c, "")
    return rows


def _g(row: Dict[str, str], key: str) -> str:
    return (row.get(key) or "").strip()


def _esc(s: str) -> str:
    return html.escape(s or "")


def _is_true(v: str) -> bool:
    return (v or "").strip().lower() in {"true", "yes", "1"}


def _chip(text: str, color: str) -> str:
    return (f'<span class="chip" style="background:{color}">'
            f'{_esc(text)}</span>')


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def cluster_groups(rows: List[Dict[str, str]]) -> Dict[str, List[Dict[str, str]]]:
    groups: Dict[str, List[Dict[str, str]]] = defaultdict(list)
    for r in rows:
        groups[_g(r, "dedup_cluster") or "(unclustered)"].append(r)
    return dict(groups)


def _counts(rows: List[Dict[str, str]], key: str) -> Dict[str, int]:
    out: Dict[str, int] = defaultdict(int)
    for r in rows:
        out[_g(r, key) or "(none)"] += 1
    return dict(out)


def coverage_matrix(rows):
    """cells × classification grid of counts, plus row/col order."""
    cells = sorted({_g(r, "device_cell") or "(none)" for r in rows})
    classes = sorted({_g(r, "classification") or "(none)" for r in rows})
    grid: Dict[str, Dict[str, int]] = {c: defaultdict(int) for c in cells}
    for r in rows:
        grid[_g(r, "device_cell") or "(none)"][
            _g(r, "classification") or "(none)"] += 1
    return cells, classes, grid


def cluster_sort_key(rows: List[Dict[str, str]]):
    """Order clusters by worst severity then size (worst first)."""
    sev = min((SEVERITY_ORDER.get(_g(r, "severity"), 4) for r in rows),
              default=4)
    return (sev, -len(rows))


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

CSS = """
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  margin: 0; background: #f8fafc; color: #1e293b; }
header { background: #0f172a; color: #fff; padding: 24px 32px; }
header h1 { margin: 0 0 4px; font-size: 22px; }
header .meta { color: #94a3b8; font-size: 13px; }
main { max-width: 1100px; margin: 0 auto; padding: 24px 32px 64px; }
section { background: #fff; border: 1px solid #e2e8f0; border-radius: 10px;
  padding: 20px 24px; margin-bottom: 20px; }
section h2 { margin: 0 0 14px; font-size: 17px; }
.chip { display: inline-block; color: #fff; border-radius: 999px;
  padding: 2px 10px; font-size: 11px; font-weight: 600; margin-right: 4px; }
.cards { display: flex; gap: 12px; flex-wrap: wrap; }
.card { flex: 1 1 120px; background: #f1f5f9; border-radius: 8px; padding: 14px; }
.card .n { font-size: 26px; font-weight: 700; }
.card .l { font-size: 12px; color: #64748b; text-transform: uppercase;
  letter-spacing: .04em; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { border: 1px solid #e2e8f0; padding: 6px 10px; text-align: left; }
th { background: #f1f5f9; }
td.num { text-align: center; font-variant-numeric: tabular-nums; }
td.zero { color: #cbd5e1; }
.cluster { border: 1px solid #e2e8f0; border-radius: 8px; margin-bottom: 14px; }
.cluster > summary { cursor: pointer; padding: 12px 16px; font-weight: 600;
  list-style: none; display: flex; align-items: center; gap: 8px; }
.cluster > summary::-webkit-details-marker { display: none; }
.cluster .body { padding: 0 16px 14px; }
.finding { border-top: 1px solid #f1f5f9; padding: 10px 0; font-size: 13px; }
.finding .id { font-weight: 700; }
.muted { color: #64748b; }
.evi a { color: #2563eb; text-decoration: none; margin-right: 8px;
  font-size: 12px; }
.gallery { display: flex; gap: 16px; flex-wrap: wrap; }
.pair { border: 1px solid #e2e8f0; border-radius: 8px; padding: 10px;
  width: 320px; }
.pair img { width: 100%; border: 1px solid #e2e8f0; border-radius: 4px;
  display: block; margin-top: 4px; }
.pair .cap { font-size: 11px; color: #64748b; }
.empty { color: #94a3b8; font-style: italic; }
"""


def _evidence_links(row: Dict[str, str], assets_root: Optional[str]) -> str:
    raw = _g(row, "evidence_paths")
    if not raw:
        return '<span class="muted">no evidence</span>'
    parts = [p.strip() for p in raw.split(rf.EVIDENCE_SEP) if p.strip()]
    out = []
    for p in parts:
        href = f"{assets_root.rstrip('/')}/{p}" if assets_root else p
        out.append(f'<a href="{_esc(href)}">{_esc(p)}</a>')
    return '<span class="evi">' + "".join(out) + "</span>"


def _render_finding(row: Dict[str, str], assets_root: Optional[str]) -> str:
    sev = _g(row, "severity")
    disp = _g(row, "disposition")
    verified = "✓ verified" if _is_true(_g(row, "verified")) else "unverified"
    return (
        f'<div class="finding">'
        f'<span class="id">{_esc(_g(row, "id") or "?")}</span> '
        f'{_chip(sev or "—", SEVERITY_COLORS.get(sev, "#9ca3af"))}'
        f'{_chip(DISPOSITION_LABELS.get(disp, disp or "—"), DISPOSITION_COLORS.get(disp, "#9ca3af"))}'
        f'<span class="muted"> · {_esc(_g(row, "area") or "—")} · '
        f'{_esc(_g(row, "device_cell") or "—")} · {verified}'
        f'{(" · " + _esc(_g(row, "first_seen_commit"))) if _g(row, "first_seen_commit") else ""}'
        f'</span><br>'
        f'{_evidence_links(row, assets_root)}'
        f'</div>'
    )


def _render_cluster(cid, rows, assets_root):
    worst = min((SEVERITY_ORDER.get(_g(r, "severity"), 4) for r in rows),
                default=4)
    worst_name = next((k for k, v in SEVERITY_ORDER.items() if v == worst), "")
    classes = sorted({_g(r, "classification") for r in rows if _g(r, "classification")})
    cells = sorted({_g(r, "device_cell") for r in rows if _g(r, "device_cell")})
    cls_chips = "".join(
        _chip(c, CLASSIFICATION_COLORS.get(c, "#6b7280")) for c in classes)
    findings = "".join(_render_finding(r, assets_root) for r in rows)
    return (
        f'<details class="cluster"{" open" if worst <= 1 else ""}>'
        f'<summary>'
        f'{_chip(worst_name or "—", SEVERITY_COLORS.get(worst_name, "#9ca3af"))}'
        f'<span>{_esc(cid)}</span>'
        f'<span class="muted">· {len(rows)} finding(s) · cells: '
        f'{_esc(", ".join(cells) or "—")}</span>'
        f'<span style="margin-left:auto">{cls_chips}</span>'
        f'</summary>'
        f'<div class="body">{findings}</div>'
        f'</details>'
    )


def _render_gallery(rows, assets_root):
    pairs = []
    for r in rows:
        sp = _g(r, "screenshot_pair")
        if not sp or rf.SCREENSHOT_SEP not in sp:
            continue
        base, cand = (sp.split(rf.SCREENSHOT_SEP, 1) + [""])[:2]
        def src(p):
            p = p.strip()
            if not p:
                return ""
            return f"{assets_root.rstrip('/')}/{p}" if assets_root else p
        pairs.append(
            f'<div class="pair"><div class="cap">{_esc(_g(r,"id"))} · '
            f'{_esc(_g(r,"area"))} · {_esc(_g(r,"device_cell"))}</div>'
            f'<div class="cap">baseline</div>'
            f'<img src="{_esc(src(base))}" alt="baseline">'
            f'<div class="cap">candidate</div>'
            f'<img src="{_esc(src(cand))}" alt="candidate"></div>'
        )
    if not pairs:
        return '<p class="empty">No screenshot pairs in this run.</p>'
    return '<div class="gallery">' + "".join(pairs) + "</div>"


def render(rows, run_id, assets_root):
    total = len(rows)
    by_sev = _counts(rows, "severity")
    by_cls = _counts(rows, "classification")
    by_disp = _counts(rows, "disposition")
    groups = cluster_groups(rows)
    file_jira = by_disp.get("file-jira", 0)
    blockers = by_sev.get("blocker", 0)
    pollution = sum(1 for r in rows if _g(r, "classification") in POLLUTION_CLASSES)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    cards = "".join(
        f'<div class="card"><div class="n">{n}</div><div class="l">{lbl}</div></div>'
        for n, lbl in [
            (total, "findings"), (len(groups), "clusters"),
            (blockers, "blockers"), (file_jira, "to file"),
            (pollution, "pollution"),
        ]
    )

    # Coverage matrix
    cells, classes, grid = coverage_matrix(rows)
    head = "".join(f"<th>{_esc(c)}</th>" for c in classes)
    matrix_rows = ""
    for cell in cells:
        tds = ""
        for c in classes:
            n = grid[cell].get(c, 0)
            cls = "num zero" if n == 0 else "num"
            tds += f'<td class="{cls}">{n or ""}</td>'
        matrix_rows += f"<tr><th>{_esc(cell)}</th>{tds}</tr>"
    matrix = (f'<table><tr><th>cell \\ class</th>{head}</tr>{matrix_rows}</table>'
              if rows else '<p class="empty">No findings.</p>')

    def breakdown(counts, colors):
        if not counts:
            return '<p class="empty">none</p>'
        return " ".join(
            _chip(f"{k}: {v}", colors.get(k, "#6b7280"))
            for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))

    ordered = sorted(groups.items(),
                     key=lambda kv: cluster_sort_key(kv[1]))
    clusters_html = "".join(
        _render_cluster(cid, rs, assets_root) for cid, rs in ordered) \
        or '<p class="empty">No clusters.</p>'

    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Regression Campaign Report{(' — ' + _esc(run_id)) if run_id else ''}</title>
<style>{CSS}</style></head><body>
<header>
  <h1>Regression Campaign Report</h1>
  <div class="meta">{('run: ' + _esc(run_id) + ' · ') if run_id else ''}\
generated {now} · {total} findings · {len(groups)} dedup clusters</div>
</header>
<main>
  <section><h2>Summary</h2><div class="cards">{cards}</div></section>
  <section><h2>Device / OS coverage matrix</h2>{matrix}</section>
  <section><h2>Breakdowns</h2>
    <p><strong>Severity:</strong> {breakdown(by_sev, SEVERITY_COLORS)}</p>
    <p><strong>Classification:</strong> {breakdown(by_cls, CLASSIFICATION_COLORS)}</p>
    <p><strong>Disposition:</strong> {breakdown(by_disp, DISPOSITION_COLORS)}</p>
  </section>
  <section><h2>Findings by dedup cluster</h2>{clusters_html}</section>
  <section><h2>Visual-diff gallery</h2>{_render_gallery(rows, assets_root)}</section>
</main></body></html>"""


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Campaign findings.csv -> HTML.")
    ap.add_argument("--csv", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--assets-root", default=None,
                    help="path prefix for evidence/screenshot links "
                         "(relative to the report's location)")
    args = ap.parse_args(argv)

    if not args.csv.exists():
        print(f"Error: findings CSV not found: {args.csv}", file=sys.stderr)
        return 2

    rows = load_findings(args.csv)
    html_doc = render(rows, args.run_id, args.assets_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(html_doc, encoding="utf-8")
    print(f"Wrote report: {args.output} "
          f"({len(rows)} findings, {len(cluster_groups(rows))} clusters, "
          f"{len(html_doc)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

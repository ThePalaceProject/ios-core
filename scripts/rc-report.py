#!/usr/bin/env python3
"""rc-report.py — Stage-5 of the RC regression campaign: findings.csv -> report.html.

Driver contract (palace-pm/campaign/rc-campaign.sh, stage 5):
    python3 scripts/rc-report.py --run <run-dir>
produces `<run-dir>/report.html`. Drop-in: the pipeline planner picks it up with
no driver change.

A `<run-dir>` is a `.regression-runs/<run-id>/` artifact dir. Its shape (discovered
from live runs + REGRESSION-BUILD-PLAN.md §2):
    <run-dir>/findings.csv                      <- the merged master (this input)
    <run-dir>/findings/<cell>__<area>.csv       <- per-worker shards (already merged)
    <run-dir>/baselines/<cell>/<area>/*.png
    <run-dir>/candidates/<cell>/<area>/*.png
    <run-dir>/diffs/<cell>/<area>/*.png
    <run-dir>/logs/ , <run-dir>/crashes/
    <run-dir>/report.html                       <- OUTPUT

Two responsibilities (REGRESSION-BUILD-PLAN.md §4.3 stage 5):
  1. Aggregate findings.csv into a readable report.html: grouped by
     area / device_cell / severity, verified vs unverified, screenshot-pair
     image diffs surfaced inline, and a clear GATING vs NON-GATING split. A
     demoted (non-gating / fragile-dispositioned) finding is STILL shown,
     flagged — demote != hide (Phase-2 handoff §6).
  2. For each REAL (verified + gating) regression, emit a ForgeOS changeset
     stub under `.forgeos/changesets/<slug>/fix-contract.md` so the coordinator
     can run `/forge-review` SoD -> Chairman handoff.

Minimum mechanism: stdlib only (csv via regression_findings, html, argparse,
pathlib). No templating framework, no deps. Robust to a missing/empty
findings.csv (empty run => valid empty report, exit 0).

Single-source-of-truth: CSV I/O goes through regression_findings (the ratified
module) so there is exactly one schema implementation.
"""
from __future__ import annotations

import argparse
import html
import importlib.util
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SCRIPTS = Path(__file__).resolve().parent

# regression_findings is the ratified findings I/O module (read_findings +
# FINDINGS_COLUMNS). Import by path — it has no hyphen, but load it the same
# robust way the sibling tests do so this works regardless of cwd / sys.path.
_spec = importlib.util.spec_from_file_location(
    "regression_findings", SCRIPTS / "regression_findings.py")
rf = importlib.util.module_from_spec(_spec)
# Register before exec: regression_findings uses @dataclass, which resolves the
# class's __module__ via sys.modules during class creation.
sys.modules["regression_findings"] = rf
_spec.loader.exec_module(rf)


# ---------------------------------------------------------------------------
# Gating decision (consistent with Stage-4 regression-triage.py).
# ---------------------------------------------------------------------------
# A REAL regression that the campaign blocks the tag on is one that the
# coordinator hermetic re-verify CONFIRMED (verified=true) AND that triage
# routed to file a Jira (disposition=file-jira) — i.e. a real product bug, not
# a flake/pollution/known-fragile. Everything else is non-gating: it still SHOWS
# (flagged), it just does not block and does not get a changeset stub.
#
# Two disposition vocabularies appear in the wild and we accept BOTH:
#   - Stage-4 triage output: file-jira | ticket-as-flake | drop | needs-verify
#   - harness pre-classification: non-gating-known-fragile (+ blank)
# Only `file-jira` is gating; everything else (incl. blank/unknown) is non-gating.
_TRUE = {"true", "yes", "1"}


def is_verified(row: dict) -> bool:
    return (row.get("verified") or "").strip().lower() in _TRUE


def disposition(row: dict) -> str:
    return (row.get("disposition") or "").strip().lower()


def is_gating(row: dict) -> bool:
    """A real, tag-blocking regression: verified AND dispositioned file-jira."""
    return is_verified(row) and disposition(row) == "file-jira"


# Severity ordering for stable, worst-first display.
_SEV_ORDER = {"blocker": 0, "major": 1, "minor": 2, "cosmetic": 3, "": 4}


def sev_rank(row: dict) -> int:
    return _SEV_ORDER.get((row.get("severity") or "").strip().lower(), 4)


# ---------------------------------------------------------------------------
# Screenshot-pair handling.
# ---------------------------------------------------------------------------

def parse_screenshot_pair(row: dict) -> tuple[Optional[str], Optional[str]]:
    """Return (baseline, candidate) paths from the 'baseline|candidate' cell.
    Either side may be empty (e.g. '|cand.png' => baseline None)."""
    raw = (row.get("screenshot_pair") or "").strip()
    if not raw:
        return (None, None)
    base, _, cand = raw.partition(rf.SCREENSHOT_SEP)
    return (base.strip() or None, cand.strip() or None)


def diff_for(run_dir: Path, base: Optional[str], cand: Optional[str]) -> Optional[Path]:
    """Best-effort: find a diff PNG matching the candidate's cell/area/name under
    <run-dir>/diffs/. The candidate path looks like
    .../candidates/<cell>/<area>/<name>-final.png; the diff (if visual-diff ran)
    mirrors it under diffs/. Returns the path if it exists, else None."""
    if not cand:
        return None
    p = Path(cand)
    # Map a candidates/* path to diffs/* with the same tail.
    parts = list(p.parts)
    if "candidates" in parts:
        i = parts.index("candidates")
        tail = Path(*parts[i + 1:])
        guess = run_dir / "diffs" / tail
        if guess.exists():
            return guess
    return None


def rel_to_report(run_dir: Path, target: str | Path) -> str:
    """Path of an artifact relative to the report (report.html lives in run_dir),
    so the <img>/<a> links resolve when the run-dir is opened in a browser.
    Absolute paths that live under run_dir become relative; anything else is
    returned as a file:// URI so it still resolves locally."""
    t = Path(target)
    try:
        return t.resolve().relative_to(run_dir.resolve()).as_posix()
    except ValueError:
        if t.is_absolute():
            return t.as_uri()
        # Relative path already (recorded relative to run_dir) — use as-is.
        return t.as_posix()


# ---------------------------------------------------------------------------
# HTML rendering (hand-rolled; everything user-derived passes through esc()).
# ---------------------------------------------------------------------------

def esc(s) -> str:
    return html.escape("" if s is None else str(s))


_CSS = """
:root{--bg:#0f1115;--card:#181b21;--line:#2a2f3a;--fg:#e6e8eb;--mut:#9aa3ad;
--gate:#ff5d5d;--ok:#36c98f;--warn:#f0b429;--demote:#7a8290;}
*{box-sizing:border-box}
body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
background:var(--bg);color:var(--fg);margin:0;padding:24px;}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 10px;
border-bottom:1px solid var(--line);padding-bottom:6px}
h3{font-size:14px;margin:18px 0 6px;color:var(--mut)}
.meta{color:var(--mut);font-size:12px;margin-bottom:18px}
.summary{display:flex;gap:14px;flex-wrap:wrap;margin:14px 0}
.stat{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:10px 16px;min-width:120px}
.stat .n{font-size:24px;font-weight:600}.stat .l{color:var(--mut);font-size:12px}
.stat.gate .n{color:var(--gate)}.stat.ok .n{color:var(--ok)}
.f{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--demote);
border-radius:8px;padding:12px 14px;margin:10px 0}
.f.gating{border-left-color:var(--gate)}
.tag{display:inline-block;font-size:11px;font-weight:600;border-radius:4px;
padding:1px 7px;margin-right:6px;vertical-align:middle}
.tag.gate{background:#3a1414;color:var(--gate)}
.tag.demote{background:#23272e;color:var(--demote)}
.tag.unver{background:#3a2f14;color:var(--warn)}
.tag.ver{background:#143a2a;color:var(--ok)}
.tag.sev{background:#23272e;color:var(--fg)}
.tag.cls{background:#1c2330;color:#7fb0ff}
.fid{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--mut)}
.kv{color:var(--mut);font-size:12px;margin-top:4px}
.kv code{color:var(--fg);word-break:break-all}
.shots{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
.shots figure{margin:0}.shots figcaption{font-size:11px;color:var(--mut);text-align:center}
.shots img{max-width:240px;max-height:360px;border:1px solid var(--line);border-radius:6px;display:block}
.empty{color:var(--mut);font-style:italic;padding:14px 0}
a{color:#7fb0ff}
details{margin:6px 0}summary{cursor:pointer;color:var(--mut)}
.todo{background:#1c1810;border:1px solid #4a3a14;border-radius:8px;padding:12px 14px;margin:10px 0}
"""


def _finding_card(run_dir: Path, row: dict) -> str:
    gating = is_gating(row)
    ver = is_verified(row)
    sev = (row.get("severity") or "").strip() or "unset"
    cls = (row.get("classification") or "").strip() or "unknown"
    disp = (row.get("disposition") or "").strip() or "untriaged"
    fid = row.get("id") or "(no-id)"

    tags = []
    tags.append('<span class="tag gate">GATING</span>' if gating
                else '<span class="tag demote">non-gating</span>')
    tags.append('<span class="tag ver">verified</span>' if ver
                else '<span class="tag unver">unverified</span>')
    tags.append(f'<span class="tag sev">sev:{esc(sev)}</span>')
    tags.append(f'<span class="tag cls">{esc(cls)}</span>')
    tags.append(f'<span class="tag demote">disp:{esc(disp)}</span>')

    rows_html = [f'<div>{"".join(tags)}</div>',
                 f'<div class="fid">{esc(fid)}</div>']

    area = row.get("area") or ""
    cell = row.get("device_cell") or ""
    rows_html.append(f'<div class="kv">area <code>{esc(area)}</code> &middot; '
                     f'cell <code>{esc(cell)}</code> &middot; '
                     f'first-seen <code>{esc(row.get("first_seen_commit") or "?")}</code></div>')

    cluster = (row.get("dedup_cluster") or "").strip()
    if cluster:
        rows_html.append(f'<div class="kv">dedup-cluster <code>{esc(cluster)}</code></div>')

    # Evidence paths (links if they resolve under run-dir).
    ev = [e for e in (row.get("evidence_paths") or "").split(rf.EVIDENCE_SEP) if e.strip()]
    if ev:
        links = " &middot; ".join(
            f'<a href="{esc(rel_to_report(run_dir, e))}">{esc(Path(e).name)}</a>' for e in ev)
        rows_html.append(f'<div class="kv">evidence: {links}</div>')

    # Screenshot pair + diff (image-diff surfacing).
    base, cand = parse_screenshot_pair(row)
    if base or cand:
        figs = []
        for label, path in (("baseline", base), ("candidate", cand)):
            if path:
                src = esc(rel_to_report(run_dir, path))
                figs.append(f'<figure><img src="{src}" loading="lazy" '
                            f'alt="{label}"><figcaption>{label}</figcaption></figure>')
        d = diff_for(run_dir, base, cand)
        if d:
            src = esc(rel_to_report(run_dir, d))
            figs.append(f'<figure><img src="{src}" loading="lazy" '
                        f'alt="diff"><figcaption>diff</figcaption></figure>')
        rows_html.append(f'<div class="shots">{"".join(figs)}</div>')

    cls_attr = "f gating" if gating else "f"
    return f'<div class="{cls_attr}">{"".join(rows_html)}</div>'


def _group_section(run_dir: Path, title: str, rows: list[dict]) -> str:
    """Render a section grouped by area -> device_cell, severity-sorted within."""
    if not rows:
        return f'<h2>{esc(title)} <span class="fid">(0)</span></h2><div class="empty">none</div>'
    out = [f'<h2>{esc(title)} <span class="fid">({len(rows)})</span></h2>']
    by_area: dict[str, list[dict]] = {}
    for r in rows:
        by_area.setdefault(r.get("area") or "(no-area)", []).append(r)
    for area in sorted(by_area):
        out.append(f'<h3>{esc(area)}</h3>')
        by_cell: dict[str, list[dict]] = {}
        for r in by_area[area]:
            by_cell.setdefault(r.get("device_cell") or "(no-cell)", []).append(r)
        for cell in sorted(by_cell):
            cell_rows = sorted(by_cell[cell], key=sev_rank)
            out.append(f'<details open><summary>{esc(cell)} '
                       f'({len(cell_rows)})</summary>')
            for r in cell_rows:
                out.append(_finding_card(run_dir, r))
            out.append('</details>')
    return "".join(out)


def render_html(run_dir: Path, rows: list[dict], changesets: list[dict]) -> str:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    total = len(rows)
    gating = [r for r in rows if is_gating(r)]
    nongating = [r for r in rows if not is_gating(r)]
    verified = sum(1 for r in rows if is_verified(r))

    head = (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<title>RC regression report — {esc(run_dir.name)}</title>'
        f'<style>{_CSS}</style></head><body>'
    )
    hdr = (
        f'<h1>RC regression report</h1>'
        f'<div class="meta">run <code>{esc(run_dir.name)}</code> &middot; '
        f'generated {esc(now)} &middot; schema: findings.csv (Stage-5)</div>'
    )
    summary = (
        '<div class="summary">'
        f'<div class="stat"><div class="n">{total}</div><div class="l">total findings</div></div>'
        f'<div class="stat gate"><div class="n">{len(gating)}</div><div class="l">GATING (real, blocks tag)</div></div>'
        f'<div class="stat"><div class="n">{len(nongating)}</div><div class="l">non-gating (shown, flagged)</div></div>'
        f'<div class="stat ok"><div class="n">{verified}</div><div class="l">verified</div></div>'
        '</div>'
    )

    if total == 0:
        body = ('<div class="empty">Empty run — findings.csv has no findings. '
                'This is a valid clean (or not-yet-discovered) result.</div>')
    else:
        body = (
            _group_section(run_dir, "Gating findings — real regressions (block the tag)", gating)
            + _group_section(run_dir, "Non-gating findings — demoted/unverified/fragile (shown, do not block)", nongating)
        )

    # ForgeOS changeset section.
    cs = ['<h2>ForgeOS changeset stubs — '
          f'<span class="fid">({len(changesets)})</span></h2>']
    if not changesets:
        cs.append('<div class="empty">No gating regressions — no changeset stubs '
                  'emitted. (Stubs are written only for verified, file-jira findings.)</div>')
    else:
        cs.append('<div class="todo">Each gating regression below has a ForgeOS '
                  'changeset stub written under '
                  '<code>.forgeos/changesets/&lt;slug&gt;/fix-contract.md</code>. '
                  'Coordinator: run <code>/forge-review</code> per changeset for the '
                  'SoD reviews, then hand off to the Chairman.</div>')
        for c in changesets:
            cs.append(f'<div class="f gating"><div class="fid">{esc(c["id"])}</div>'
                      f'<div class="kv">slug <code>{esc(c["slug"])}</code> &middot; '
                      f'stub <code>{esc(c["path"])}</code></div></div>')

    return head + hdr + summary + body + "".join(cs) + "</body></html>"


# ---------------------------------------------------------------------------
# ForgeOS changeset stub emission.
# ---------------------------------------------------------------------------

def _slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:60] or "regression"


def repo_root_for(run_dir: Path) -> Optional[Path]:
    """Walk up from the run-dir to the repo root (the dir holding .forgeos).
    Returns None if not found (e.g. a synthetic run-dir outside the repo)."""
    for d in [run_dir, *run_dir.parents]:
        if (d / ".forgeos" / "changesets").is_dir():
            return d
    return None


def emit_changeset_stub(repo_root: Path, run_dir: Path, row: dict) -> dict:
    """Write a minimal, correct ForgeOS changeset stub for one gating regression.

    Mirrors the existing changeset shape (.forgeos/changesets/<slug>/fix-contract.md).
    This is a STUB the coordinator completes + drives through /forge-review SoD —
    we do not invent a forge API, we write the same on-disk artifact the existing
    changesets use, pre-filled from the finding's evidence.
    """
    fid = row.get("id") or "regression"
    slug = "rc-regression-" + _slugify(fid)
    cs_dir = repo_root / ".forgeos" / "changesets" / slug
    cs_dir.mkdir(parents=True, exist_ok=True)
    path = cs_dir / "fix-contract.md"

    ev = [e for e in (row.get("evidence_paths") or "").split(rf.EVIDENCE_SEP) if e.strip()]
    base, cand = parse_screenshot_pair(row)
    shots = [p for p in (base, cand) if p]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    ev_md = "\n".join(f"  - `{e}`" for e in ev) or "  - (none cited)"
    shots_md = "\n".join(f"  - `{s}`" for s in shots) or "  - (none)"

    content = f"""# Fix-contract — RC regression `{fid}`

**Branch:** `fix/{slug}`
**Created:** {now}
**Source:** RC-CAMPAIGN Stage-5 report (`scripts/rc-report.py`)
**Regression run:** `{run_dir.name}`
**Status:** STUB — auto-generated from a verified, gating (file-jira) finding.
Coordinator: complete sections 1-4 from the cited evidence, then run
`/forge-review` for the SoD reviews and hand off to the Chairman.

---

## 0. Finding (from findings.csv)

| field | value |
|---|---|
| id | `{fid}` |
| area | {row.get('area') or '?'} |
| device_cell | {row.get('device_cell') or '?'} |
| severity | {row.get('severity') or '?'} |
| classification | {row.get('classification') or '?'} |
| verified | {row.get('verified') or '?'} |
| disposition | {row.get('disposition') or '?'} |
| first_seen_commit | `{row.get('first_seen_commit') or '?'}` |
| dedup_cluster | `{row.get('dedup_cluster') or '(none)'}` |

**Evidence:**
{ev_md}

**Screenshot pair:**
{shots_md}

---

## 1. Problem (one paragraph)

> TODO (coordinator): describe the regression from the cited evidence above.

## 2. Scope (in)

> TODO

## 3. Fix approach

> TODO

## 4. Verification

The finding was reproduced under the coordinator hermetic re-verify gate
(`verified=true`). Re-run the cited tests in a clean worktree (full
`scripts/tests/` suite) to confirm the fix closes it without regressing the suite.
"""
    path.write_text(content)
    return {"id": fid, "slug": slug, "path": str(path.relative_to(repo_root))}


def emit_changesets(run_dir: Path, gating_rows: list[dict]) -> list[dict]:
    """Emit a stub per gating regression. If the run-dir is not inside a repo
    with .forgeos/changesets (e.g. a synthetic test run-dir), skip emission and
    return [] — the report still lists the gating findings as candidates."""
    if not gating_rows:
        return []
    repo_root = repo_root_for(run_dir)
    if repo_root is None:
        return []
    return [emit_changeset_stub(repo_root, run_dir, r) for r in gating_rows]


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

def generate(run_dir: Path) -> Path:
    csv_path = run_dir / "findings.csv"
    rows = rf.read_findings(str(csv_path))  # [] if missing/empty (robust)
    gating_rows = [r for r in rows if is_gating(r)]
    changesets = emit_changesets(run_dir, gating_rows)
    out = run_dir / "report.html"
    out.write_text(render_html(run_dir, rows, changesets))
    return out


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="Stage-5 RC regression report: findings.csv -> report.html "
                    "+ ForgeOS changeset stubs for gating regressions.")
    p.add_argument("--run", required=True, type=Path,
                   help="regression run-dir (under .regression-runs/)")
    args = p.parse_args(argv)

    run_dir = args.run
    if not run_dir.is_dir():
        print(f"error: --run {run_dir} is not a directory", file=sys.stderr)
        return 2

    out = generate(run_dir)
    rows = rf.read_findings(str(run_dir / "findings.csv"))
    gating = sum(1 for r in rows if is_gating(r))
    print(f"rc-report: {len(rows)} finding(s), {gating} gating -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

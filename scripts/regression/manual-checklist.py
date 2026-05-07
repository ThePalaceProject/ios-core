#!/usr/bin/env python3
"""Generate MANUAL_CHECKLIST.md from TEST_MATRIX, changed-files diff, and in-field signal.

Output is an actionable, ordered list of checkbox items. Order:
1. In-field-signal areas (highest priority)
2. Auth coverage matrix (one row per auth type — explicit)
3. P0 areas with changed files in the diff
4. P0 areas with no changes (sanity)
5. P1 areas with changes

Usage:
    python3 scripts/regression/manual-checklist.py \
        --output-dir ~/Desktop/regression-PP-XXXX \
        --baseline 3.0.0 --candidate 3.1.0
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

P0_AREAS = [
    ("A1", "Auth — basic (A1QA Test Library)", "barcode + PIN sign-in"),
    ("A2", "Auth — token (Lyrasis Reads)", "basic-token sign-in"),
    ("A3", "Auth — SAML", "SAML library + IdP round-trip + SMS"),
    ("A4", "Auth — OIDC", "OIDC library + IdP round-trip"),
    ("A5", "Auth — anonymous (Palace Bookshelf)", "no sign-in form"),
    ("A6", "Sign-out confirmation dialog (PP-4229)", "Settings → Account → Sign Out shows confirmation"),
    ("B1", "Borrow ePub (Adobe DRM)", "borrow → DRM activation → download"),
    ("B2", "Borrow audiobook (LCP)", "borrow → LCP license → manifest"),
    ("B3", "Borrow PDF", "borrow → download"),
    ("D1", "Download — happy path", "fresh download completes"),
    ("D2", "Download — pause/resume", "interrupt mid-download, resume"),
    ("D3", "Download — network drop (PP-4114)", "network drops mid-download → cancel + reset state"),
    ("D4", "Reset Library Account (PP-4282)", "patron self-service stuck-state recovery"),
    ("R1", "Read EPUB — open + page-forward", "Reader2 launch + nav controls"),
    ("R2", "Read PDF", "Reader3 launch + nav"),
    ("R3", "Audiobook — Play/Pause/Skip ±30", "playback transport (sim audio decoder is silent — drive position state)"),
    ("R4", "Audiobook 401 → SAML reauth (HelpSpot 17727)", "expired token mid-playback re-auths via SAML"),
    ("S1", "Annotation sync round-trip", "highlight → sign-out → sign-in → highlight reappears"),
    ("S2", "Bookmark sync round-trip", "bookmark → sign-out → sign-in → bookmark reappears"),
    ("M1", "iCloud backup migration on upgrade (PP-4179)", "3.0.x → 3.1.0 upgrade walks Application Support + Documents"),
    ("M2", "iCloud backup migration on fresh install", "3.1.0 fresh install applies xattr to created dirs"),
]

P1_AREAS = [
    ("C1", "Catalog browsing", "lanes render, scroll smooth"),
    ("C2", "Catalog — search", "search returns results, no leak"),
    ("C3", "MyBooks tab", "borrowed books listed, state correct"),
    ("C4", "Holds tab", "holds listed if any, ready-to-borrow transition"),
    ("X1", "Library picker", "first-launch + add-library"),
    ("X2", "Library switcher", "top-left Palace icon → multiple libraries"),
    ("X3", "Settings — version, About App, Privacy, User Agreement, Software Licenses", "round-trip"),
    ("X4", "Push registration latch (HelpSpot 17680)", "register only on success"),
    ("X5", "Book detail metadata (PP-4046)", "Audience + Language rows present, empties omitted"),
]


def render_checklist(output_dir: Path, baseline: str, candidate: str) -> str:
    changed_files: list[str] = []
    cf = output_dir / "automated" / "mutation" / "changed-files.txt"
    if cf.exists():
        changed_files = [ln.strip() for ln in cf.read_text().splitlines() if ln.strip()]

    must_test_path = output_dir / "preflight" / "MUST_TEST.md"
    must_test = must_test_path.read_text() if must_test_path.exists() else ""

    creds_path = output_dir / "preflight" / "creds-matrix.md"
    creds_matrix = creds_path.read_text() if creds_path.exists() else ""

    md = []
    md.append(f"# Manual Regression Checklist — {candidate} vs {baseline}\n")
    md.append("**Mark each item as you go.** Each item has a checkbox; capture screenshots as `F-NNN-baseline-*.png` / `F-NNN-candidate-*.png` in the workspace `screenshots/` dir.\n")
    md.append(f"_Generated from {len(changed_files)} changed files between `{baseline}` and `{candidate}`._\n")

    # Section 1: In-field signal MUST_TEST
    md.append("## 1. In-field signal (must-test first)\n")
    md.append("_The agent populates this from Crashlytics + HelpSpot + CM at run time. Walk these BEFORE TEST_MATRIX areas — they're where users are bleeding._\n")
    if "Stub — fill from MCP at run time" in must_test:
        md.append("> ⚠️  In-field signal not yet ingested. Run with the orchestrator that calls `in-field-signal.py` before this checklist is meaningful.\n")
    else:
        md.append("> See `preflight/MUST_TEST.md` for the area list. Mirror each here.\n")
    md.append("\n- [ ] (placeholder — fill after in-field-signal ingestion)\n")

    # Section 2: Auth coverage matrix
    md.append("\n## 2. Auth coverage matrix (5-of-7 minimum per TEST_MATRIX)\n")
    if creds_matrix:
        md.append("_See `preflight/creds-matrix.md` for vault status. Every auth type below must be exercised on baseline AND candidate side-by-side._\n\n")
    auth_items = [
        "- [ ] **basic** — A1QA Test Library: sign-in, browse MyBooks, sign-out",
        "- [ ] **token** — Lyrasis Reads: sign-in, browse MyBooks, sign-out",
        "- [ ] **oauthIntermediary** — NYPL via Clever: sign-in (manual IdP), browse",
        "- [ ] **saml** — Academic library: sign-in (manual IdP + SMS), browse",
        "- [ ] **oidc** — Palace OIDC test library: sign-in (manual IdP), browse",
        "- [ ] **anonymous** — Palace Bookshelf: catalog browse, no sign-in form (SQ-005 regression guard)",
        "- [ ] **coppa** — Open eBooks: age-gate flow, browse",
    ]
    md.extend(auth_items)
    md.append("")

    # Section 3: P0 — areas with changed files
    md.append("\n## 3. P0 critical-path — touched files\n")
    md.append(f"_From the {len(changed_files)} files in changed-files.txt. Heuristic: substring-match against area keywords._\n\n")
    p0_touched: list[tuple] = []
    p0_untouched: list[tuple] = []
    keyword_to_paths: dict[str, list[str]] = {}
    keyword_map = {
        "Auth": ["SignInLogic", "TPPSignInBusinessLogic", "TPPUserAccount", "Account.swift"],
        "Borrow": ["BorrowOperation", "BookFileManager", "TPPBookRegistry"],
        "Download": ["BackgroundDownloadHandler", "DownloadCenter", "DownloadErrorRecovery", "MyBooksDownload"],
        "Reader2": ["Reader2/", "Bookmarks/"],
        "Audiobook": ["Audiobook"],
        "Sync": ["BookmarkSync", "AnnotationSync"],
        "Migration": ["Migrations/", "BackupExclusion"],
        "Catalog": ["Catalog", "OPDS"],
        "Settings": ["Settings/"],
        "BookDetail": ["BookDetail"],
        "Holds": ["Holds/"],
    }
    for area_key, paths in keyword_map.items():
        hits = [p for p in changed_files if any(kw in p for kw in paths)]
        if hits:
            keyword_to_paths[area_key] = hits

    for code, name, hint in P0_AREAS:
        # rough heuristic to match
        touched = False
        if any(kw in name for kw in keyword_to_paths.keys()):
            for kw in keyword_to_paths.keys():
                if kw in name and keyword_to_paths.get(kw):
                    touched = True
                    break
        if touched:
            p0_touched.append((code, name, hint))
        else:
            p0_untouched.append((code, name, hint))

    if p0_touched:
        for code, name, hint in p0_touched:
            md.append(f"- [ ] **{code}** — {name}\n      _{hint}_  🔥 _changed-files-touched_")
    else:
        md.append("_(no P0 areas matched changed-files heuristic — review TEST_MATRIX manually)_")

    # Section 4: P0 untouched (sanity)
    md.append("\n\n## 4. P0 critical-path — sanity (no changes detected, but always test)\n")
    for code, name, hint in p0_untouched:
        md.append(f"- [ ] **{code}** — {name}  _{hint}_")

    # Section 5: P1
    md.append("\n\n## 5. P1 core experience\n")
    for code, name, hint in P1_AREAS:
        md.append(f"- [ ] **{code}** — {name}  _{hint}_")

    md.append("\n\n## 6. Findings log\n")
    md.append("Every checked item that revealed a difference becomes a row in `findings.csv`. Fields:\n\n")
    md.append("- ID: F-NNN (next available)\n- Title: short imperative summary\n- Area: code (e.g. A1, B2)\n- Classification: regression | pre-existing | fixed | behavior-change\n- Severity: blocker | major | minor | cosmetic\n- Verified: false until reproduced\n- Steps: shortest reproduction\n- Screenshots: `F-NNN-baseline-*.png`, `F-NNN-candidate-*.png`\n")

    return "\n".join(md) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--candidate", required=True)
    args = ap.parse_args()

    md = render_checklist(args.output_dir, args.baseline, args.candidate)
    out = args.output_dir / "MANUAL_CHECKLIST.md"
    out.write_text(md)
    print(f"manual-checklist: wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

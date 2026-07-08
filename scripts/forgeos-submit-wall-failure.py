#!/usr/bin/env python3
"""
Submit a .forgeos/wall-failures/<entry>.md file as ForgeOS
architecture_decision evidence so the lesson is discoverable via
forge_list_adrs and forge_query_mind, not just markdown grep.

Usage:
    scripts/forgeos-submit-wall-failure.py .forgeos/wall-failures/2026-05-27-pr1018-arch1.md
    scripts/forgeos-submit-wall-failure.py <path> --changeset cs_xxxxxxxx
    scripts/forgeos-submit-wall-failure.py <path> --area accounts --dry-run

Output (success): the new adr_<8hex> id printed to stdout.
Exit 0 on success, non-zero on validation / HTTP / parse failure.

Maps to evidence schema:
  - summary       <- H1 / title from the markdown body
  - decision      <- ## Proposed permanent fix (compressed to 500 chars)
  - context       <- ## Finding + ## What actually happened
  - consequences  <- ## Walls that should have caught it + ## Application log
  - area          <- --area override, OR derived from frontmatter `walls:`
  - metadata.wall_failure_path <- file path (for traceability)

If --area is omitted, the script picks the best area from the walls[] field:
  contract|implementer|reviewer|orchestrator|hook|verify-pr -> governance
  TDD|mutation                                              -> testing
  stale-doc                                                 -> documentation
This is an approximation; for topic-specific wall-failures, pass --area
explicitly (e.g. --area accounts for an auth-area failure).

Skips files where wall_status=='applied' AND adr_ref is already populated
in frontmatter (idempotent re-runs).

Requires FORGEOS_API_KEY (read from ~/harness/.env if not set in env).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECT_ID = "proj_87884c17"
INITIATIVE_ID = "init_8ddc5d5a"  # Palace iOS modernization initiative
ENGINE_URL_DEFAULT = "https://forgeos-api.synctek.io"
USER_AGENT = "forgeos-submit-wall-failure/1.0"

# Map wall types to ADR area. Override via --area for topic-specific failures.
WALL_TO_AREA = {
    "contract": "governance",
    "implementer": "governance",
    "reviewer": "governance",
    "orchestrator": "governance",
    "hook": "governance",
    "verify-pr": "governance",
    "TDD": "testing",
    "mutation": "testing",
    "stale-doc": "documentation",
}


def _load_api_key() -> str | None:
    k = os.environ.get("FORGEOS_API_KEY", "").strip()
    if k:
        return k
    env_path = os.path.expanduser("~/harness/.env")
    if not os.path.isfile(env_path):
        return None
    try:
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if key.strip() == "FORGEOS_API_KEY":
                    return value.strip().strip('"').strip("'")
    except Exception:
        return None
    return None


def _parse_frontmatter(text: str) -> tuple[dict, str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    fm_block = text[4:end]
    body = text[end + 5:]
    fm: dict = {}
    for line in fm_block.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            if not inner:
                fm[key] = []
            else:
                fm[key] = [v.strip().strip('"').strip("'") for v in inner.split(",")]
        else:
            fm[key] = value.strip('"').strip("'")
    return fm, body


def _extract_section(body: str, heading: str) -> str:
    """Return the prose under `## heading ...` up to the next `## ` or EOF."""
    pattern = re.compile(
        rf"^##\s+{re.escape(heading)}.*?\n(.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(body)
    if not m:
        return ""
    return m.group(1).strip()


def _extract_title(body: str) -> str:
    m = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
    return m.group(1).strip() if m else ""


def _truncate(text: str, max_len: int) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= max_len:
        return text
    cut = text[:max_len - 1]
    last_space = cut.rfind(" ")
    if last_space > max_len * 0.6:
        cut = cut[:last_space]
    return cut.rstrip(",.;:") + "…"


def _derive_area(fm: dict, override: str | None) -> str:
    if override:
        return override
    walls = fm.get("walls") or []
    if isinstance(walls, str):
        walls = [walls]
    if not walls:
        walls = [fm.get("wall", "")]
    for w in walls:
        if w in WALL_TO_AREA:
            return WALL_TO_AREA[w]
    return "governance"


def _create_oneshot_changeset(api_key: str, engine_url: str, source_path: str) -> str:
    """Create a dedicated changeset for this wall-failure submission."""
    url = f"{engine_url.rstrip('/')}/api/projects/{PROJECT_ID}/changesets"
    payload = {
        "initiative_id": INITIATIVE_ID,
        "description": f"Wall-failure backfill: {source_path}",
        "files_changed": [source_path],
        "modules_affected": ["governance"],
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "X-ForgeOS-API-Key": api_key,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    cs = data.get("changeset_id") or data.get("id")
    if not cs:
        raise RuntimeError(f"changeset create returned no id: {data}")
    return cs


def _submit_evidence(api_key: str, engine_url: str, changeset_id: str,
                     summary: str, area: str, decision: str, context: str,
                     consequences: str, wall_failure_path: str) -> str:
    """Submit architecture_decision evidence; returns adr_id."""
    url = f"{engine_url.rstrip('/')}/api/projects/{PROJECT_ID}/changesets/{changeset_id}/evidence"
    payload = {
        "type": "architecture_decision",
        "summary": summary,
        "metadata": {
            "decision": decision,
            "context": context,
            "consequences": consequences,
            "area": area,
            "wall_failure_path": wall_failure_path,
        },
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "X-ForgeOS-API-Key": api_key,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    adr_id = (data.get("metadata") or {}).get("adr_id") or data.get("adr_id")
    if not adr_id:
        raise RuntimeError(f"evidence submit returned no adr_id: {data}")
    return adr_id


def _patch_frontmatter_adr_ref(path: Path, adr_id: str) -> None:
    """Add `adr_ref: <id>` to the wall-failure file's frontmatter."""
    text = path.read_text()
    if not text.startswith("---\n"):
        return
    end = text.find("\n---\n", 4)
    if end < 0:
        return
    fm_block = text[4:end]
    if "adr_ref:" in fm_block:
        # update in place
        new_fm = re.sub(r"^adr_ref:.*$", f"adr_ref: {adr_id}",
                        fm_block, count=1, flags=re.MULTILINE)
    else:
        new_fm = fm_block.rstrip() + f"\nadr_ref: {adr_id}\n"
    new_text = "---\n" + new_fm + "\n---\n" + text[end + 5:]
    path.write_text(new_text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("path", help="path to wall-failure markdown")
    parser.add_argument("--area", help="ADR area override (default: derived from walls[])")
    parser.add_argument("--changeset", help="existing changeset_id to attach to (default: create one-shot)")
    parser.add_argument("--engine-url", default=ENGINE_URL_DEFAULT)
    parser.add_argument("--dry-run", action="store_true", help="print payload, don't submit")
    parser.add_argument("--no-patch", action="store_true", help="skip writing adr_ref back into the wall-failure file")
    args = parser.parse_args()

    wf_path = Path(args.path).resolve()
    if not wf_path.is_file():
        sys.stderr.write(f"not a file: {wf_path}\n")
        return 2

    raw = wf_path.read_text()
    fm, body = _parse_frontmatter(raw)

    # Idempotency: skip if already submitted.
    if fm.get("adr_ref"):
        sys.stderr.write(f"already submitted as {fm['adr_ref']}; skip (use --no-patch to force)\n")
        if not args.dry_run:
            return 0

    title = _extract_title(body) or wf_path.stem
    summary = _truncate(title, 240)
    fix = _extract_section(body, "Proposed permanent fix")
    finding = _extract_section(body, "Finding")
    what_happened = _extract_section(body, "What actually happened")
    walls_section = _extract_section(body, "Walls that should have caught it")
    application = _extract_section(body, "Application log")

    if not fix:
        sys.stderr.write("missing '## Proposed permanent fix' section\n")
        return 2

    decision = _truncate(fix, 500)
    context_parts = [
        f"Finding: {finding}" if finding else "",
        f"What happened: {what_happened}" if what_happened else "",
    ]
    context = "\n\n".join(p for p in context_parts if p)[:6000] or "(no context section)"
    cons_parts = [
        f"Walls: {walls_section}" if walls_section else "",
        f"Application: {application}" if application else "",
    ]
    consequences = "\n\n".join(p for p in cons_parts if p)[:6000] or "(no consequences section)"

    area = _derive_area(fm, args.area)
    rel_path = str(wf_path.relative_to(REPO_ROOT)) if wf_path.is_relative_to(REPO_ROOT) else str(wf_path)

    if args.dry_run:
        print(json.dumps({
            "would_submit": True,
            "changeset_id": args.changeset or "(would create one-shot)",
            "type": "architecture_decision",
            "summary": summary,
            "area": area,
            "wall_failure_path": rel_path,
            "decision_len": len(decision),
            "context_len": len(context),
            "consequences_len": len(consequences),
            "decision_preview": decision[:200],
        }, indent=2))
        return 0

    api_key = _load_api_key()
    if not api_key:
        sys.stderr.write("FORGEOS_API_KEY not found (env or ~/harness/.env)\n")
        return 3

    try:
        changeset_id = args.changeset or _create_oneshot_changeset(
            api_key, args.engine_url, rel_path)
        adr_id = _submit_evidence(
            api_key, args.engine_url, changeset_id, summary, area,
            decision, context, consequences, rel_path)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code}: {e.reason}\n")
        try:
            sys.stderr.write(e.read().decode("utf-8") + "\n")
        except Exception:
            pass
        return 4
    except Exception as e:
        sys.stderr.write(f"submit failed: {e}\n")
        return 5

    if not args.no_patch:
        try:
            _patch_frontmatter_adr_ref(wf_path, adr_id)
        except Exception as e:
            sys.stderr.write(f"warning: failed to patch wall-failure file: {e}\n")

    print(adr_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())

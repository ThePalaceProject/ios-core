#!/usr/bin/env python3
"""Check a PR title and body against the writing conventions in CLAUDE.md.

Reads the pull_request event ($GITHUB_EVENT_PATH or --event), or --title and
--body-file when run locally. Dependabot PRs are exempt.

Exit codes: 0 clean or exempt, 1 findings, 2 input error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

TITLE_MAX = 72
BODY_MAX = 1500
EXEMPT_AUTHORS = {"dependabot[bot]"}

# Internal run / campaign identifiers. Not allowed in titles or bodies.
RUN_IDS = [
    (re.compile(r"\bswarm(?:_\w+)?\b", re.I), "swarm ID"),
    (re.compile(r"\bwave\s*\d+[a-z]?\b", re.I), "wave ID"),
    (re.compile(r"\bphase\s*\d+(?:\.\d+)?\b", re.I), "phase ID"),
    (re.compile(r"\bWS\d+\b"), "workstream ID"),
    (re.compile(r"\brev_[0-9a-f]{6,}\b", re.I), "review ID"),
]

# Harness vocabulary and AI footers. Not allowed in bodies (or titles).
BANNED = [
    (re.compile(r"Generated with \[?Claude Code", re.I), "'Generated with Claude Code' footer"),
    (re.compile(r"Co-Authored-By:\s*Claude", re.I), "Co-Authored-By: Claude trailer"),
    (re.compile(r"\bheka2?\b", re.I), "heka"),
    (re.compile(r"\bforge(?:-review|os)?\b", re.I), "forge / forge-review / ForgeOS"),
    (re.compile(r"\bswarm\b", re.I), "swarm"),
    (re.compile(r"\bwaves?\b", re.I), "wave"),
    (re.compile(r"\bwall[- ]failures?\b", re.I), "wall-failure"),
    (re.compile(r"\bSoD\b"), "SoD"),
    (re.compile(r"\b(?:architect|qa_test|blast[_ -]radius)[- ]reviewers?\b", re.I), "reviewer role"),
    (re.compile(r"\b(?:qa_test|blast_radius)\b", re.I), "reviewer role"),
    (re.compile(r"\brigorous-fix\b", re.I), "rigorous-fix"),
    (re.compile(r"\bintent files?\b", re.I), "intent file"),
    (re.compile(r"\bchangesets?\b", re.I), "changeset"),
    (re.compile(r"\battested-done\b", re.I), "attested-done"),
    (re.compile(r"\bverify-tiers\b", re.I), "verify-tiers"),
    (re.compile(r"\bsimdrive session\b", re.I), "simdrive session"),
]

_HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
_MD_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_HTML_IMG = re.compile(r"<img\b[^>]*>", re.I)
# The Jira GitHub integration edits the body after creation and appends a
# link reference definition per linked key, tagged with atlOrigin=. Those lines
# render as nothing and are not the author's text. Author-written definitions
# (no atlOrigin=) still count.
_JIRA_BOT_LINK_REF = re.compile(r"^[ \t]*\[[^\]]+\]:[ \t]*\S*atlOrigin=\S*[ \t]*$", re.M)


def countable_body(body: str) -> str:
    """The body as a reader sees it: no HTML comments, no images, no
    reference definitions appended by the Jira integration."""
    text = _HTML_COMMENT.sub("", body)
    text = _JIRA_BOT_LINK_REF.sub("", text)
    text = _MD_IMAGE.sub("", text)
    text = _HTML_IMG.sub("", text)
    return "\n".join(line.rstrip() for line in text.strip().splitlines())


def _matches(patterns, text: str) -> list[str]:
    seen: list[str] = []
    for rx, label in patterns:
        m = rx.search(text)
        if m and label not in seen:
            seen.append(f"{label} ({m.group(0)!r})")
    return seen


def check(title: str, body: str) -> list[str]:
    findings: list[str] = []
    title = title.strip()
    if len(title) > TITLE_MAX:
        findings.append(f"title is {len(title)} characters; the limit is {TITLE_MAX}")
    for hit in _matches(RUN_IDS, title):
        findings.append(f"title contains an internal run identifier: {hit}")
    for hit in _matches(BANNED, title):
        findings.append(f"title contains banned text: {hit}")

    visible = countable_body(body or "")
    for hit in _matches(RUN_IDS, visible):
        findings.append(f"body contains an internal run identifier: {hit}")
    for hit in _matches(BANNED, visible):
        findings.append(f"body contains banned text: {hit}")
    if len(visible) > BODY_MAX:
        findings.append(
            f"body is {len(visible)} characters excluding images and comments; "
            f"aim for about 20 lines, limit {BODY_MAX}"
        )
    return findings


def _load(args) -> tuple[str, str, str]:
    if args.title is not None:
        body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else ""
        return args.title, body, args.author or ""
    event_path = args.event or os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        raise ValueError("pass --title/--body-file, --event, or set GITHUB_EVENT_PATH")
    event = json.loads(Path(event_path).read_text(encoding="utf-8"))
    pr = event.get("pull_request")
    if not pr:
        raise ValueError(f"{event_path} is not a pull_request event")
    return pr.get("title") or "", pr.get("body") or "", (pr.get("user") or {}).get("login", "")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--event", help="path to a GitHub pull_request event JSON")
    ap.add_argument("--title")
    ap.add_argument("--body-file")
    ap.add_argument("--author", help="PR author login (local mode)")
    args = ap.parse_args(argv)

    try:
        title, body, author = _load(args)
    except (OSError, ValueError) as e:
        print(f"check-pr-hygiene: {e}", file=sys.stderr)
        return 2

    if author in EXEMPT_AUTHORS:
        print(f"check-pr-hygiene: {author} is exempt")
        return 0

    findings = check(title, body)
    if not findings:
        print("check-pr-hygiene: title and body follow the writing conventions")
        return 0
    print("check-pr-hygiene: the PR title/body does not follow the writing conventions:")
    for f in findings:
        print(f"  - {f}")
    print("See 'Writing conventions' in CLAUDE.md and .github/PULL_REQUEST_TEMPLATE.md.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

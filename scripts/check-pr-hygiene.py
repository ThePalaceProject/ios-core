#!/usr/bin/env python3
"""Check a PR title and body against the writing conventions in CLAUDE.md.

Reads the pull_request event ($GITHUB_EVENT_PATH or --event), or --title and
--body-file when run locally. Dependabot PRs are exempt.

--changed-files (one path per line) and --diff-file (the PR's unified diff) let
the check require the Evidence section when the PR changes Palace/ or
PalaceTests/, and match `// Known:` markers the diff adds against the
"Known behavior kept:" line. Without either, the section is optional.

Exit codes: 0 clean or exempt, 1 findings, 2 input error.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

TITLE_MAX = 72
BODY_MAX = 1500
EVIDENCE_MAX = 600
EVIDENCE_REQUIRED_ROOTS = ("Palace/", "PalaceTests/")
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


_EVIDENCE_HEADING = re.compile(r"^##[ \t]+Evidence[ \t]*$", re.I | re.M)
_NEXT_HEADING = re.compile(r"^#{1,6}[ \t]", re.M)
EVIDENCE_KEYS = ("Red first", "Mutation", "Simulator", "Reviews", "Known behavior kept")
_KEY_LINE = re.compile(
    r"^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?(" + "|".join(EVIDENCE_KEYS) + r"):(?:\*\*)?[ \t]*(.*)$",
    re.I | re.M,
)
# "not run: <reason>", "not applicable: <reason>" or "none; <reason>".
_SKIP = re.compile(r"^(not run:|not applicable:|none;)\s*(.*)$", re.I)
# "killed N, survived N, errored N", or per-file "N/N/N" with that order stated.
_MUTATION = re.compile(
    r"\bkilled \d+, survived \d+, errored \d+\b"
    r"|\b\d+/\d+/\d+\b.*\(killed/survived/errored\)", re.I)
# A count and the short SHA the reviews approved.
_REVIEWS = re.compile(r"^\d+\b.*\b[0-9a-f]{7,40}\b", re.I)
_BARE_SKIPS = {"none", "n/a", "na", "not run", "not applicable", "-"}
_PP_KEY = re.compile(r"\bPP-\d+\b")


def split_evidence(body: str) -> tuple[str, str | None]:
    """(body without the Evidence section, the section's text or None)."""
    m = _EVIDENCE_HEADING.search(body)
    if not m:
        return body, None
    nxt = _NEXT_HEADING.search(body, m.end())
    end = nxt.start() if nxt else len(body)
    return body[:m.start()] + body[end:], body[m.end():end]


def _load_marker_parser():
    path = Path(__file__).resolve().with_name("list-known-behaviors.py")
    spec = importlib.util.spec_from_file_location("list_known_behaviors", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.markers_in_diff


def files_in_diff(diff_text: str) -> list[str]:
    return re.findall(r"^\+\+\+ b/(.+)$", diff_text, re.M)


def evidence_required(changed_files: list[str] | None) -> bool:
    return bool(changed_files) and any(f.startswith(EVIDENCE_REQUIRED_ROOTS) for f in changed_files)


def check_evidence(section: str | None, required: bool, marker_keys: list[str]) -> list[str]:
    """Findings for the Evidence section. Every key is required, and must be
    non-empty, when the PR changes product or test code."""
    if section is None:
        if required:
            return ["body has no '## Evidence' section; it is required when the PR changes "
                    "Palace/ or PalaceTests/ (see .github/PULL_REQUEST_TEMPLATE.md)"]
        if marker_keys:
            return [f"the diff adds Known markers for {', '.join(marker_keys)}; add an "
                    "'## Evidence' section with a 'Known behavior kept:' line naming them"]
        return []
    findings: list[str] = []
    visible = countable_body(section)
    if len(visible) > EVIDENCE_MAX:
        findings.append(f"Evidence section is {len(visible)} characters; limit {EVIDENCE_MAX}, "
                        "one line per key")
    values: dict[str, str] = {}
    for m in _KEY_LINE.finditer(visible):
        key = next(k for k in EVIDENCE_KEYS if k.lower() == m.group(1).lower())
        values.setdefault(key, m.group(2).strip())
    for key in EVIDENCE_KEYS:
        value = values.get(key)
        if value is None:
            if required:
                findings.append(f"Evidence is missing the '{key}:' line")
            continue
        if not value:
            if required:
                findings.append(f"Evidence '{key}:' is empty")
            continue
        skip = _SKIP.match(value)
        bare = value.lower().strip(" .;:") in _BARE_SKIPS
        if (skip or bare) and key not in ("Reviews", "Known behavior kept"):
            if bare or not skip.group(2).strip(" .;"):
                findings.append(f"Evidence '{key}: {value}' needs a reason after it, "
                                "e.g. 'not run: <reason>'")
            continue
        if key == "Mutation" and not _MUTATION.search(value):
            findings.append("Evidence 'Mutation:' should read 'killed N, survived N, errored N "
                            "on changed lines' (or per file 'N/N/N (killed/survived/errored)') "
                            "or 'not run: <reason>'")
        elif key == "Reviews" and not value.lower().startswith("none") and not _REVIEWS.match(value):
            findings.append("Evidence 'Reviews:' should read 'N independent reviews, approved at "
                            "<short sha>' or 'none'")
        elif key == "Known behavior kept" and value.lower().strip(" .") != "none" and not _PP_KEY.search(value):
            findings.append("Evidence 'Known behavior kept:' should list PP keys or read 'none'")
    listed = set(_PP_KEY.findall(values.get("Known behavior kept") or ""))
    unlisted = [k for k in marker_keys if k not in listed]
    if unlisted:
        findings.append(f"the diff adds Known markers for {', '.join(unlisted)}; list them on "
                        "the 'Known behavior kept:' line")
    return findings


def _matches(patterns, text: str) -> list[str]:
    seen: list[str] = []
    for rx, label in patterns:
        m = rx.search(text)
        if m and label not in seen:
            seen.append(f"{label} ({m.group(0)!r})")
    return seen


def check(title: str, body: str, changed_files: list[str] | None = None,
          diff_text: str | None = None) -> list[str]:
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
    rest, section = split_evidence(body or "")
    rest_visible = countable_body(rest)
    if len(rest_visible) > BODY_MAX:
        findings.append(
            f"body is {len(rest_visible)} characters excluding images and comments (the "
            f"Evidence section is counted separately); aim for about 20 lines, limit {BODY_MAX}"
        )
    if changed_files is None and diff_text is not None:
        changed_files = files_in_diff(diff_text)
    marker_keys: list[str] = []
    if diff_text:
        for _, _, keys, _ in _load_marker_parser()(diff_text):
            marker_keys += [k for k in keys if k not in marker_keys]
    findings += check_evidence(section, evidence_required(changed_files), marker_keys)
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
    ap.add_argument("--changed-files", help="file listing the PR's changed paths, one per line")
    ap.add_argument("--diff-file", help="the PR's unified diff")
    args = ap.parse_args(argv)

    try:
        title, body, author = _load(args)
        changed = None
        if args.changed_files:
            changed = [ln.strip() for ln in
                       Path(args.changed_files).read_text(encoding="utf-8").splitlines()
                       if ln.strip()]
        diff_text = (Path(args.diff_file).read_text(encoding="utf-8", errors="replace")
                     if args.diff_file else None)
    except (OSError, ValueError) as e:
        print(f"check-pr-hygiene: {e}", file=sys.stderr)
        return 2

    if author in EXEMPT_AUTHORS:
        print(f"check-pr-hygiene: {author} is exempt")
        return 0

    findings = check(title, body, changed, diff_text)
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

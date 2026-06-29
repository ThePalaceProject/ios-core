#!/usr/bin/env python3
"""
check-intent-recorded.py — require an intent file for non-trivial prod diffs.

If a diff adds at least `--threshold-loc` (default 10) lines under
`Palace/`, then a corresponding intent file must exist under
`--intent-dir` (default `.forgeos/intent/`). The intent file:

  - Has frontmatter with `name`, `created`, `author` keys.
  - Contains body sections `## Claims`, `## Anti-claims`, `## Files in scope`.
  - Has `name:` that token-matches the commit subject (≥4 consecutive
    case-insensitive token overlap).

Excluded from the prod-LOC count:
  - PalaceTests/* (test code)
  - scripts/* (tooling)
  - .forgeos/* (governance artifacts)
  - .claude/* (skill / agent / hook config)
  - *.md files (docs)
  - Comment-only added lines and blank lines.

Exit codes:
  0 — no intent required, OR intent present and valid.
  1 — intent required but missing or malformed.
  2 — argument / I/O error.

Flags:
  --diff <file>            Unified-diff input. Defaults to stdin.
  --commit-msg <file>      Commit-message subject source.
  --threshold-loc N        Prod-LOC threshold (default 10).
  --intent-dir <path>      Intent file directory (default .forgeos/intent/).
  --quiet                  Suppress summary on stderr.
  --dry-run                Print state; never exit non-zero.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import read_diff

# --- Required intent shape -------------------------------------------------

_REQUIRED_FRONTMATTER_KEYS = ("name", "created", "author")
_REQUIRED_BODY_SECTIONS = ("## Claims", "## Anti-claims", "## Files in scope")
# Extra sections required when an intent declares `type: bugfix` — the enforced
# spine of the bug-investigation process (reproduce → root-cause → verify).
_REQUIRED_BUGFIX_SECTIONS = ("## Reproduction", "## Root cause", "## Verification")

# Files / paths to count as "prod" LOC.
_PROD_PATH_PREFIXES = ("Palace/",)
_EXCLUDED_PATH_PREFIXES = (
    "PalaceTests/",
    "scripts/",
    ".forgeos/",
    ".claude/",
    "docs/",
)
_EXCLUDED_SUFFIXES = (".md", ".markdown", ".yml", ".yaml", ".json", ".plist")

# Token-match threshold for matching intent file to commit subject.
_TOKEN_MATCH_MIN_CONSECUTIVE = 4

_FILE_HDR_RE = re.compile(r"^\+\+\+ b/(.+)$")
_SWIFT_COMMENT_RE = re.compile(r"^\s*(?://|///|/\*|\*\s|\*/)")
_FRONTMATTER_RE = re.compile(r"^([a-zA-Z_]+):\s*(.+)$")
_WORDLIKE_RE = re.compile(r"[a-zA-Z0-9]+")


# --- Diff parsing ----------------------------------------------------------

@dataclass
class _DiffStats:
    prod_loc_added: int
    files_touched: list[str]


def _is_prod_path(path: str) -> bool:
    if not any(path.startswith(p) for p in _PROD_PATH_PREFIXES):
        return False
    if any(path.startswith(p) for p in _EXCLUDED_PATH_PREFIXES):
        return False
    if any(path.endswith(s) for s in _EXCLUDED_SUFFIXES):
        return False
    return True


def _parse_diff(diff_text: str) -> _DiffStats:
    prod_added = 0
    files: list[str] = []
    current_path: str | None = None
    for raw in diff_text.splitlines():
        m = _FILE_HDR_RE.match(raw)
        if m:
            current_path = m.group(1)
            files.append(current_path)
            continue
        if current_path is None:
            continue
        if raw.startswith("---") or raw.startswith("+++"):
            continue
        if not raw.startswith("+"):
            continue
        text = raw[1:]
        if not _is_prod_path(current_path):
            continue
        stripped = text.strip()
        if not stripped:
            continue
        if _SWIFT_COMMENT_RE.match(text):
            continue
        prod_added += 1
    return _DiffStats(prod_loc_added=prod_added, files_touched=files)


# --- Intent file validation ------------------------------------------------

@dataclass
class _IntentValidation:
    path: Path | None
    ok: bool
    reason: str          # empty when ok=True


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def _parse_commit_subject(commit_msg_text: str) -> str:
    """First non-empty line of commit body."""
    for line in commit_msg_text.splitlines():
        if line.strip():
            return line.strip()
    return ""


# PP-4161 follow-up: strip noise prefixes like `[swarm_xxx]` or `[wave 4]`
# before tokenizing the commit subject. Without this, the 4-consecutive
# match window gets shifted by the prefix tokens and even subjects that
# clearly correspond to an intent file fail to match.
_NOISE_PREFIX_RE = re.compile(r"^\s*\[[^\]]+\]\s*")

# Ticket-key form — matches "PP-4161", "PP 4161", "JIRA-123", etc.
# Used to give ticket-keyed subjects a shorter path to matching the intent
# file's ticket-key, even when their content tokens differ.
_TICKET_KEY_RE = re.compile(
    r"\b([a-z]{2,6})[\s\-]?(\d{2,6})\b",
    re.IGNORECASE,
)


def _strip_noise_prefixes(text: str) -> str:
    """Iteratively strip `[bracketed]` noise prefixes from the front of a subject.

    Example: `[swarm_c2b95c85] [wave 4] PP-4161 ...` → `PP-4161 ...`.
    Keeps stripping until the first non-prefix token is reached.
    """
    while True:
        new = _NOISE_PREFIX_RE.sub("", text)
        if new == text:
            return text
        text = new


def _extract_ticket_keys(text: str) -> set[str]:
    """Return the set of normalized ticket-keys (e.g. {'pp-4161'}) in `text`."""
    keys: set[str] = set()
    for m in _TICKET_KEY_RE.finditer(text):
        prefix = m.group(1).lower()
        number = m.group(2)
        keys.add(f"{prefix}-{number}")
    return keys


def _tokenize(text: str) -> list[str]:
    return [t.lower() for t in _WORDLIKE_RE.findall(text)]


def _has_consecutive_token_match(subject: str, name: str, min_run: int) -> bool:
    """True if `name` shares ≥`min_run` consecutive tokens with `subject`.

    Multi-strategy matching, in order of preference:

    1. **Ticket-key + 2-consecutive content-token overlap.** When the subject
       and the intent name share a ticket-key (e.g. both contain `PP-4161`
       after normalization across `PP-4161` / `PP 4161` / `PP4161` forms),
       accept on ≥2 consecutive content-token overlap. This is the common
       case for ticket-driven work; the original 4-consecutive bar broke
       on swarm-prefixed subjects (`[swarm_xxx] PP-4161 Module A: ...`).
    2. **Original 4-consecutive shared-token match** (after noise-prefix
       stripping) — preserves prior behavior for non-ticket-keyed names.
    3. **Loose single-name match** for very short token sets — preserved
       from the prior implementation as a fallback.

    The noise-prefix strip removes `[bracketed]` prefixes from the subject
    before tokenization so swarm-id / wave-id prefixes don't shift the
    match window past the meaningful content tokens.
    """
    subject_stripped = _strip_noise_prefixes(subject)

    # Strategy 1: ticket-key + 2-consecutive content overlap.
    subj_keys = _extract_ticket_keys(subject_stripped)
    name_keys = _extract_ticket_keys(name)
    shared_keys = subj_keys & name_keys
    if shared_keys:
        # Re-tokenize with the ticket-key tokens collapsed to a single sentinel
        # so the consecutive-content-token check focuses on the non-key tokens.
        subj_content = _tokens_without_keys(subject_stripped, shared_keys)
        name_content = _tokens_without_keys(name, shared_keys)
        # 2-consecutive is the lower bar for ticket-keyed names; it still
        # rejects unrelated commits (subject "PP-4161 typo fix" vs intent
        # "pp-4161-streaming-html-reader" would share `pp-4161` but have
        # disjoint content tokens `[typo, fix]` vs `[streaming, html, reader]`).
        for i in range(len(subj_content) - 1):
            window = subj_content[i:i + 2]
            for j in range(len(name_content) - 1):
                if name_content[j:j + 2] == window:
                    return True
        # Fall through to strategy 2 — the ticket-key alone isn't enough
        # without some content overlap.

    # Strategy 2 (original): 4-consecutive shared-token match.
    subj_tokens = _tokenize(subject_stripped)
    name_tokens = _tokenize(name)
    if len(subj_tokens) < min_run or len(name_tokens) < min_run:
        # Strategy 3: loose single-name fallback for very short token sets.
        return any(n in subj_tokens for n in name_tokens) and len(
            set(name_tokens) & set(subj_tokens)) >= max(1, len(name_tokens) - 1)
    for i in range(len(subj_tokens) - min_run + 1):
        window = subj_tokens[i:i + min_run]
        for j in range(len(name_tokens) - min_run + 1):
            if name_tokens[j:j + min_run] == window:
                return True
    return False


def _tokens_without_keys(text: str, keys: set[str]) -> list[str]:
    """Tokenize `text` while dropping tokens that are part of a ticket-key.

    Helper for the ticket-key match strategy: lets us check content-token
    overlap after the shared ticket-key is excluded so the key itself
    doesn't double-count as a "consecutive match."
    """
    key_token_parts: set[str] = set()
    for key in keys:
        # Each key is `<prefix>-<number>`; strip dash, lowercase, split.
        # Both tokens get dropped from the consecutive-content window.
        prefix, number = key.split("-", 1)
        key_token_parts.add(prefix.lower())
        key_token_parts.add(number)
    return [t for t in _tokenize(text) if t not in key_token_parts]


def _parse_intent(path: Path) -> _IntentValidation:
    text = _read_text(path)
    if text is None:
        return _IntentValidation(path=path, ok=False,
                                 reason=f"cannot read {path}")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return _IntentValidation(path=path, ok=False,
                                 reason="missing leading `---` frontmatter")
    frontmatter: dict[str, str] = {}
    body_start = -1
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            body_start = idx + 1
            break
        m = _FRONTMATTER_RE.match(lines[idx])
        if m:
            frontmatter[m.group(1)] = m.group(2).strip()
    if body_start < 0:
        return _IntentValidation(path=path, ok=False,
                                 reason="missing trailing `---` frontmatter")
    for key in _REQUIRED_FRONTMATTER_KEYS:
        if key not in frontmatter or not frontmatter[key]:
            return _IntentValidation(path=path, ok=False,
                                     reason=f"missing frontmatter key `{key}`")
    body_text = "\n".join(lines[body_start:])
    required_sections = list(_REQUIRED_BODY_SECTIONS)
    # Bug-fix intents must additionally carry the investigation evidence:
    # a reproduction against the REAL failing artifact, the verified root
    # cause, and an in-action verification of the fix. This is the enforced
    # half of the bug-investigation process (docs/bug-investigation-process.md).
    # It exists because a fix once shipped on an unverified root-cause
    # hypothesis whose unit tests only encoded the assumption — wall-failure
    # 2026-06-25-epub-webview-premature-collapse. Opt-in via `type: bugfix`;
    # the process doc + reviewers are responsible for setting it on bug fixes.
    if frontmatter.get("type", "").strip().lower() == "bugfix":
        required_sections += _REQUIRED_BUGFIX_SECTIONS
    for section in required_sections:
        if section not in body_text:
            return _IntentValidation(path=path, ok=False,
                                     reason=f"missing body section `{section}`")
    return _IntentValidation(path=path, ok=True, reason="")


def _find_matching_intent(intent_dir: Path, commit_subject: str
                          ) -> tuple[Path | None, list[Path]]:
    """Return (matching_path, all_candidate_paths)."""
    if not intent_dir.is_dir():
        return (None, [])
    candidates = sorted(intent_dir.glob("*.md"))
    best: Path | None = None
    for c in candidates:
        text = _read_text(c)
        if text is None:
            continue
        name_match = re.search(r"^name:\s*(.+)$", text, flags=re.MULTILINE)
        if not name_match:
            continue
        name_value = name_match.group(1).strip()
        if _has_consecutive_token_match(
                commit_subject, name_value, _TOKEN_MATCH_MIN_CONSECUTIVE):
            best = c
            break
    return (best, candidates)


# --- CLI -------------------------------------------------------------------

_read_diff = read_diff  # shared with scripts/_checklib.py


def _read_commit_msg(path: str | None) -> str:
    if path is None:
        return ""
    p = Path(path)
    if not p.is_file():
        print(f"ERROR: commit-msg file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return p.read_text(encoding="utf-8", errors="replace")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-intent-recorded.py",
        description=(
            "Require a .forgeos/intent/<name>.md file when a diff adds "
            "≥ --threshold-loc lines to Palace/ production code. Intent "
            "file must have frontmatter (name/created/author) + body "
            "sections (Claims / Anti-claims / Files in scope), and its "
            "`name:` must match the commit subject."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file.")
    parser.add_argument("--commit-msg", default=None,
                        help="Commit-message file (subject line is first non-empty).")
    parser.add_argument("--threshold-loc", type=int, default=10,
                        help="Prod-LOC threshold (default 10).")
    parser.add_argument("--intent-dir", default=".forgeos/intent",
                        help="Intent file directory (default .forgeos/intent).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress summary line.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print state; never exit non-zero.")
    args = parser.parse_args(argv)

    diff_text = _read_diff(args.diff)
    commit_text = _read_commit_msg(args.commit_msg)
    stats = _parse_diff(diff_text)

    if stats.prod_loc_added < args.threshold_loc:
        if not args.quiet:
            print(f"OK: {stats.prod_loc_added} prod LOC < threshold "
                  f"{args.threshold_loc}; no intent required.",
                  file=sys.stderr)
        return 0

    subject = _parse_commit_subject(commit_text)
    if not subject:
        if args.dry_run:
            if not args.quiet:
                print(f"DRY-RUN: {stats.prod_loc_added} prod LOC ≥ threshold; "
                      f"no commit subject to match.", file=sys.stderr)
            return 0
        print("INTENT-MISSING: ≥ threshold prod LOC but no commit subject "
              "to match an intent file against.")
        return 1

    intent_dir = Path(args.intent_dir)
    match, candidates = _find_matching_intent(intent_dir, subject)
    if match is None:
        if args.dry_run:
            if not args.quiet:
                print(f"DRY-RUN: would require intent under {intent_dir} "
                      f"matching subject: {subject!r}", file=sys.stderr)
            return 0
        cand_names = ", ".join(c.name for c in candidates) or "(none)"
        print(f"INTENT-MISSING: prod LOC added={stats.prod_loc_added} "
              f"≥ threshold={args.threshold_loc}; no intent file in "
              f"{intent_dir} matched subject: {subject!r}. "
              f"Candidates checked: {cand_names}")
        return 1

    validation = _parse_intent(match)
    if not validation.ok:
        if args.dry_run:
            return 0
        print(f"INTENT-INVALID: {validation.path}: {validation.reason}")
        return 1

    if not args.quiet:
        print(f"OK: intent file {match} matches subject and has all "
              f"required sections (prod LOC added={stats.prod_loc_added}).",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

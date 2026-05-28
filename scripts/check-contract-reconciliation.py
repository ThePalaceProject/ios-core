#!/usr/bin/env python3
# ruff: noqa: W605
r"""
check-contract-reconciliation.py — reconcile claims against staged diff.

Parses commit body / PR body / intent file / swarm contract for claim
phrases — "removes X", "renames X to Y", "extracts X into P",
"migrates Y to Z", "adds field A to type B", "fixes N findings" —
then greps the staged diff for evidence each claim is reflected.

The canonical bad shape this catches: the wave 4 scaffold body claimed
"remove HostingController" but the cleanup diff only renamed the class
(left 4 stale comment refs as a separate bug). The cleanup commit body
honestly listed 6 fixes, and 6 corresponding edits land in the diff.

Claim grammars (case-insensitive):
  REM:      r"removes?\s+`?([A-Z]\w+)`?"
  REN:      r"renames?\s+`?([A-Z]\w+)`?\s+to\s+`?([A-Z]\w+)`?"
  EXT:      r"extracts?\s+`?([A-Z]\w+)`?\s+into\s+`?([A-Z]\w+)`?"
  MIG:      r"migrates?\s+`?([A-Z]\w+)`?\s+to\s+`?([A-Z]\w+)`?"
  ADDFLD:   r"adds?\s+field\s+`?(\w+)`?\s+to\s+(?:type\s+)?`?([\w\.]+)`?"
  FIX_N:   r"fixes?\s+(\d+)\s+(?:manual-review\s+)?finding"

Evidence rules:
  REM        — must see a `-` line removing `class|struct|...|protocol\s+X`
               OR a `deleted file mode` header for a file named `X.swift`.
  REN        — must see BOTH a `-` line with `\bX\b` AND a `+` line with
               `\bY\b`.
  EXT        — must see a new-file `+++ b/.../P.swift` header AND a `-X`
               removal of the original `class|struct|...|protocol\s+X`.
  MIG        — must see a `-Y` and `+Z` token-level swap somewhere; lenient
               (counts as satisfied if both names appear in the diff).
  ADDFLD     — must see a `+` line declaring a member named A inside the
               surviving body of `B` (heuristic: A appears as the LHS of
               `:` or `=` on an added line within a file containing B's
               declaration).
  FIX_N     — must see ≥ N edits in the diff (added/removed-line pair
               counts across all files, sans pure whitespace/comments).

Exit codes:
  0 — all claims reconcile.
  1 — at least one claim unsupported.
  2 — argument / I/O error.

Flags:
  --commit-msg <file>      Commit-message source.
  --pr-body <file>         PR body markdown.
  --intent <file>          Intent markdown.
  --swarm-contract <file>  Swarm-module contract markdown.
  --diff <file>            Unified-diff input.
  --quiet                  Suppress summary.
  --dry-run                Print findings; never exit non-zero.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --- Claim grammars --------------------------------------------------------

_REM_RE = re.compile(r"\bremoves?\s+`?([A-Z][\w\.]+)`?",
                     flags=re.IGNORECASE)
_REN_RE = re.compile(
    r"\brenames?\s+`?([A-Z]\w+)`?\s+(?:to|→)\s+`?([A-Z]\w+)`?",
    flags=re.IGNORECASE)
_EXT_RE = re.compile(
    r"\bextracts?\s+`?([A-Z]\w+)`?\s+into\s+`?([A-Z][\w\.]+)`?",
    flags=re.IGNORECASE)
_MIG_RE = re.compile(
    r"\bmigrates?\s+`?([A-Z]\w+)`?\s+to\s+`?([A-Z][\w\.]+)`?",
    flags=re.IGNORECASE)
_ADDFLD_RE = re.compile(
    r"\badds?\s+field\s+`?(\w+)`?\s+to\s+(?:type\s+)?`?([\w\.]+)`?",
    flags=re.IGNORECASE)
_FIX_N_RE = re.compile(
    r"\bfixes?\s+(\d+)\s+(?:manual[-\s]review\s+)?finding",
    flags=re.IGNORECASE)


@dataclass
class _Claim:
    kind: str       # REM | REN | EXT | MIG | ADDFLD | FIX_N
    args: tuple
    source: str     # which input file the claim came from


def _strip_non_claim_regions(text: str) -> str:
    """Strip regions where claim-shaped text is NOT a fresh claim:

    1. Fenced code blocks (```...```).
    2. Blockquoted lines (prefix `> `).
    3. Backtick-wrapped inline code (`code`) — preserves the line, drops the
       quoted span so PascalCase names inside ``` don't trigger claim regexes.
    4. Wall-failure / catalog reference lines — any line containing
       `/wall-failures/` or a date-prefixed backfill / wall-failure filename
       (matches `YYYY-MM-DD-` followed by any short-id).
    5. Double-quoted spans (`"..."` and `'...'`) — when authors quote
       prior-language verbatim (e.g. "removes X"), they're not claiming X
       removal as the current diff's action.

    Architect rev_f1c4ea3c (M1 review): false positive on M1's own commit
    body where `"removes SignInModalHostingController"` (a literal quote
    of prior wave 4 claim-drift language) was parsed as a fresh claim.
    Architect rev_4d2eb9dc (re-review): the original fix missed the most
    common quoted-prose case — plain double-quoted strings in markdown
    prose. This generalization covers (5).
    """
    out_lines: list[str] = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.lstrip()
        # Fence boundary
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # Blockquote
        if stripped.startswith("> "):
            continue
        # Wall-failure reference line (date-generalized — works for any month
        # not just 2026-05-28).
        if "/wall-failures/" in line or _WALL_FAILURE_FILENAME.search(line):
            continue
        # Strip backtick-wrapped inline code from the line (preserve the rest
        # so legitimate claim language survives).
        line = _BACKTICK_INLINE.sub("``", line)
        # Strip double-quoted and single-quoted spans (preserves surrounding
        # prose). Quoted strings are typically prior-language references, not
        # the current author's claim.
        line = _DOUBLE_QUOTED.sub('""', line)
        line = _SINGLE_QUOTED.sub("''", line)
        out_lines.append(line)
    return "\n".join(out_lines)


_BACKTICK_INLINE = re.compile(r"`[^`\n]+`")
_DOUBLE_QUOTED = re.compile(r'"[^"\n]+"')
_SINGLE_QUOTED = re.compile(r"'[^'\n]+'")
_WALL_FAILURE_FILENAME = re.compile(r"\b\d{4}-\d{2}-\d{2}-(backfill-)?(pr|cs)[a-z0-9_-]+\b")


def _parse_claims_from_text(text: str, source: str) -> list[_Claim]:
    """Extract structured claims from a free-form text block.

    Pre-filters via _strip_non_claim_regions to skip code blocks, blockquotes,
    wall-failure reference lines, and inline-code-wrapped tokens — none of
    those are fresh claims for the CURRENT commit (architect rev_f1c4ea3c).
    """
    text = _strip_non_claim_regions(text)
    claims: list[_Claim] = []
    for m in _REN_RE.finditer(text):
        claims.append(_Claim(kind="REN", args=(m.group(1), m.group(2)),
                             source=source))
    for m in _EXT_RE.finditer(text):
        claims.append(_Claim(kind="EXT", args=(m.group(1), m.group(2)),
                             source=source))
    for m in _MIG_RE.finditer(text):
        claims.append(_Claim(kind="MIG", args=(m.group(1), m.group(2)),
                             source=source))
    for m in _ADDFLD_RE.finditer(text):
        claims.append(_Claim(kind="ADDFLD", args=(m.group(1), m.group(2)),
                             source=source))
    for m in _FIX_N_RE.finditer(text):
        try:
            claims.append(_Claim(kind="FIX_N", args=(int(m.group(1)),),
                                 source=source))
        except ValueError:
            pass
    # Remove: must NOT be a rename — same line may match `renames X to Y`
    # which then ALSO matches `removes X`. Filter REM matches that overlap
    # rename matches.
    renamed_first_args = {c.args[0] for c in claims if c.kind == "REN"}
    extracted_first_args = {c.args[0] for c in claims if c.kind == "EXT"}
    migrated_first_args = {c.args[0] for c in claims if c.kind == "MIG"}
    rem_seen: set[str] = set()
    for m in _REM_RE.finditer(text):
        name = m.group(1)
        if name in renamed_first_args:
            continue
        if name in extracted_first_args:
            continue
        if name in migrated_first_args:
            continue
        if name in rem_seen:
            continue
        rem_seen.add(name)
        claims.append(_Claim(kind="REM", args=(name,), source=source))
    return claims


# --- Diff parsing ----------------------------------------------------------

@dataclass
class _DiffIndex:
    added_lines: list[tuple[str, str]] = field(default_factory=list)
    removed_lines: list[tuple[str, str]] = field(default_factory=list)
    new_files: set[str] = field(default_factory=set)
    deleted_files: set[str] = field(default_factory=set)
    all_files: set[str] = field(default_factory=set)
    raw_text: str = ""


_FILE_DIFF_RE = re.compile(r"^diff --git a/(.+) b/(.+)$")
_NEW_FILE_RE = re.compile(r"^new file mode \d+$")
_DEL_FILE_RE = re.compile(r"^deleted file mode \d+$")
_HUNK_RE = re.compile(r"^@@")


def _parse_diff(diff_text: str) -> _DiffIndex:
    idx = _DiffIndex(raw_text=diff_text)
    cur_path: str | None = None
    cur_new = False
    cur_del = False
    for raw in diff_text.splitlines():
        m_file = _FILE_DIFF_RE.match(raw)
        if m_file:
            cur_path = m_file.group(2)
            idx.all_files.add(cur_path)
            cur_new = False
            cur_del = False
            continue
        if _NEW_FILE_RE.match(raw):
            cur_new = True
            if cur_path:
                idx.new_files.add(cur_path)
            continue
        if _DEL_FILE_RE.match(raw):
            cur_del = True
            if cur_path:
                idx.deleted_files.add(cur_path)
            continue
        if _HUNK_RE.match(raw):
            continue
        if raw.startswith("---") or raw.startswith("+++"):
            continue
        if cur_path is None:
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            idx.added_lines.append((cur_path, raw[1:]))
        elif raw.startswith("-") and not raw.startswith("---"):
            idx.removed_lines.append((cur_path, raw[1:]))
    return idx


# --- Reconciliation --------------------------------------------------------

_DECL_KINDS_RE = r"(?:class|struct|enum|protocol|func|typealias|actor|extension)"


def _file_basename_matches(files: set[str], name: str) -> bool:
    """True if any file path's basename (sans extension) equals `name`."""
    for p in files:
        base = p.rsplit("/", 1)[-1]
        stem = base.rsplit(".", 1)[0]
        if stem == name:
            return True
    return False


def _line_matches_decl_removal(line: str, name: str) -> bool:
    pattern = re.compile(
        rf"\b{_DECL_KINDS_RE}\s+{re.escape(name)}\b")
    return bool(pattern.search(line))


def _reconcile_rem(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    name = claim.args[0]
    if _file_basename_matches(idx.deleted_files, name):
        return (True, f"deleted file {name}.* found")
    for path, line in idx.removed_lines:
        if _line_matches_decl_removal(line, name):
            return (True, f"removed declaration in {path}")
    return (False, f"no `-class|struct|...|protocol {name}` line and "
                   f"no `{name}.*` file deletion found in diff")


def _reconcile_ren(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    old, new = claim.args
    saw_old_removed = any(
        re.search(rf"\b{re.escape(old)}\b", line)
        for _, line in idx.removed_lines
    )
    saw_new_added = any(
        re.search(rf"\b{re.escape(new)}\b", line)
        for _, line in idx.added_lines
    )
    if saw_old_removed and saw_new_added:
        return (True, f"`{old}` removed AND `{new}` added")
    if not saw_old_removed:
        return (False, f"no `-` line referencing `{old}` in diff")
    return (False, f"no `+` line referencing `{new}` in diff")


def _reconcile_ext(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    old, new_pkg = claim.args
    saw_old_removed = any(
        _line_matches_decl_removal(line, old)
        for _, line in idx.removed_lines
    )
    saw_new_pkg = (
        _file_basename_matches(idx.new_files, new_pkg)
        or _file_basename_matches(idx.all_files, new_pkg)
        or any(re.search(rf"\b{re.escape(new_pkg)}\b", line)
               for _, line in idx.added_lines)
    )
    if saw_old_removed and saw_new_pkg:
        return (True, f"`{old}` declaration removed AND target `{new_pkg}` "
                      f"referenced in diff")
    if not saw_old_removed:
        return (False, f"no removal of declaration `{old}` found")
    return (False, f"no new-file or +-line referencing target `{new_pkg}`")


def _reconcile_mig(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    src, dst = claim.args
    saw_src = any(
        re.search(rf"\b{re.escape(src)}\b", line)
        for _, line in idx.removed_lines + idx.added_lines
    )
    saw_dst = any(
        re.search(rf"\b{re.escape(dst)}\b", line)
        for _, line in idx.added_lines
    )
    if saw_src and saw_dst:
        return (True, f"both `{src}` and `{dst}` appear in diff")
    if not saw_src:
        return (False, f"no diff reference to migration source `{src}`")
    return (False, f"no `+` line referencing migration target `{dst}`")


def _reconcile_addfld(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    field_name, type_name = claim.args
    # Look for added lines that declare a member named `field_name`
    # AND share a file whose path or added body references `type_name`.
    candidate_files: set[str] = set()
    for path, line in idx.added_lines:
        if re.search(rf"\b{re.escape(type_name)}\b", line):
            candidate_files.add(path)
    # Also allow the file path itself to contain the type name.
    for path in idx.all_files:
        if re.search(rf"/{re.escape(type_name)}\.", path):
            candidate_files.add(path)
    member_decl = re.compile(
        rf"^\s*(?:public|internal|fileprivate|private|case|@\w+\s+)*"
        rf"(?:var\s+|let\s+|case\s+)?{re.escape(field_name)}\b"
        rf"(?:\s*:|\s*=|\s*\(|\s*$)"
    )
    for path, line in idx.added_lines:
        if path not in candidate_files:
            continue
        if member_decl.match(line):
            return (True, f"added `{field_name}` declaration in {path}")
    # Looser: any added line declares `case|let|var <field>` AND the diff
    # somewhere references type_name.
    if candidate_files:
        for path, line in idx.added_lines:
            if member_decl.match(line):
                return (True, f"added `{field_name}` declaration in {path} "
                              f"(type `{type_name}` referenced elsewhere)")
    return (False, f"no added line declares member `{field_name}` in a "
                   f"file referencing type `{type_name}`")


def _reconcile_fix_n(claim: _Claim, idx: _DiffIndex) -> tuple[bool, str]:
    n = claim.args[0]
    # Count distinct edit "regions": added or removed non-empty non-comment
    # lines, deduped per (path, line-fingerprint).
    edits: set[tuple[str, str]] = set()
    for path, line in idx.added_lines + idx.removed_lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("//") or stripped.startswith("/*"):
            continue
        if stripped.startswith("///") or stripped.startswith("*"):
            continue
        edits.add((path, stripped))
    if len(edits) >= n:
        return (True, f"{len(edits)} distinct edit(s) ≥ claimed {n}")
    return (False, f"only {len(edits)} distinct non-comment edits found; "
                   f"claim says fixes {n}")


_RECONCILERS = {
    "REM": _reconcile_rem,
    "REN": _reconcile_ren,
    "EXT": _reconcile_ext,
    "MIG": _reconcile_mig,
    "ADDFLD": _reconcile_addfld,
    "FIX_N": _reconcile_fix_n,
}


@dataclass
class _Result:
    claim: _Claim
    ok: bool
    detail: str

    def render(self) -> str:
        status = "OK" if self.ok else "UNSUPPORTED"
        return (f"{status}: {self.claim.source}: claim={self.claim.kind} "
                f"args={self.claim.args}: {self.detail}")


def _reconcile_all(claims: list[_Claim], idx: _DiffIndex) -> list[_Result]:
    results: list[_Result] = []
    for c in claims:
        reconciler = _RECONCILERS.get(c.kind)
        if reconciler is None:
            results.append(_Result(claim=c, ok=False,
                                   detail=f"no reconciler for kind {c.kind}"))
            continue
        ok, detail = reconciler(c, idx)
        results.append(_Result(claim=c, ok=ok, detail=detail))
    return results


# --- CLI -------------------------------------------------------------------

def _read_path(path: str | None, label: str) -> str:
    if path is None:
        return ""
    p = Path(path)
    if not p.is_file():
        print(f"ERROR: {label} file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return p.read_text(encoding="utf-8", errors="replace")


def _read_diff(path: str | None) -> str:
    if path is None or path == "-":
        return sys.stdin.read()
    return _read_path(path, "diff")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-contract-reconciliation.py",
        description=(
            "Reconcile commit/PR/intent/contract claims against the staged "
            "diff. Catches the 'claims X, diff doesn't' gap class."
        ),
    )
    parser.add_argument("--commit-msg", default=None)
    parser.add_argument("--pr-body", default=None)
    parser.add_argument("--intent", default=None)
    parser.add_argument("--swarm-contract", default=None)
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input. `-` or omit for stdin.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress summary line.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print results; never exit non-zero.")
    args = parser.parse_args(argv)

    sources = [
        ("commit-msg", args.commit_msg),
        ("pr-body", args.pr_body),
        ("intent", args.intent),
        ("swarm-contract", args.swarm_contract),
    ]
    claims: list[_Claim] = []
    for label, path in sources:
        if path is None:
            continue
        text = _read_path(path, label)
        claims.extend(_parse_claims_from_text(text, label))

    if not claims:
        if not args.quiet:
            print("OK: no claims parsed from any source.", file=sys.stderr)
        return 0

    diff_text = _read_diff(args.diff)
    idx = _parse_diff(diff_text)

    results = _reconcile_all(claims, idx)
    unsupported = [r for r in results if not r.ok]

    for r in results:
        print(r.render())

    if not args.quiet:
        print(f"\n{len(claims)} claim(s); {len(unsupported)} unsupported.",
              file=sys.stderr)

    if args.dry_run:
        return 0
    return 1 if unsupported else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

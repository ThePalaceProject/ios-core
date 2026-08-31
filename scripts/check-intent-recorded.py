#!/usr/bin/env python3
"""
check-intent-recorded.py — require an intent file for non-trivial prod diffs.

If a diff adds at least `--threshold-loc` (default 10) lines under
`Palace/`, then a corresponding intent file must exist under
`--intent-dir` (default `.forgeos/intent/`). The intent file:

  - Has frontmatter with `name`, `created`, `author` keys.
  - Contains body sections `## Claims`, `## Anti-claims`, `## Files in scope`.
  - Lists, under `## Files in scope`, every production file the diff adds
    lines to.

PP-5024: the intent used to be selected by token-matching its `name:` against
the subject of the NEWEST commit. The thing being validated is the whole
branch, so that made the verdict a function of how the last commit happened to
be worded — a correct intent went red behind a "fix review nit" commit, and an
unrelated intent went green on four shared words. Worse, the way past it was to
reword the subject, so the gate could be satisfied by phrasing rather than by
the work being described.

Selection is now the file scope. If the diff writes its own intent file(s),
those are what get judged — as a union, so a branch may record two intents for
two strands of work. Otherwise the pre-existing intent covering the most of the
diff is used, which keeps work that continues under an earlier intent green.
Either way the selected intent(s) must name every production file the diff adds
code to. Commit wording is not an input, so no rewording can turn a red check
green. `--commit-msg` is still accepted for call-site compatibility and is no
longer used for matching.

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
  --commit-msg <file>      Accepted and ignored (see PP-5024 above).
  --threshold-loc N        Prod-LOC threshold (default 10).
  --intent-dir <path>      Intent file directory (default .forgeos/intent/).
  --quiet                  Suppress summary on stderr.
  --dry-run                Print state; never exit non-zero.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
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

_FILE_HDR_RE = re.compile(r"^\+\+\+ b/(.+)$")
_SWIFT_COMMENT_RE = re.compile(r"^\s*(?://|///|/\*|\*\s|\*/)")
_FRONTMATTER_RE = re.compile(r"^([a-zA-Z_]+):\s*(.+)$")

# `## Files in scope` heading, and the path-like tokens inside that section.
# The token class deliberately excludes backticks, parentheses and commas so
# the corpus's several spellings — `- `path``, `- path (new)`, `- path — why`,
# `- pathA, pathB` — all yield bare paths. A token counts only if it has a
# slash, which drops prose words and keeps directory entries like `scripts/`.
#
# Braces are expanded FIRST. `Palace/AppInfrastructure/{AppContainer,Scene}.swift`
# is an author enumerating two files; tokenizing it raw would truncate at the
# `{` and leave `Palace/AppInfrastructure/` — a cover over the whole directory,
# which is the opposite of what was written. Measured on the corpus: 97 of 811
# `Palace/*.swift` files were covered ONLY by that collapse, including
# `Store.swift`, `SceneDelegate.swift` and `NavigationCoordinator.swift`.
# A `**` glob is left to collapse, because there the directory IS the intent.
# The heading carries a parenthetical in a few files — `## Files in scope
# (test target only)`, `(14)` — so match the phrase, not the whole line.
_SCOPE_HEADING_RE = re.compile(r"^(#{1,6})\s*files\s+in\s+scope\b",
                               re.IGNORECASE)
_ANY_HEADING_RE = re.compile(r"^(#{1,6})\s+\S")
_PATH_TOKEN_RE = re.compile(r"[A-Za-z0-9_.+@-]+(?:/[A-Za-z0-9_.+@-]+)*/?")
_BRACE_RE = re.compile(r"\{([^{}]*)\}")


# --- Diff parsing ----------------------------------------------------------

@dataclass
class _DiffStats:
    prod_loc_added: int
    files_touched: list[str]
    # Files this diff ADDS lines to (not merely deletes from). An intent file
    # in here was written or extended by this branch, so it is the branch's
    # own — as opposed to an older sibling that happens to list the same code.
    files_added_to: list[str]
    # Production files this diff ADDS lines to, in first-seen order. These are
    # the files the intent has to account for — the same lines that decide
    # whether an intent is required at all decide what it must describe.
    prod_files: list[str]


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
    added_to: list[str] = []
    prod_files: list[str] = []
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
        if text.strip() and current_path not in added_to:
            added_to.append(current_path)
        if not _is_prod_path(current_path):
            continue
        stripped = text.strip()
        if not stripped:
            continue
        if _SWIFT_COMMENT_RE.match(text):
            continue
        prod_added += 1
        if current_path not in prod_files:
            prod_files.append(current_path)
    return _DiffStats(prod_loc_added=prod_added, files_touched=files,
                      files_added_to=added_to, prod_files=prod_files)


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


def _expand_braces(entry: str) -> list[str]:
    """Expand one line's `{a,b}` alternations into separate lines.

    `Palace/X/{A,B}.swift` -> [`Palace/X/A.swift`, `Palace/X/B.swift`].
    A line with no braces comes back unchanged, as a single-element list.

    Anything with a brace still in it after expansion is DROPPED, and that
    is the whole point of the function rather than an edge case. The failure
    mode is silent and it is the one this guard exists to close: a group that
    does not expand gets tokenized raw, the token truncates at the `{`, and
    `Palace/AppInfrastructure/{AppContainer,` becomes a cover over all 26
    files in that directory — broader than written, from an entry naming two.
    Two ways in, both real. `_BRACE_RE` needs a closing brace, so a group
    wrapped across two lines leaves each half unbalanced (there is already
    such a wrap in the corpus, on a test path). And the pass bound expands one
    group per pass, so a line with more groups than passes keeps its tail.
    A malformed enumeration must cover nothing, never everything under it.

    The caller splits a line into entries first, so a residual brace costs
    only its own entry. Doing it line-wise cost a well-formed sibling: the
    corpus wrap above shares its line with an explicitly enumerated
    `Palace/AppInfrastructure/AppContainer.swift`, and dropping that silently
    is a false red — the same silent-rule complaint the `too_broad` and
    `ineligible` lines exist to answer.

    How wide the truncation reaches is not a property to lean on. Groups
    expand leftmost-first, so a leftover from an exhausted pass budget sits
    right of everything expanded and can only over-cover at depth. But an
    unmatched `{` to the LEFT of a well-formed group truncates to `Palace/`,
    tree-wide. That is caught by `_scope_covers` refusing top-level entries,
    independently of this guard — two rules, deliberately not one.
    """
    out = [entry]
    for _ in range(8):                  # passes, not nesting: one group each
        grown: list[str] = []
        changed = False
        for item in out:
            m = _BRACE_RE.search(item)
            if not m:
                grown.append(item)
                continue
            changed = True
            for alt in m.group(1).split(","):
                grown.append(item[:m.start()] + alt.strip() + item[m.end():])
        out = grown
        if not changed:
            break
    return [item for item in out if "{" not in item and "}" not in item]


def _dropped_is_relevant(entry: str, prod_files: list[str]) -> bool:
    """True if a discarded entry, read up to its brace, names a directory one
    of the changed files sits in — i.e. it was probably trying to describe
    this work before the brace swallowed it."""
    head = entry.split("{", 1)[0]
    for token in _PATH_TOKEN_RE.findall(head):
        # Same refusal as `_scope_covers` and the `too_broad` rule: a
        # top-level entry is a prefix of every production file, so without
        # this a stranger's `Palace/{Dir,` would print on every failing
        # branch forever — the noise this predicate exists to prevent. It
        # subsumes a slash-required check, since a slash-less token counts 0.
        if token.rstrip("/").count("/") < 1:
            continue
        # Normalised to a directory boundary so `Palace/Syn` cannot match
        # `Palace/Sync/Foo.swift` on a partial segment.
        prefix = token if token.endswith("/") else token + "/"
        if any(f.startswith(prefix) for f in prod_files):
            return True
    return False


def _split_entries(line: str) -> list[str]:
    """Split a scope line into entries on commas at brace depth 0.

    Depth-aware so `{A,B}.swift` stays one entry. An unmatched `{` never
    returns to depth 0, which puts the malformed remainder in one entry — the
    behaviour we want, since that entry is the one that gets dropped.
    """
    entries: list[str] = []
    depth = 0
    current: list[str] = []
    for ch in line:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            entries.append("".join(current))
            current = []
            continue
        current.append(ch)
    entries.append("".join(current))
    return [e for e in entries if e.strip()]


@dataclass
class _Scope:
    paths: list[str]
    # Entries discarded for still holding a brace. Reported, not silently
    # eaten: an author who wrapped a group over production files would
    # otherwise be told those files are uncovered while looking straight at
    # them in their own intent.
    dropped: list[str]


def _extract_scope_paths(intent_text: str) -> _Scope:
    """Return the repo paths listed under the intent's `## Files in scope`.

    Everything after the heading up to the next heading is scanned for
    path-like tokens. Entries are returned verbatim (minus a sentence-ending
    period); a trailing slash, or a path that is a parent of a changed file,
    is honoured as a directory entry by `_scope_covers`.
    """
    paths: list[str] = []
    dropped: list[str] = []
    depth = 0                       # 0 until the scope heading is seen
    for raw in intent_text.splitlines():
        line = raw.strip()
        heading = _SCOPE_HEADING_RE.match(line)
        if heading:
            depth = len(heading.group(1))
            continue
        if not depth:
            continue
        other = _ANY_HEADING_RE.match(line)
        # A DEEPER heading is still inside the section — several intents group
        # their scope under `### Production` / `### Tests`. Only a sibling or
        # shallower heading ends it.
        if other and len(other.group(1)) <= depth:
            break
        for entry in _split_entries(line):
            expanded = _expand_braces(entry)
            if not expanded and "/" in entry:
                dropped.append(entry.strip())
            for variant in expanded:
                for token in _PATH_TOKEN_RE.findall(variant):
                    if "/" not in token:
                        continue
                    if not token.endswith("/"):
                        token = token.rstrip(".")
                    if token and token not in paths:
                        paths.append(token)
    return _Scope(paths=paths, dropped=dropped)


def _scope_covers(scope_paths: list[str], changed_path: str) -> bool:
    """True if `changed_path` is named — as a file or under a directory —
    by one of the intent's scope entries.

    A top-level directory entry (`Palace/`, or a `Palace/**` glob, which the
    token regex reduces to the same thing) covers nothing: it names the tree,
    not the work, so honouring it would let one line stand in for any change
    anywhere. No corpus intent has one under a PRODUCTION prefix today, and
    that is a coupling rather than a fact about the corpus: seven intents do
    carry top-level entries (`PalaceTests/`, `scripts/`, `docs/`), inert only
    because `_PROD_PATH_PREFIXES` is `("Palace/",)`. Widen that and they start
    covering nothing, which is correct but will read as a regression.
    """
    for entry in scope_paths:
        if entry == changed_path:
            return True
        if entry.rstrip("/").count("/") < 1:
            continue
        if entry.endswith("/") and changed_path.startswith(entry):
            return True
        if changed_path.startswith(entry.rstrip("/") + "/"):
            return True
    return False


@dataclass
class _ScopeMatch:
    path: Path
    covered: list[str]
    uncovered: list[str]
    scope_paths: list[str]
    own: bool           # written or extended by THIS diff
    valid: bool         # frontmatter + required sections


@dataclass
class _Selection:
    """What the intent corpus says about this diff."""
    own: list[_ScopeMatch]          # the branch's own intents, if any
    best: _ScopeMatch | None        # otherwise, the closest pre-existing one
    uncovered: list[str]            # prod files no selected intent lists
    invalid: _ScopeMatch | None     # a selected intent that fails validation
    candidate_count: int
    unscoped_count: int
    # Sibling intents that already list files the selection leaves uncovered.
    covered_elsewhere: list[str] = field(default_factory=list)
    # Intents that DO list the changed files but are not eligible to answer
    # for them — malformed, and not written by this branch.
    ineligible: list[str] = field(default_factory=list)
    # Scope entries ignored for naming a whole tree rather than the work.
    too_broad: list[str] = field(default_factory=list)
    # Scope entries ignored for carrying an unbalanced brace.
    malformed: list[str] = field(default_factory=list)


def _rank(m: _ScopeMatch) -> tuple:
    """Widest coverage first, then the narrower scope, then name (so the
    result does not depend on directory-iteration order)."""
    return (-len(m.covered), len(m.scope_paths), m.path.name)


def _select_intent(intent_dir: Path, prod_files: list[str],
                   files_added_to: list[str]) -> _Selection:
    """Decide which intent file(s) speak for this diff, and what they miss.

    Two cases, and the distinction matters:

    - **The branch wrote its own intent(s).** Any intent file this diff adds
      lines to is the branch speaking for itself, so those — and only those —
      are judged, as a union. A branch may legitimately record two intents for
      two strands of work; between them they must still name every production
      file the branch changes. An older sibling intent does not get to fill
      the gap, because then "is this work described" would be answered by the
      corpus rather than by the author.

    - **The branch wrote none.** Fall back to the pre-existing intent that
      covers the most of the diff — work that continues under an intent
      recorded earlier stays green. Only STRUCTURALLY VALID intents are
      eligible here. 26 of the corpus's intents predate the frontmatter rule,
      and selecting one would report INTENT-INVALID against a branch that
      never touched it — which is what a hotfix forward-port into develop
      does, since those land as merge commits carrying a wide diff. An
      author is answerable for the intent they wrote, not for a stranger's.
    """
    if not intent_dir.is_dir():
        return _Selection([], None, list(prod_files), None, 0, 0)
    own_names = {
        Path(f).name for f in files_added_to
        if f.endswith(".md") and "intent" in Path(f).parent.name.lower()
    }
    unscoped = 0
    matches: list[_ScopeMatch] = []
    too_broad: set[str] = set()
    malformed: set[str] = set()
    candidates = sorted(intent_dir.glob("*.md"))
    for c in candidates:
        text = _read_text(c)
        if text is None:
            continue
        is_own = c.name in own_names
        scope = _extract_scope_paths(text)
        scope_paths = scope.paths
        # Reported when it is the branch's own intent, OR when the entry —
        # truncated at its brace — is a directory prefix of a file this diff
        # changes. Reported corpus-wide it would append a stranger's dropped
        # test path to every failure forever, so the relevance arm matters.
        # But eligibility-for-diagnosis is not eligibility-for-verdict, and
        # they have opposite polarity: narrowing who may be JUDGED protects
        # the author, while narrowing what may be EXPLAINED costs them. A
        # dropped entry has no other channel — it expands to nothing, so its
        # intent never becomes a candidate and can never reach `ineligible`.
        malformed.update(
            e for e in scope.dropped
            if is_own or _dropped_is_relevant(e, prod_files))
        # An entry that would have covered something, had it named the work
        # instead of the tree. Collected so the failure can say why it was
        # ignored — a rule with no occurrences under a production prefix
        # exists to teach future authors, and it teaches nothing when it
        # fires silently.
        too_broad.update(
            e for e in scope_paths
            if e.rstrip("/").count("/") < 1
            and any(f.startswith(e.rstrip("/") + "/") for f in prod_files))
        if not scope_paths and not is_own:
            # Nothing to match on, and not this branch's file — say so in the
            # failure message rather than silently treating it as a candidate.
            unscoped += 1
            continue
        covered = [f for f in prod_files if _scope_covers(scope_paths, f)]
        if not covered and not is_own:
            continue
        matches.append(_ScopeMatch(
            path=c,
            covered=covered,
            uncovered=[f for f in prod_files if f not in covered],
            scope_paths=scope_paths,
            own=is_own,
            valid=_parse_intent(c).ok,
        ))

    # Malformed strangers that nonetheless list the changed files. The verdict
    # excludes them deliberately; the diagnosis must still name them, or it
    # sends the author looking for a file that is sitting right there.
    ineligible = sorted({m.path.name for m in matches
                         if not m.valid and not m.own})

    own = sorted([m for m in matches if m.own], key=_rank)
    if own:
        covered = {f for m in own for f in m.covered}
        uncovered = [f for f in prod_files if f not in covered]
        # We know which sibling intents DO cover the gap. Saying so is the
        # difference between "add these files somewhere" and "this file is
        # already described over there, decide which intent owns it" — the
        # same reporting gap the retired near-miss ranking existed to close.
        elsewhere = sorted(
            {m.path.name for m in matches
             if not m.own and m.valid and set(m.covered) & set(uncovered)})
        return _Selection(
            own=own,
            best=None,
            uncovered=uncovered,
            invalid=next((m for m in own if not m.valid), None),
            candidate_count=len(candidates),
            unscoped_count=unscoped,
            covered_elsewhere=elsewhere,
            ineligible=ineligible,
            too_broad=sorted(too_broad),
            malformed=sorted(malformed),
        )

    pool = sorted([m for m in matches if m.valid], key=_rank)
    if not pool:
        return _Selection([], None, list(prod_files), None,
                          len(candidates), unscoped,
                          ineligible=ineligible, too_broad=sorted(too_broad),
                          malformed=sorted(malformed))
    best = pool[0]
    return _Selection(
        own=[],
        best=best,
        uncovered=list(best.uncovered),
        invalid=None,               # strangers are pre-filtered to valid ones
        candidate_count=len(candidates),
        unscoped_count=unscoped,
        ineligible=ineligible,
        too_broad=sorted(too_broad),
        malformed=sorted(malformed),
    )


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


# --- CLI -------------------------------------------------------------------

_read_diff = read_diff  # shared with scripts/_checklib.py


def _print_ignored(sel: _Selection) -> None:
    """Say what the scan saw and set aside. Both lines exist because the
    verdict was right while the diagnosis pointed somewhere else: an intent
    that lists the file but cannot answer for it, and an entry that would
    have matched but names the whole tree."""
    if sel.ineligible:
        print("  Lists these files but cannot answer for them (no `---` "
              "frontmatter or a missing required section, and not written "
              "by this branch): " + ", ".join(sel.ineligible))
    if sel.malformed:
        print("  Ignored for an unbalanced brace — a `{` group that does not "
              "close on its own line expands to nothing, so these list no "
              "file: " + ", ".join(sel.malformed))
    if sel.too_broad:
        print("  Ignored as too broad — these name the tree, not the work, "
              "so one line would stand in for any change anywhere: "
              + ", ".join(sel.too_broad))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-intent-recorded.py",
        description=(
            "Require a .forgeos/intent/<name>.md file when a diff adds "
            "≥ --threshold-loc lines to Palace/ production code. Intent "
            "file must have frontmatter (name/created/author) + body "
            "sections (Claims / Anti-claims / Files in scope), and its "
            "`## Files in scope` must name every production file the diff "
            "adds lines to."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file.")
    parser.add_argument("--commit-msg", default=None,
                        help="Accepted for call-site compatibility; not used "
                             "for matching (PP-5024).")
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
    stats = _parse_diff(diff_text)

    if stats.prod_loc_added < args.threshold_loc:
        if not args.quiet:
            print(f"OK: {stats.prod_loc_added} prod LOC < threshold "
                  f"{args.threshold_loc}; no intent required.",
                  file=sys.stderr)
        return 0

    intent_dir = Path(args.intent_dir)
    sel = _select_intent(intent_dir, stats.prod_files, stats.files_added_to)
    scope_list = ", ".join(stats.prod_files)
    selected = sel.own or ([sel.best] if sel.best else [])

    if not selected:
        if args.dry_run:
            if not args.quiet:
                print(f"DRY-RUN: would require an intent under {intent_dir} "
                      f"listing: {scope_list}", file=sys.stderr)
            return 0
        # "eligible" is load-bearing: a malformed intent may well list these
        # files, and saying flatly that none does would be untrue.
        print(f"INTENT-MISSING: prod LOC added={stats.prod_loc_added} "
              f"≥ threshold={args.threshold_loc}; no eligible intent file in "
              f"{intent_dir} lists any of the production files this diff "
              f"changes.")
        print(f"  Files needing an intent: {scope_list}")
        print(f"  Candidates checked: {sel.candidate_count} file(s)"
              + (f", {sel.unscoped_count} with no path under "
                 f"`## Files in scope`" if sel.unscoped_count else ""))
        _print_ignored(sel)
        print("  Matching rule (PP-5024): an intent matches on its "
              "`## Files in scope`, not on the commit subject. Add the files "
              "above to the intent that describes this work, or write one.")
        return 1

    if sel.invalid is not None:
        if args.dry_run:
            return 0
        validation = _parse_intent(sel.invalid.path)
        print(f"INTENT-INVALID: {validation.path}: {validation.reason}")
        return 1

    if sel.uncovered:
        if args.dry_run:
            if not args.quiet:
                print(f"DRY-RUN: {len(sel.uncovered)} production file(s) not "
                      f"listed by the selected intent(s).", file=sys.stderr)
            return 0
        named = ", ".join(str(m.path) for m in selected)
        whose = ("this branch's own intent" + ("s" if len(selected) > 1 else "")
                 if sel.own else "the closest existing intent")
        print(f"INTENT-SCOPE-INCOMPLETE: {whose} ({named}) "
              f"{'do' if len(selected) > 1 else 'does'} not list "
              f"{len(sel.uncovered)} of the {len(stats.prod_files)} "
              f"production file(s) this diff changes. Missing from "
              f"`## Files in scope`:")
        for f in sel.uncovered:
            print(f"  - {f}")
        _print_ignored(sel)
        if sel.covered_elsewhere:
            print("  Already listed by: "
                  + ", ".join(sel.covered_elsewhere)
                  + " — decide which intent owns that file rather than "
                    "listing it twice.")
        print("  Either add them to the intent, or record a separate intent "
              "for that work.")
        return 1

    if not args.quiet:
        named = ", ".join(str(m.path) for m in selected)
        print(f"OK: {named} lists all {len(stats.prod_files)} production "
              f"file(s) this diff changes and has all required sections "
              f"(prod LOC added={stats.prod_loc_added}).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

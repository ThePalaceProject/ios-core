#!/usr/bin/env python3
"""
test_check_intent_recorded_scope.py — the intent-recorded gate matches on the
intent's `## Files in scope`, not on the newest commit subject (PP-5024).

This file replaces the R9 near-miss tests. Those pinned the failure message of
a subject-token matcher: which intent names came closest to the newest commit
subject, and by what rule. The matcher is gone, and with it the ranking — the
verdict now follows the files, so "which name nearly matched" has nothing to
report. Do not restore it: subject-token matching is the defect PP-5024 fixed,
because the way past it was to reword the commit.

What is pinned here:

  - The commit subject cannot change the verdict, in either direction.
  - A failure names the production files that need an intent, and the rule.
  - The candidate dump stays a count, not 80 undifferentiated filenames.
  - Directory entries and the corpus's several path spellings are honoured.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-intent-recorded.py"

_FRONTMATTER = """---
name: segv-mock-race-bookmark-keys
created: 2026-07-05
author: test
---

## Claims
- x

## Anti-claims
- x

## Files in scope
"""

# A diff adding >10 prod LOC under Palace/.
DIFF = "--- a/Palace/Sync/Foo.swift\n+++ b/Palace/Sync/Foo.swift\n" + "".join(
    f"+let x{i} = {i}\n" for i in range(15))


def _intent(*scope_lines: str) -> str:
    return _FRONTMATTER + "".join(f"- {line}\n" for line in scope_lines)


def _run(tmp: Path, subject: str | None, scope_lines: tuple[str, ...],
         ) -> tuple[int, str]:
    intent_dir = tmp / "intent"
    intent_dir.mkdir(parents=True, exist_ok=True)
    (intent_dir / "segv-mock-race-bookmark-keys.md").write_text(
        _intent(*scope_lines))
    (tmp / "diff.txt").write_text(DIFF)
    argv = ["python3", str(_SCRIPT),
            "--diff", str(tmp / "diff.txt"),
            "--intent-dir", str(intent_dir)]
    if subject is not None:
        (tmp / "msg.txt").write_text(subject + "\n")
        argv += ["--commit-msg", str(tmp / "msg.txt")]
    result = subprocess.run(argv, capture_output=True, text=True,
                            cwd=str(_REPO_ROOT), timeout=30)
    return result.returncode, result.stdout + result.stderr


_COVERING = ("Palace/Sync/Foo.swift",)
_NOT_COVERING = ("Palace/Elsewhere/Bar.swift",)

# Subjects that a token matcher would score very differently: one repeats the
# intent name, one is the narrow follow-up commit from the ticket, one has no
# words in common at all.
_SUBJECTS = [
    "fix: segv mock race bookmark keys hardening",
    "fix review nit",
    "chore: zebra quantum unrelated",
]


def test_subject_cannot_turn_a_covering_intent_red(tmp_path):
    """The ticket's first half: a correct intent passes however the newest
    commit happens to be worded — including with no commit message at all."""
    for i, subject in enumerate([*_SUBJECTS, None]):
        rc, out = _run(tmp_path / f"s{i}", subject, _COVERING)
        assert rc == 0, f"subject={subject!r} went red:\n{out}"


def test_subject_cannot_turn_a_missing_intent_green(tmp_path):
    """The ticket's second half, and the reason it was written down: rewording
    the commit must not be a way past the gate."""
    for i, subject in enumerate([*_SUBJECTS, None]):
        rc, out = _run(tmp_path / f"s{i}", subject, _NOT_COVERING)
        assert rc == 1, f"subject={subject!r} went green:\n{out}"
        assert "INTENT-MISSING" in out


def test_failure_names_the_files_and_the_rule(tmp_path):
    rc, out = _run(tmp_path, "fix review nit", _NOT_COVERING)
    assert rc == 1, out
    assert "Palace/Sync/Foo.swift" in out
    assert "Matching rule (PP-5024)" in out


def test_candidate_dump_is_count_only(tmp_path):
    rc, out = _run(tmp_path, "fix review nit", _NOT_COVERING)
    assert rc == 1, out
    assert "1 file(s)" in out
    assert "segv-mock-race-bookmark-keys.md" not in out


def test_directory_entry_covers_the_files_beneath_it(tmp_path):
    rc, out = _run(tmp_path, None, ("Palace/Sync/",))
    assert rc == 0, out


def test_scope_survives_the_corpus_path_spellings(tmp_path):
    """Backticks, a trailing `(new)`, an em-dash rationale, and two paths on
    one line all appear in `.forgeos/intent/` today."""
    variants = [
        ("`Palace/Sync/Foo.swift`",),
        ("Palace/Sync/Foo.swift (new)",),
        ("`Palace/Sync/Foo.swift` — the queue seam",),
        ("`Palace/Other/Baz.swift`, `Palace/Sync/Foo.swift`",),
    ]
    for i, scope in enumerate(variants):
        rc, out = _run(tmp_path / f"v{i}", None, scope)
        assert rc == 0, f"scope={scope!r} was not recognised:\n{out}"


def test_subheadings_do_not_end_the_scope_section(tmp_path):
    """Several intents group their scope under `### Production` / `### Tests`.
    A deeper heading is still inside the section; only a sibling ends it."""
    intent_dir = tmp_path / "intent"
    intent_dir.mkdir(parents=True)
    (intent_dir / "grouped.md").write_text(
        _FRONTMATTER
        + "\n### Production\n\n- `Palace/Sync/Foo.swift`\n"
        + "\n### Tests\n\n- `PalaceTests/Sync/FooTests.swift`\n"
        + "\n## Notes\n\n- `Palace/NotInScope/Ignored.swift`\n")
    (tmp_path / "diff.txt").write_text(DIFF)
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(tmp_path / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_brace_enumeration_is_expanded_not_collapsed(tmp_path):
    """`Palace/X/{A,B}.swift` is an author naming two files. Truncating at the
    brace would leave `Palace/X/` — a cover over the whole directory, the
    opposite of what was written. 97 of 811 `Palace/*.swift` were covered only
    by that collapse before this was fixed."""
    # The listed alternatives are honoured...
    rc, out = _run(tmp_path / "hit", None, ("Palace/Sync/{Foo,Bar}.swift",))
    assert rc == 0, out
    # ...and a sibling in the same directory that was NOT listed is not.
    rc, out = _run(tmp_path / "miss", None, ("Palace/Sync/{Bar,Baz}.swift",))
    assert rc == 1, out
    assert "Palace/Sync/Foo.swift" in out


def test_a_top_level_directory_covers_nothing(tmp_path):
    """`Palace/` — or a `Palace/**` glob, which the token regex reduces to the
    same string — names the tree, not the work. One line must not stand in for
    any change anywhere."""
    for scope in (("Palace/",), ("Palace/**",)):
        rc, out = _run(tmp_path / scope[0].replace("/", "_"), None, scope)
        assert rc == 1, f"scope={scope!r} blanket-covered the diff:\n{out}"


def test_a_deeper_glob_still_covers_its_directory(tmp_path):
    """The control for the rule above: `**` under a real directory is a
    deliberate cover and keeps working."""
    rc, out = _run(tmp_path, None, ("Palace/Sync/**",))
    assert rc == 0, out


def test_an_unmatched_brace_covers_nothing(tmp_path):
    """The fail-open both reviewers found: a brace group wrapped across two
    lines leaves each half unbalanced, the token truncates at the `{`, and an
    entry naming two files becomes a cover over their whole directory. There
    is already such a wrap in the corpus. A malformed enumeration must cover
    nothing rather than everything under it."""
    rc, out = _run(tmp_path / "wrapped", None,
                   ("Palace/Sync/{Foo,", "Bar}.swift"))
    assert rc == 1, out
    assert "Palace/Sync/Foo.swift" in out
    # ...and the single-line form of the same defect.
    rc, out = _run(tmp_path / "single", None, ("Palace/Sync/{Foo.swift",))
    assert rc == 1, out


def test_more_brace_groups_than_passes_covers_nothing(tmp_path):
    """The pass bound expands one group per pass, so a line with more groups
    than passes keeps its tail — and the tail truncates to a directory cover.

    Groups expand leftmost-first, so the leftover always sits to the RIGHT of
    everything already expanded: the collapse is broader than the enumerated
    leaf but never broader than the written prefix. That is why this case
    needs a file living UNDER the collapsed directory to show anything at all.
    A shallower construction goes red under the fail-open too and proves
    nothing.
    """
    deep = "Palace/Sync/a/c/e/g/i/k/m/o/Deep.swift"
    diff = (f"--- a/{deep}\n+++ b/{deep}\n"
            + "".join(f"+let x{i} = {i}\n" for i in range(15)))
    intent_dir = tmp_path / "intent"
    intent_dir.mkdir(parents=True)
    # Nine groups, eight passes. Written, this names two files called
    # `Other.swift`; collapsed, it covers everything under the directory
    # `Deep.swift` sits in — which the author never wrote.
    (intent_dir / "x.md").write_text(_intent(
        "Palace/Sync/{a,b}/{c,d}/{e,f}/{g,h}/{i,j}/{k,l}/{m,n}/{o,p}/"
        "{q,r}/Other.swift"))
    (tmp_path / "diff.txt").write_text(diff)
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(tmp_path / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30)
    out = result.stdout + result.stderr
    assert result.returncode == 1, out
    assert deep in out


def test_failure_names_an_ineligible_intent_that_lists_the_file(tmp_path):
    """A malformed stranger is excluded from the verdict deliberately — but
    it may list exactly the file in question, and a flat "no intent lists
    this" would send the author looking for something sitting right there."""
    intent_dir = tmp_path / "intent"
    intent_dir.mkdir(parents=True)
    (intent_dir / "legacy.md").write_text(
        "# Intent: pre-frontmatter, the shape 26 of the corpus still has\n\n"
        "## Files in scope\n\n- `Palace/Sync/Foo.swift`\n")
    (tmp_path / "diff.txt").write_text(DIFF)
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(tmp_path / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30)
    out = result.stdout + result.stderr
    assert result.returncode == 1, out
    assert "INTENT-INVALID" not in out          # a stranger is not our finding
    assert "cannot answer for them" in out
    assert "legacy.md" in out
    assert "no eligible intent file" in out     # not "no intent file"


def test_a_too_broad_entry_says_why_it_was_ignored(tmp_path):
    """The blanket-cover rule has zero corpus occurrences, so it exists only
    to teach future authors — and it teaches nothing if it fires silently."""
    rc, out = _run(tmp_path, None, ("Palace/**",))
    assert rc == 1, out
    assert "too broad" in out
    assert "Palace/" in out


def test_a_residual_brace_costs_only_its_own_entry(tmp_path):
    """Dropping malformed enumerations line-wise cost a well-formed sibling.
    The shape is in the corpus: a wrapped brace group shares its line with an
    explicitly enumerated file, and dropping that file silently is a false red.
    """
    rc, out = _run(tmp_path / "shared", None,
                   ("Palace/Sync/Foo.swift, Palace/Other/{A,",))
    assert rc == 0, out          # the enumerated sibling still covers
    # ...while the malformed half covers nothing, so it cannot stand in for
    # the directory it truncates to.
    rc, out = _run(tmp_path / "malformed", None,
                   ("Palace/Elsewhere/Bar.swift, Palace/Sync/{Foo,",))
    assert rc == 1, out
    assert "Palace/Sync/Foo.swift" in out


def test_a_stray_closing_brace_does_not_unbalance_the_split(tmp_path):
    """The depth clamp in `_split_entries`. A continuation line that closes one
    wrapped group and opens another starts at a stray `}`; without clamping,
    depth underflows to -1, the next `{` returns it to 0, and the comma then
    splits INSIDE a well-formed group — silently losing both files it names.
    That is the false-red class this parsing exists to remove, and it sits one
    corpus edit away from the wrap already in
    `perf-wavec-launch-credential-firstrun.md`.
    """
    rc, out = _run(tmp_path, None, ("B}.swift, Palace/Sync/{Foo,Bar}.swift",))
    assert rc == 0, out


def test_a_dropped_entry_says_why_it_was_ignored(tmp_path):
    """An author must not be told a file is uncovered while looking straight
    at it in an intent, just because a brace swallowed the entry.

    Reported when the intent is the branch's OWN, or when the entry — read up
    to its brace — is a directory prefix of a changed file. Each arm gets its
    own case below: pinning only the pair leaves either arm free to be deleted
    without a test noticing, which is how a rule ends up inert.
    """
    intent_dir = tmp_path / "intent"
    intent_dir.mkdir(parents=True)
    # Own intent, entry NOT relevant to the diff — carried by the `is_own`
    # arm alone. Delete that arm and this line disappears.
    (intent_dir / "own.md").write_text(_intent("PalaceTests/Own/{B,"))
    # Stranger intent, entry IS a directory prefix of the changed file —
    # carried by the relevance arm alone. Delete that arm and this goes.
    (intent_dir / "relevant.md").write_text(_intent("Palace/Sync/{Foo,"))
    # Stranger intent, entry irrelevant — must never appear, or the line
    # becomes a permanent stranger's-test-path footer on every failure.
    (intent_dir / "stranger.md").write_text(_intent("PalaceTests/Sync/{A,"))
    (tmp_path / "diff.txt").write_text(
        DIFF
        + "--- /dev/null\n+++ b/.forgeos/intent/own.md\n"
        + "+---\n+name: recorded-by-this-branch\n+---\n")
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(tmp_path / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30)
    out = result.stdout + result.stderr
    assert result.returncode == 1, out
    assert "unbalanced brace" in out
    assert "PalaceTests/Own/{B," in out          # is_own arm
    assert "Palace/Sync/{Foo," in out            # relevance arm
    assert "PalaceTests/Sync/{A," not in out     # neither arm


def test_a_dropped_entry_relevance_refuses_top_level_and_partial_segments(
        tmp_path):
    """The relevance arm is the only thing keeping a stranger's dropped entry
    off unrelated branches, so its own guards need pinning.

    A top-level head (`Palace/`) is a prefix of every production file, and a
    partial segment (`Palace/Syn`) is a prefix of `Palace/Sync/...` as a raw
    string. Either would print a stranger's entry on every failing branch —
    the noise the arm exists to prevent, one level down.
    """
    intent_dir = tmp_path / "intent"
    intent_dir.mkdir(parents=True)
    (intent_dir / "top-level.md").write_text(_intent("Palace/{Dir,"))
    (intent_dir / "partial.md").write_text(_intent("Palace/Syn{c,"))
    (tmp_path / "diff.txt").write_text(DIFF)
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(tmp_path / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30)
    out = result.stdout + result.stderr
    assert result.returncode == 1, out
    assert "Palace/{Dir," not in out
    assert "Palace/Syn{c," not in out

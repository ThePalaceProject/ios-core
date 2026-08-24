#!/usr/bin/env python3
"""
CLAUDE.md's description of `--quick` must stay true.

WHY THIS EXISTS (PP-4976). The ticket asked to reconcile what `--quick` actually
runs against what CLAUDE.md promises, because a run reported six tests where the
documentation described a full-scheme pass.

Measuring settled it in an unexpected direction: the SCOPE was never wrong. The
unit-test leg has always invoked the whole scheme with no `-only-testing`. The
six-test reading was a REPORTING defect — the tally was scraped from stdout,
which does not carry the rollup under parallel clones, and the same tree
reported 2815, 4786 and 0 tests on three consecutive runs. That was fixed
separately by reading the xcresult.

So what remained was a documentation gap rather than a behaviour gap: "runs the
full battery" did not say what `--quick` omits, and it omits exactly one thing.
Mutation is the leg that answers whether the tests would notice if the code were
wrong, which makes it the one worth naming.

Documentation drifts silently. This makes the claim falsifiable.
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VPR = os.path.join(REPO, "scripts", "verify-pr.sh")
CLAUDE_MD = os.path.join(REPO, "CLAUDE.md")


def vpr_source() -> str:
    with open(VPR, encoding="utf-8") as fh:
        return fh.read()


def legs_skipped_by_quick() -> set:
    """Every leg whose skip is conditioned on QUICK being true.

    Derived from the script rather than listed here — a hand-maintained list
    would drift the moment someone adds a `--quick` guard, which is the exact
    failure this file exists to prevent.
    """
    src = vpr_source()
    skipped = set()
    for m in re.finditer(r'\[ "\$QUICK" = "true" \][^\n]*\n(.*?)(?=\nelif|\nelse|\nfi)',
                         src, re.S):
        for key in re.findall(r'record "([a-z_0-9]+)" "skip"', m.group(1)):
            skipped.add(key)
    return skipped


def test_quick_skips_exactly_one_leg():
    """If a second leg ever becomes --quick-conditional, the docs are stale and
    this fails rather than the next person discovering it mid-review."""
    skipped = legs_skipped_by_quick()
    assert skipped == {"mutation"}, (
        f"--quick now skips {sorted(skipped) or 'nothing'}, but CLAUDE.md says it "
        f"skips exactly mutation. Update the documentation or the guard."
    )


def test_claude_md_names_the_omission():
    """The words that carry the claim. A reader deciding "am I verified?" reads
    this line and nothing else."""
    with open(CLAUDE_MD, encoding="utf-8") as fh:
        text = fh.read()
    assert "`--quick` skips exactly one leg: **mutation testing**." in text, (
        "CLAUDE.md no longer names what --quick omits — that sentence is the "
        "whole point of PP-4976's third bullet"
    )


def test_the_unit_test_leg_really_is_a_full_scheme_pass():
    """The other half of the reconciliation, asserted rather than assumed.

    If someone ever narrows this to `-only-testing`, the documentation's
    "full-scheme single pass" becomes false and this catches it.
    """
    src = vpr_source()
    m = re.search(r'TEST_OUTPUT=\$\((.*?)\)\n', src, re.S)
    assert m, "the unit-test invocation has moved — re-read this test"
    invocation = m.group(1)
    assert "-scheme Palace" in invocation, "the unit-test leg no longer names the scheme"
    assert "-only-testing" not in invocation, (
        "the unit-test leg is now scoped with -only-testing, so CLAUDE.md's "
        "'full-scheme single pass' is no longer true"
    )


def test_the_tally_comes_from_the_xcresult_not_stdout():
    """The actual PP-4976 defect: a stdout-scraped tally reported 2815, 4786 and
    0 tests on three consecutive runs of the same tree. The xcresult is
    authoritative; stdout is the fallback."""
    src = vpr_source()
    assert "xcresult_summary.py" in src, (
        "the tally no longer reads the xcresult — it will under-report under "
        "parallel clones, which is how this ticket started"
    )
    xcr = src.index("xcresult_summary.py")
    fallback = src.index("ROLLUP_LINES=")
    assert xcr < fallback, (
        "stdout scraping now runs before the xcresult tally — the unreliable "
        "source must be the fallback, not the primary"
    )

---
date: 2026-09-27
pr: "#TBD (arch/phase-a-rearm-gates)"
source: reviewer-block
reviewer_ids: []
changeset_id: ""
wall: reviewer
walls: [reviewer, stale-doc, implementer]
severity: high
wall_status: applied
applied_in: arch/phase-a-rearm-gates
detector_script: ""
detector_status: queued
no-detector: ""
name: corrected-claim-survives-its-siblings
type: incident
---

# A claim corrected in one place survives everywhere else it was written down

## What happened

Repeatedly across one change, a defect was fixed at the
site review named and left standing at every other site that carried it.

1. **The fail-closed claim.** Round four corrected "the gate fails closed on
   malformed YAML" in the module docstring and the commit body. Round five found
   it alive in the TEST's docstring — and that arm passed only because its
   fixture's malformed YAML happened to contain no `run:` body. Given the same
   file with a real invocation the gate returns `ok`, exit 0. So the arm was
   inert AND asserted the thing already known to be false.

2. **The comment skip.** Round five added "skip comment lines" to
   `_ineffective_job_spans`. Round six found `_job_is_ineffective` — the *other*
   loop walking the same job block, twenty lines away — still treating a comment
   as structure. A comment at or left of the job's indent ended the key scan, so
   a job-level `continue-on-error: true` below it was never seen: a false green
   in the gate whose own docstring says false green is the defect.

3. **The accretion citation.** "+474 code lines across releases 3.2.4 / 3.3.0 /
   3.3.1" was wrong on three axes — the baseline attributes those deltas to the
   3.2.1/3.2.2/3.2.3 forward-port (PR #1348), they are physical line counts not
   code lines, and 474 omits the +54 the same sentence itemizes (it is +528; a
   wider total is not quotable, since the baseline's entries mix the two
   metrics). It had been copied into the commit body, the
   gate script, and the decomposition plan. Correcting the first left **two more
   instances in the same file**, found only by grepping for the number.

4. **The `ledger.yml` instance.** A comment asserted that repo file "carries
   exactly this shape". Measured, it is a near-miss: the comment sits past its
   job's content, and the fix changes output for 0 of 16 workflows. The claim
   appeared in the module, the test docstring, and the commit body.

## Why the normal instinct fails

Fixing code at the named site is usually sufficient, because code has one
definition. A *claim* has as many definitions as places someone wrote it down —
docstring, inline comment, commit body, ADR, test name — and none of them are
reachable from the others. Tests do not cover prose, the type system does not
cover prose, and mutation does not cover prose.

Worse, the copies are the persuasive ones. A number repeated in three files
reads as corroborated. In case 3 the reviewer had to go to the baseline file to
discover that all three copies descended from a single misreading.

## The remedy failed on its first use, which is the most useful part

The entry above prescribed `grep -rn "<phrase>" scripts/ docs/ .forgeos/`. On
the very next round a reviewer ran exactly that and found **three more
survivors** of case 3 — one in `verify-pr.sh` and two in
`test_check_file_size_ceiling.py`, one of those in the docstring of the arm
described as "the one that must never silently pass".

The sweep had been run. It reported clean. It was piped through
`grep -viE "test_|\.json|baseline"` — a filter added to drop noise, which
removed **test files**: the exact site this entry names as most-missed. Two of
the three survivors were behind that filter.

So the failure is not "we forgot to sweep". It is that a sweep with a
convenience filter reports the same clean output as a sweep with nothing left to
find, and the filter was written by someone who had just documented which sites
get missed.

Corollary, and the reason this is recorded rather than quietly fixed: **a
remedy is a claim too.** "I swept for it" needs the same treatment as any other
verification claim — show the command, and read what it excluded.

## Then it happened again, at a site the correction itself had named

The C8 correction enumerated three locations: the commit body, the gate script,
and the decomposition plan. Two were fixed. **The third — named in my own
sentence, in the same paragraph — was not swept**, and a reviewer found `+543`
still standing in `god-class-decomposition-plan.md`, now contradicting the gate
script three directories away, which by then said a wider total "is not
quotable".

This is the strongest form of the pattern, and it rules out the comfortable
explanation. It was not that the other sites were hard to find, or that a filter
hid them, or that nobody thought to look. **The location was written down, by
me, in the text being corrected, and the sweep still did not reach it.**

Enumerating where a claim lives is not the same act as fixing it there, and the
enumeration creates a false sense of completion — having listed three sites, the
work feels done at two. The list is a to-do, not a receipt.

Practical consequence: when a correction names N sites, fix them in the same
edit and then re-grep, because the list will be believed the moment it is
written. And note which artifact is worst to leave stale — here it was the
decomposition plan, which no gate reads and which phases B through F execute
from.

## The count is deliberately not stated as a numeral anywhere

An earlier version of this entry opened "Four times in one change", its own §6
said "a sixth", the body said "seven", and the INDEX row said "four" — three
different counts of one claim, in the document whose rule is *grep for the
claim, not the line*. A reviewer found it, which is the correct outcome and also
the embarrassing one.

The numeral is now absent from the prose and from the index row. The enumerated
list above IS the count; adding an instance means adding an entry, and there is
no second place to update. A number restated in prose is a claim, and this
entry exists because claims get copied and then corrected in one place.

## A variant worth naming separately: correcting by APPENDING

One instance was not a missed copy but a botched correction.
`test_live_repo_passes`'s docstring asserted "Neither gate is a named step in
tooling-checks.yml"; when that stopped being true, a correction was appended
four lines below it — leaving both claims in one docstring, with the wrong one
first. A reader who stops early gets the false version, and grep for the claim
finds it and reads the correction as agreement.

Replace the text. An appended correction is two claims, not one, and the stale
one keeps its position.

## The rule

**When review corrects a claim, grep for the claim, not the line.** Before
calling it fixed:

    grep -rn "<the distinctive number / phrase>" scripts/ docs/ .forgeos/
    git log -1 --format=%B | grep -n "<same>"

Two sites specifically get missed and are worth naming: the **test docstring**
(prose about the code under test, never read when the code is fixed) and the
**second loop over the same structure** (case 2 — two functions walking a job
block, the fix applied to one).

The same applies to a behavioural fix with more than one code path: ask "what
else walks this?" before ask "does the test pass?".

## Detector

Queued. A claim-consistency check cannot be general, but two narrow and
mechanical arms are worth having: flag a numeric literal that appears in a
commit body AND in a committed comment when only one of them changed in that
commit; and flag a docstring in `scripts/tests/` asserting a safety direction
("fails closed", "cannot be fooled", "always") for a gate whose own module
docstring disclaims it. The second is the one that would have caught case 1.

---
date: 2026-08-17
source: near-miss
walls: [contract-reconciliation, intent-recorded, blast-radius, superpartner]
severity: medium
wall_status: open
---

# claim-outran-the-commit

## Finding

PP-4969, tip `5a3f9d03c`. Two independent reviewers blocked with the same
verdict:

> "The code change you describe is not in the commit. Only the intent doc
> changed. `DownloadAuthChallengeWitnessTests.swift` is `748f169fe…` at *both*
> shas — byte-identical. There is no `XCTAssertIdentical` anywhere in the file."
> — qa_test

> "`XCTAssertIdentical` appears **zero** times … and zero times anywhere in
> `git diff origin/develop...5a3f9d03c`." — blast_radius

The commit message and `.forgeos/intent/pp-4969-answer-challenges-with-the-request-account.md`
both stated, as completed fact, "All three are identity now" and "reverting the
helper fails … 3 of 3 with identity". Against that tree the true figure was
1 of 3. QA re-ran the measurement on the tip and got 1 of 3, matching the
pre-change state.

## What actually happened

The edits were real and the 3-of-3 measurement was real — but they existed only
in the working tree, and were destroyed before the commit.

Sequence:

1. Applied the identity-assertion edits to
   `PalaceTests/MyBooks/DownloadAuthChallengeWitnessTests.swift`. Uncommitted.
2. Ran the baseline (13/13) and then the guard-bite measurement, which mutates
   the SAME file to reintroduce the two-instance defect. Got the genuine 3-of-3.
3. Reverted the mutation with
   `git checkout -- PalaceTests/MyBooks/DownloadAuthChallengeWitnessTests.swift`.
   HEAD at that moment was `98b40ef70`, which did not contain the identity edits
   — so the checkout discarded BOTH the defect mutation and the real work.
4. Amended. Only `.forgeos/…` was still modified, so only the doc landed.

The evidence was on screen and unread: the `git status --short` printed
immediately before the amend listed only the intent doc. Nothing else was
modified because the test file had already been reverted to HEAD.

Net effect is worse than shipping the weaker assertions would have been. The
weaker code carried a known, reviewer-documented gap; the artifact instead
recorded that the gap had been measured away, so no later reader — human or gate
— had reason to re-check.

## Walls that should have caught it

- **contract-reconciliation** — passed (0 findings). It matches "removes X" /
  "adds field A to type B" shapes. A claim naming a concrete symbol
  (`XCTAssertIdentical`) that appears nowhere in the diff is not one of its
  shapes, so the drift was invisible to it.
- **intent-recorded** — passed. It checks that an intent file EXISTS and
  token-matches the commit subject. It does not compare the intent's assertions
  against the diff.
- **blast-radius / superpartner** — passed. Both scan the diff for risk; neither
  reads the message or intent, so neither can see a claim about content that
  isn't there.
- **The reviewers caught it**, twice, independently, by hashing the blob rather
  than reading the narrative. That worked — but it is the expensive path, and it
  only worked because two reviewers happened to verify rather than accept.

## Proposed permanent fix

**Detector (designed by the blast_radius reviewer, verbatim):** in
`scripts/check-contract-reconciliation.py`, for any claim of the form *"X is now
Y"* / *"became Y"* where `Y` is an identifier, require `Y` to appear as an ADDED
line in the diff. One line of output, catches this class without a human.

Concretely, the trigger set should include claims naming a code identifier
(CamelCase, `snake_case`, or `foo(bar:)` selector shape) in a sentence whose verb
is a completion claim ("is now", "became", "now uses", "changed to", "replaced
with"). Flag when the identifier occurs zero times in `+` lines.

**Cheap author-side habit, complementary not substitute:** before re-requesting
review, run `git show --stat HEAD` and confirm every file the message claims to
change is listed. One command; would have caught this in isolation.

**Related standing rule this instantiates:** never `git checkout -- <file>` to
revert a mutation when that file also carries uncommitted work. Commit first,
then mutate — the mutation revert is then safe because the tip holds the real
change. This is the same defect class as
`verify-means-build-not-just-review` ("'verified green' REQUIRES the CURRENT
tip"), one level up: measured-on-a-working-tree, recorded-on-a-commit.

## Application log

- 2026-08-17 — Recorded. Identity edits re-applied and committed as `88973b6ba`,
  and the measurement re-run **against the committed tip** rather than
  re-asserted from memory: baseline 13/13, defect reintroduction fails 3 of 3
  with no compile error, tip verified to still carry 3 `XCTAssertIdentical` after
  the revert.
- 2026-08-17 — Memory written:
  `never-checkout-a-file-that-holds-uncommitted-work` (author-side habit) and the
  existing `verify-means-build-not-just-review` cross-linked.
- OPEN — the contract-reconciliation generalization is NOT implemented here.
  Deliberately: this branch is a credential-path fix and tooling changes do not
  belong in its revert unit. Filed separately so it does not evaporate.

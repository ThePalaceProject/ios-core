---
date: 2026-09-23
pr: "#1462"
source: reviewer-block
reviewer_ids: [r4073991333]
changeset_id: feature-problem-document-show-title
wall: reviewer
walls: [contract, TDD, reviewer]
severity: high
wall_status: proposed
applied_in: ""
detector_script: "scripts/check-snakecase-codingkeys.py"  # queued — see PP-5234
detector_status: queued
no-detector: ""
name: pr1462-snakecase-codingkeys
type: evolving
status: active
created: 2026-09-23
last_refresh: 2026-09-23
freshness_window: 365d
owners: [network, auth]
description: Declaring a Codable member turned an ignorable JSON key into a document-killing one, and the obvious fix silently deletes the feature
---

# Declaring `show_title` made a wrong-typed flag discard the whole problem document — and the obvious fix would have silently deleted the feature

## Finding (verbatim from reviewer)

> ### Adding this member turns an ignorable key into a document-killing one
>
> `TPPProblemDocument` uses **synthesized** `Codable` -- no `CodingKeys`, no custom
> `init(from:)`. An *unknown* key of any type is ignored; a *declared* key with the wrong
> JSON type throws and kills the **entire** decode. Before this PR `show_title` was in the
> first category. After it, it's in the second.

— PR #1462 review comment [r4073991333](https://github.com/ThePalaceProject/ios-core/pull/1462#discussion_r4073991333),
`Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPProblemDocument.swift:76`

## What actually happened

PR #1462 added `public let showTitle: Bool?` to `TPPProblemDocument` so a library could ask
the client to render its patron-blocking message without the standard title. The member was
added to a type using synthesized `Codable`.

Synthesized `Codable` emits `decodeIfPresent` per member, which returns `nil` only for an
ABSENT or `null` value. A present-but-wrong-typed value throws `typeMismatch` and aborts the
whole decode. So the act of DECLARING the member moved `show_title` from "unknown key,
ignored whatever its type" into "must be exactly right, or the caller gets no document at
all." A server sending `"show_title": "false"` or `0` — a plausible misconfiguration, since
many templating layers stringify booleans — would discard the entire problem document.

On the sign-in path that is not cosmetic. `TPPNetworkResponder.parseAndLogError` parses with
the strict `fromData` (`:825`); its `catch` arm (`:847-857`) returns an `NSError` carrying no
problem document. `TPPSignInBusinessLogic.handleNetworkError` (`:627`) then passes `nil` to
`userFacingSignInError` (`:659`), which skips the branch PR #1462 had just taught to honor
`show_title` and falls through to `Strings.Error.invalidCredentialsErrorMessage`.

**A patron blocked by a library policy would be told their password is wrong, and the
library's `detail` — the entire point of the PR — would never render.**

The second half is what makes this a class rather than an incident. The instinctive fix —
an explicit `CodingKeys` case with the snake_case raw value `"show_title"` — **silently
deletes the feature**, because `fromData` sets `.convertFromSnakeCase`, which rewrites the
incoming key to `showTitle` BEFORE `CodingKeys` matching. Measured:

```
CodingKeys: case showTitle = "show_title", strategy ON
  {"show_title":false}    -> showTitle=nil   <-- correct input, flag never read
  {"show_title":"false"}  -> showTitle=nil   <-- no throw, and no feature
```

It stops the throw, so it passes a test that only covers the type-drift rows, while making
`shouldShowTitle` permanently `true`. No throw, no crash, no log.

## Walls that should have caught it (and why they didn't)

- **TDD**: the PR shipped **eight** `show_title` tests. All eight used well-formed JSON, and
  they missed the bug for **two different reasons** — worth separating, because a reader who
  recognizes only one will wrongly conclude the finding does not apply to them.
  - The four in `TPPSignInBusinessLogicTests` went through a helper,
    `blockedByPolicyDocument(showTitle: Bool?)`, that was *structurally incapable* of
    producing the failing body: `Bool?` cannot express `"false"` or `0`. Those tests were not
    lazy; the helper's type signature fenced the bug out of reach. **Lesson: where a member
    has a wire type, the helper must take a RAW literal, not the Swift type.**
  - The four in `ProblemDocumentTests` had no such excuse. They build raw JSON string
    literals inline and could trivially have written `"show_title": "false"`. That half was
    ordinary missing malformed-input coverage. **Lesson: when you add a typed member to a
    decoded model, the wrong-type row is not an edge case — it is the row that decides
    whether the member can cost you the document.**
- **contract**: no contract existed for this change (it was a feature PR, not a
  /rigorous-fix). The fix-contract written in response then reproduced the same class of
  defect three times — prescribing criteria that no correct implementation could satisfy —
  and each was caught only by RUNNING them against compiled mocks. See "Second-order lesson".
- **reviewer**: caught it. This wall worked, and it worked because the reviewer measured
  rather than reasoned: the comment carries a decode table produced by compiling the real
  class shape, not an argument about how `Codable` behaves.
- **mutation**: structurally blind here. `palace_mutate.py` has no operator for `??` or for
  a member declaration, so neither `showTitle ?? true` nor the act of declaring the member is
  a mutation point. A 100% kill rate on this file would have measured the brace scanner in
  `extractFirstJSONObject`. Measured: `palace_mutate.py --dry-run` on this file discovers 12
  mutation points, and all 12 sit in the brace scanner or in the two auth-category
  `guard let type … else { return false }` returns — none in the `show_title` logic. So the
  decode table is the real verification here and mutation is not even corroboration. A dry-run
  first is also how you learn `palace_mutate.py` CAN discover a surface in an in-project SPM
  package (`Palace/Packages/PalaceCatalog`), which its docs only claim for a sibling checkout.
- **verify-pr / hook**: no detector existed for the class. That is what this entry fixes.

## Proposed permanent fix

1. **Landed in this PR:** `showTitle` decodes inside a `do`/`catch` so an unreadable flag
   degrades to "absent" (→ `shouldShowTitle == true`, the pre-extension behavior) instead of
   costing the document. The five RFC 7807 members stay strict — the leniency is scoped to
   the one member that can afford it.
2. **Landed in this PR:** `scripts/check-snakecase-codingkeys.py` — see below.
3. **Test-shape rule, generalizable:** where a JSON member has a wire type, the test helper
   must accept a RAW literal, not the Swift type. `Bool?` cannot express the bodies that
   break a `Bool?` member.

## Detector script — QUEUED, not landed

**Status: `queued`.** The detector was built and reviewed alongside the fix, then deliberately
split out: it is ~610 lines of new block-mode tooling (script, pytest, ten fixtures, two wiring
points, a hook assertion) riding on a ~15-line sign-in bug fix. Tooling that can block every
commit for every developer deserves review on its own merits, not as a passenger. Follow-up
ticket: **PP-5234**. The implementation exists and is recoverable — see "Implementation already
written" below.

**Planned script:** `scripts/check-snakecase-codingkeys.py`
**Planned tests:** `scripts/tests/test_check_snakecase_codingkeys.py`
**Planned wiring:** `scripts/verify-pr.sh` (`run_phase35_detector`, block-mode, `scan` not
`diff`) and `scripts/pre-commit-phase35-detectors.sh` as
`SNAKECASE_CODINGKEYS|check-snakecase-codingkeys.py|block|scan`, with an end-to-end assertion in
`scripts/tests/test_pre_commit_phase35_detectors.sh`.

**Matching rule (the spec for the follow-up — this is the part worth keeping):** within a Swift
file under `Palace/` containing the literal `.convertFromSnakeCase`, flag any enum that is named
`CodingKeys` **or** conforms to `CodingKey` — nested types in the same file included, since they
inherit the decoder's strategy — declaring a `case` whose explicit string raw value contains `_`.
Whole-tree, not diff-scoped: the hazard appears when a DECODER elsewhere in the file gains the
strategy, and that commit may touch no `CodingKeys` at all.

**Must-NOT-flag** (all three exist in the tree today; the exclusion has to be structural, not
incidental):
- `OPDS2LinkRel` (`OPDS2AuthenticationDocument.swift:12`) — a link-relation enum, NOT a
  `CodingKey`, sitting in the same file as a `.convertFromSnakeCase` decoder.
- `TPPProblemDocument.swift:41` — `static let DetailLoanTermLimitReached =
  "loan_term_limit_reached"`, a legitimate snake_case string constant, not an enum case.
- Non-`CodingKey` snake_case enums: `FirebaseManager.swift:82-92`,
  `AppLaunchTracker.swift:16-19`, `PerformanceMetric.swift:14-20`.

**Known limitation to carry forward:** the strategy↔type correlation is established SAME-FILE.
All three production types using `.convertFromSnakeCase` today configure the decoder in the same
file as the type. A type decoded by a strategy-setting decoder in a DIFFERENT file is not
detected. Put this in the script's docstring.

**Trap the first implementation fell into — do not repeat it.** Brace-depth tracking must record
the enum's body depth as `depth + 1` (i.e. AFTER the declaration line's `{`). Recording it before
makes the exit test never fire at the enum's own closing brace, so the scan window runs to the end
of the ENCLOSING type and flags every snake_case enum case that merely FOLLOWS a `CodingKeys`
block — which is exactly the `OPDS2LinkRel` shape the rule promises to exclude. Blast-radius
review caught this by reproducing a false positive against `TPPProblemDocument.swift` itself.
**A fixture with no `CodingKeys` enum cannot catch it**, because the discriminating path is never
entered; the regression fixture must contain BOTH a `CodingKeys` block AND a following wire enum.

**Severity: high.** The failure is silent by construction — no throw, no crash, no log — and it
passes any test that only asserts "the document decoded". It is also the instinctive fix for a
*different* bug, so it is most likely to be written by someone actively trying to be careful.

**Scan at landing: zero survivors.** Exactly three production types use `.convertFromSnakeCase`
(`TPPProblemDocument`, `TokenResponse`, `OPDS2AuthenticationDocument`) and none declares a
snake_case `CodingKey` raw value. The class is empty precisely because nobody had yet had reason
to write the obvious fix — the argument FOR the wall, not against it.

**Implementation already written.** The full detector, its 14-case pytest, ten fixtures (including
the regression fixture above), and the wiring are preserved on local branch
`pp5202-snakecase-codingkeys-detector`. The follow-up PR should start there rather than from
scratch, but should re-review it — it is not code that has been through CI.

## Related prior wall — the same room, a different door

`scripts/check-nserror-problemdoc-preservation.py` already exists, built after PP-3956 / PR #935,
for the case where an `NSError` re-wrap DROPS the problem document and `userFacingSignInError`
falls back to "Invalid Credentials". **That is the identical end-user harm as this bug**, reached
by a different mechanism: there the document existed and was discarded downstream; here the
document never got constructed. A reviewer investigating a future "sign-in says the password is
wrong but shouldn't" report should check BOTH walls — and anyone adding a third path to losing
the document should expect to add a third detector.

## Second-order lesson — a criterion is code, and untested code is wrong

The fix-contract for this change was BLOCKED three times by the architect-reviewer, for six
findings. Five of the six were not wrong *conclusions* — they were verification criteria that
would have failed a CORRECT implementation, or prescriptions no implementation could satisfy:

- an `encode(to:)` requirement that contradicted the contract's own anti-underscore criterion,
  and whose snake_case output would have broken the plain-decoder round trip pinned at
  `TPPBookLocationTests.swift:451`;
- `grep -c 'case showTitle'`, which returns 0 against the idiomatic comma-separated case list;
- a `Log.warn` requirement built on `try?`, which erases the very distinction the log needs;
- a log-assertion criterion that no honest test could meet, because `Log`'s only observable
  seam is compiled out on the simulator in Debug;
- `grep -c 'try?' == 0`, file-scoped, which the file's two pre-existing legitimate `try?` uses
  make permanently unsatisfiable.

**None was visible by inspection. Every one surfaced by RUNNING the criterion against a
compiled mock.** A verification criterion is executable code with no test of its own; treat a
contract's greps as something to run before the implementation exists, not as prose.

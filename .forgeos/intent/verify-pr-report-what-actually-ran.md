---
name: verify-pr-report-what-actually-ran
created: 2026-08-14
author: claude-opus-5
type: bugfix
---

**ADR refs:** none. The green-board contract in `CLAUDE.md` ("CI/CD reliability")
is the governing text; this change enforces two of its existing rules rather than
proposing a new policy.

## Summary

Two remedy gaps left open by #1379, and the reporting defects in `verify-pr.sh`
that let them look closed.

The triage-bot half: a patron already on the newest build had no honest answer to
an "update the app" rung, so the trace recorded an attempt that never happened;
and the step telling patrons to delete and re-fetch a title carried no remedy
tag, which kept it out of the destructive-remedy safety rules entirely.

The tooling half: the unit-test gate scraped a stdout rollup that does not exist
under parallel-clone execution, and `--diff-baseline` could not extract class
names from any real xcresult, so its flake triage never ran.

## Reproduction

Tally: run `scripts/verify-pr.sh --quick` three times on an unchanged tree. It
reported `2815 tests, 1 failures`, `4786 tests, 1 failures` and `0 tests, 0
failures`, while the corresponding xcresults held 8246/7, 8250/5 and a full
green. One earlier run was recorded `[PASS]` with 3 failures in its xcresult.

Class extraction: `--diff-baseline` printed no re-run line on any run, because
its walker returned an empty list.

Blast radius: a PR with 27 findings displayed 3; fixing those three produced a
second red naming three more.

Trace: answer a ladder's update rung with the only available "No change" button
while already current, and the emitted `ResolutionTrace` contains a
`did_not_resolve` attempt for a step the patron never performed.

## Root cause

`xcodebuild` emits `Test Suite 'All tests' passed` + `Executed N tests` only in
serial mode. Under parallel clones — how CI and `xcode-test-optimized.sh` both
run — it emits per-test-case lines instead, so the scrape matched partially or
not at all.

The `--diff-baseline` walker treated a failed test case as a leaf node. A failed
case is not a leaf: its children are `Failure Message` nodes carrying the
assertion text, so the one node type being searched for was the one type
systematically excluded.

`StepAttempt.Outcome` had no value meaning "this did not apply to me", so the
only route onward from a non-applicable step recorded a failure.

`CatalogValidator` inspects `step.remedy`; an untagged step is invisible to it,
so KI-2026-007's delete-and-redownload was exempt from the destructive rules
while destroying content.

## Verification

- `scripts/tests/test_xcresult_summary.py` — 9 tests, fixtures transcribed from a
  real xcresult rather than assumed.
- Extractor run against a real bundle that previously yielded nothing: now names
  `NotificationServiceTokenTests`.
- End-to-end dry run: `--diff-baseline` fired for the first time — "re-running 5
  failed class(es) in isolation" — and correctly resolved them to flakes.
- TriageBotCore `swift test` 390/390; full `Palace` iOS build succeeded;
  `TriageBotUI` clean-built (82 compile tasks).
- Guards proved by reintroducing each defect, each producing a NAMED failing
  test; removing the new `GuidedStepCard` case fails the iOS build while
  `swift test` stays green.

## Claims

- The unit-test tally reported by `verify-pr` equals the xcresult's counts.
- `--diff-baseline` extracts failing class names from real xcresults and re-runs
  them in isolation.
- Every blast-radius finding is reported, with a count.
- A timeout or runner restart fails the gate even when counts read clean.
- A patron reporting a step does not apply advances without a failed attempt
  being recorded against that rung.
- A step that deletes downloaded content is subject to the destructive-remedy
  rules.

## Anti-claims

- Does NOT make any gate more permissive. A class that cannot be re-run counts as
  a real failure, because `-only-testing` silently ignores unknown selectors and
  still prints `** TEST SUCCEEDED **`.
- Does NOT audit `xcode-test-optimized.sh`, which has its own stdout parsing.
- Does NOT fix `pre-push-test-gate`, which derives no test classes for SPM
  package changes.
- Does NOT let the bot tell a patron a fix is coming: `waitForFix` is still
  referenced by no catalog entry.
- Does NOT change KI-2026-002 or KI-2026-005, whose update rungs have the same
  non-attempt problem but need `escalate` semantics, not `advance`.
- Claims nothing about whether the flakes re-run in isolation are themselves
  fixed. They are diagnosed, not repaired.

## Files in scope

- `scripts/verify-pr.sh` — tally source, pinned result bundle, finding output,
  timeout detection.
- `scripts/xcresult_summary.py` — new shared extractor.
- `scripts/tests/test_xcresult_summary.py` — its tests.
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBStep.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/ConversationState.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Reducer/ConversationReducer.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/RemedyDetector.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/KB/CatalogValidator.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/GuidedStepCard.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json`
- `Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/UpdateRungAlreadyCurrentTests.swift`
- `Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/RedownloadTitleRemedyTests.swift`

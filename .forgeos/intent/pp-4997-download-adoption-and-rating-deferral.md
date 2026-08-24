---
name: pp-4997-download-adoption-and-rating-deferral
created: 2026-08-21
author: claude-opus-5
type: bugfix
---

**ADR refs:** none — this repo has no `docs/adr/`. Governing texts are the INV-4
ownership contract stated in `DownloadTaskPersistence.swift`, the green-board
contract in `CLAUDE.md`, and the freeze in `scripts/godclass-loc-baseline.txt`.

**Jira:** PP-4997 (download adoption), PP-5020 (rating deferral), PP-4976
(pre-PR verification reporting green on checks it declined to run — partly
closed here), PP-5023 (unpersisted download tasks — filed from this work, not
fixed here).

## Claims

- A persisted download record is adopted only by a live task fetching the SAME
  URL, and the adoption carries that live task's identifier rather than the
  persisted one.
- Two persisted records claiming one download URL are both refused adoption.
- The rating deferral budget is restored for every positive moment, and a
  sleeping re-arm hop cannot overwrite a newer trigger's reset.
- `verify-pr.sh` records `skip`, never `pass`, for a leg that did not run, and a
  leg that never executes at all is reported as an accounting failure.
- Every bash test under `scripts/tests/` is invoked by a workflow, and absence
  of a tracked test file fails the job rather than skipping it.
- Every script and workflow named in a tracked doc either resolves, or is
  recorded in `scripts/doc-references-baseline.json`.

## Anti-claims

- The contested-URL guard is NOT free, and the cost is not only PP-5023. It runs
  BEFORE `adoptableTask`, so two records sharing a URL are both refused even in
  the sub-case where identifiers survived and the exact branch would have been
  right for each. Versus develop, that case goes from correct adoption to both
  restarting. The trade is deliberate — "identifiers survived" is precisely the
  assumption this fix declines to make, and a retry is cheaper than delivering
  the wrong book — but a reader of PP-5023 should not infer the guard is free.
- This does NOT make adoption safe when a live task exists with no persisted
  record. `contestedURLs` is computed from persisted records only, so a live
  unpersisted task on another book's URL is invisible to it and that book's
  record will adopt it. That is a wrong adoption, not a decline. Root fix is
  PP-5023; the exposure is stated in-source rather than papered over.
- This does NOT verify anything on a device. Simulator only.
- This does NOT prove `URLSessionTask.taskIdentifier` behaviour across a
  relaunch. The fix is deliberately agnostic to it.
- This does NOT close PP-4976. Audiobook path classification, submodule
  visibility, and the quick-mode scope question are untouched.
- This does NOT repair the 53 baselined dangling doc references; it bounds them.
- The `capture` argument binding is NOT covered and cannot be — a task built
  from a URL reports the same value for both requests. The mutation run reports
  those lines uncovered rather than counting them.

## Files in scope

- `Palace/MyBooks/DownloadTaskPersistence.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/AppRating/RatingPromptPresenter.swift`
- `PalaceTests/MyBooks/DownloadReconciliationTests.swift`
- `PalaceTests/MyBooks/LiveDownloadTaskBoxTests.swift`
- `PalaceTests/MyBooks/DownloadReconciliationLaunchOrderContractTests.swift`
- `PalaceTests/Decomp/BackgroundReconciliationContractTests.swift`
- `PalaceTests/AppRating/RatingPromptPresenterTests.swift`
- `scripts/verify-pr.sh`
- `scripts/check-doc-references-resolve.py`, `scripts/doc-references-baseline.json`
- `scripts/tests/` — doc-reference pytests, the ratchet-aggregation behaviour
  harness, the wiring tests, and the anti-orphan gate
- `.github/workflows/tooling-checks.yml`
- `scripts/godclass-loc-baseline.txt`, `scripts/README.md`, `CONTRIBUTING.md`,
  `scripts/coverage-exclude.json`, `.github/PULL_REQUEST_TEMPLATE.md`,
  `docs/regression-suite/DESIGN.md`, `docs/Testing/3.3.0-REGRESSION-PLAN.md`

## Reproduction

PP-4997 is source-verified rather than observed: `reconcile` compared only
`record.taskIdentifier` against the live set, while the record already carried
the download URL that distinguishes them. Two people read it independently and
reached the same conclusion.

PP-5020 reproduces in a unit test: drive a trigger with a modal presented, let
the budget exhaust, drive a second trigger. Before the fix the second is dropped
on entry, permanently.

The reporting defects reproduce by reading the script: 60 `record … "pass"`
calls whose own detail string began "Skipped".

## Root cause

**PP-4997.** `URLSessionTask.taskIdentifier` is unique only within a session. A
relaunch starts a new session and renumbers from 1, so a leftover record for
task 1 matched a different book's live task 1. The discriminating field — the
download URL — was on the record and never read.

**PP-5020.** The deferral budget was restored only on the code path that showed
the gate. A positive moment that was fully occluded therefore consumed the
budget and never replenished it, leaving the counter latched at zero for the
life of the presenter.

**The reporting defects.** `record()` had two outcomes, pass and fail, so a leg
that declined to run had no way to say so and reported the only non-failing
value available.

## Verification

Every fix was confirmed by reintroducing the defect and requiring a NAMED
failing test, not by the suite passing.

Mutation on the changed lines of `DownloadTaskPersistence.swift`
(`palace_mutate.py --diff-only`): 6 killed, 0 survived, 0 errored, 1 uncovered.
The first run of this reported 4 killed / 1 errored / 2 uncovered because it
named only one test class; a reviewer pointed out that `LiveDownloadTaskBoxTests`
covers two of those lines, so the gap was a test-selection artifact and not a
real one. The single remaining uncovered line is the `return false` arm that
cannot be reached through `URLSessionDownloadTask` at all. Rating: four mutants —
latch, clobber, decrement removed, budget guard removed — each killed by a named
test, re-run after the `armHop` extraction.

The rating clobber test needed four attempts. Three passed against the live
defect: two never reached the cell they named, and one depended on winning a
~30ms race that a reviewer measured it losing 10 times in 12. It now injects a
clock and drives both wake orders; the mutant dies 12/12.

The ratchet-wiring check needed two. The first asserted by grepping the script's
own source; two reviewers between them walked through it seven ways, each
leaving every searched-for string intact while making the branch unreachable.
The replacement lifts the block, stubs its inputs, and asserts the recorded
outcome: 7/7 versus 0/7. A third attack class — disabling the whole section so
it records nothing — is caught by the expected-key manifest, which fails the run
when a leg reports neither pass, fail, nor skip.

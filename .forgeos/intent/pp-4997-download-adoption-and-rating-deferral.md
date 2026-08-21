---
name: pp-4997-download-adoption-and-rating-deferral
created: 2026-08-21
author: claude-opus-5
type: bugfix
---

**ADR refs:** none — this repo has no `docs/adr/`. The governing texts are the
INV-4 ownership contract stated in `DownloadTaskPersistence.swift`, the
green-board contract in `CLAUDE.md`, and the god-class freeze recorded in
`scripts/godclass-loc-baseline.txt`.

**Jira:** PP-4997 (download adoption), PP-5020 (rating deferral), PP-4976
(pre-PR verification reporting green on checks it declined to run — partly
closed here).

## Summary

Two patron-visible defects and a set of gates that were reporting work they had
not done.

**PP-4997.** A background download that outlived the app was re-attached to a
book on `taskIdentifier` alone. That number is unique only within one session,
so after a relaunch a leftover record for task 1 could match a different book's
live task 1, and the finished file was delivered to a title the patron never
asked for. Silent: no error, no alert, no log line.

**PP-5020.** The rating gate defers when a sheet would cover it, but the
deferral budget was only restored on the path that actually showed the gate. A
patron whose first positive moment was fully occluded left the counter at zero
and the app stopped asking permanently, without ever spending the lifetime cap
it was protecting.

**PP-4976 (partial).** `verify-pr.sh` recorded `pass` for 60 checks whose own
detail line said they had been skipped, and `skip_count` never reached the main
summary or the main JSON report.

## Reproduction

PP-4997 is source-verified rather than observed: `reconcile` compared only
`record.taskIdentifier` against the live set, and the record already carried the
download URL that distinguishes the two. Two people read it independently and
reached the same conclusion.

PP-5020 reproduces in a unit test: drive a trigger with a modal presented, let
the budget exhaust, then drive a second trigger. Before the fix the second is
dropped on entry.

The reporting defects reproduce by reading the script: 60 `record … "pass"`
calls whose detail string begins "Skipped".

## What changed

- Adoption matches on the download URL and carries the LIVE task's identifier,
  so it is correct whether or not identifiers survive a relaunch — a question
  two reviewers disagreed about and nobody had settled on device.
- Records whose URL is claimed by more than one book are refused rather than
  guessed at. Three reviewers found this cell independently; it is PP-4997's own
  symptom re-entered through its fix, because `taskIdentifierToBook` is
  last-write-wins.
- The rating budget is restored per trigger, and a sleeping re-arm hop no longer
  writes its stale count over a newer trigger's reset.
- `LiveDownloadTaskBox` moved to `DownloadTaskPersistence.swift` with a
  `capture(_:)` method. Carrying URLs grew the hub 7 lines past its freeze; the
  ratchet asks for extraction rather than a raised baseline, and extraction net
  **-1** (baseline ratcheted 1250 → 1249).
- All 60 unrun `verify-pr.sh` legs record `skip`; the count reaches both
  summaries and both JSON emitters; a MISSING ratchet is reported instead of
  being stepped past and counted as "at or under baseline".
- New `check-doc-references-resolve.py` + baseline + CI wiring, because the
  coverage summary had been telling reviewers that excluded paths were "covered
  by simdrive E2E journeys (see `chaos-replay-on-pr.yml`)" — a workflow that does
  not exist, for a corpus with zero tracked files.

## Verification

Every fix was confirmed by reintroducing the defect and requiring a NAMED
failing test, not by the suite passing.

The rating clobber test needed four attempts. Three passed against the live
defect: two never reached the cell they named, and one depended on winning a
~30ms race that a reviewer measured it losing 10 times in 12. It now injects a
clock and drives both wake orders; the mutant dies 12/12.

The ratchet-wiring check needed two. The first asserted the aggregation by
grepping the script's own source; two reviewers between them walked through it
seven ways, each leaving every searched-for string intact while making the
branch unreachable — including piping into `head` and reading the wrong exit
status, a trap already written down in this repo. The replacement lifts the
block, stubs `record` and the ratchets, and asserts the recorded outcome. It
catches all seven; the grep version caught none.

**Not done:** on-device verification — simulator only. `.restart` being inert
for a `.downloading` book is pre-existing and wants its own ticket. The full
suite has one failure, `BookSignInRedirectHandlerTests.testHandleProblem_alreadySAMLStarted_setsFailedAndPresentsReauthModal`,
which passes in isolation and has been failing intermittently on five unrelated
branches since 19 August with retry reporting those runs green — recorded
against PP-4991, not caused here.

**Deferred:** `taskDescription` carrying the book id would be an exact
discriminator and make the collision guard unnecessary; nothing sets it today.
The 24 baselined dangling doc references are recorded, not repaired.

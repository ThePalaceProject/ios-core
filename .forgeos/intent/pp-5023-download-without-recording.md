---
name: pp-5023-download-without-recording
created: 2026-08-26
author: claude-opus-5
type: bugfix
---

**ADR refs:** none — this repo has no `docs/adr/`. The governing text is the
INV-4 ownership contract stated in `DownloadTaskPersistence.swift`, together
with the credential-isolation boundary documented at
`BackgroundDownloadHandler.startedForAccount` (PP-4978 / PP-4020 / F-034).

**Jira:** PP-5023. Filed from the PP-4997 review, which closed the identifier
collision and named this residue in-source rather than papering over it.

## Claims

- Every path that starts a `URLSessionDownloadTask` in the download centre's
  session writes a durable `PersistedDownloadRecord` for it. The two that did
  not — `BackgroundDownloadHandler.followAcquisitionLink` and the
  `.simplifiedBearerTokenJSON` hop in `RightsManagementDispatcher` — now do.
- A download started through the acquisition-link path cannot be adopted by a
  different book whose record names the same URL. It is now visible to
  `reconcile`'s contested-URL guard, which refuses both claimants.
- A re-issued task PRESERVES the account its download started under. It is
  carried forward from the existing record, never restamped from the current
  account.
- With no record to carry an account from, the re-issue writes an EMPTY account.
  `startedForAccount` already degrades an empty id to today's account, so that
  arm reproduces current behaviour exactly.
- When `followAcquisitionLink` re-registers under a book whose identifier differs
  from the original's, the account crosses to the new record and the superseded
  record is removed rather than left naming a dead task.
- **A record written by a mid-flight re-issue SURVIVES the caller's terminal
  cleanup.** `handleDownloadCompletion` retires a book's record when a download
  reaches a terminal outcome; a bearer hop has not reached one, because it has
  just started a new content task. Without this the bearer half of the fix was
  inert — the record was written and removed roughly 100ms later.
- A completion with NO follow-up task still retires its record, so finished
  downloads do not accumulate records forever.
- **A re-issue's read-modify-write is atomic under ONE lock acquisition.**
  Deriving a new record from the existing one via `all()` then `record()` takes
  the lock twice, and a concurrent `remove` landing between them resurrects the
  record it deleted. `DownloadTaskPersistence.upsert` closes that window.

## Anti-claims

- This does NOT make the contested-URL guard complete as a property of
  `reconcile`. Completeness is a property of the CALLERS — every future path that
  starts a download must persist, and nothing in `DownloadTaskPersistence` can
  enforce that. The invariant is stated in-source and pinned by
  `DownloadReissuePersistenceTests`; it is not mechanically guarded.
- `upsert` does NOT enforce that `transform` returns a record for `bookID`; that
  is a documented caller contract. An earlier version enforced it by deleting both
  keys, but the two are identical for every reachable input, so the clause was an
  unkillable mutant on a critical path — worse to carry than a stated
  precondition. No caller can produce the violating case.
- This does NOT change the REST of the terminal cleanup for a bearer hop. The
  same block still removes `bookIdentifierToDownloadInfo` and calls
  `registerCompletion` for a download that has only just started. That is
  PRE-EXISTING behaviour, a larger change than this ticket, and is documented
  in-source rather than silently widened.
- This does NOT fix the transfer-retry account overwrite. `reissueTransferDownloadTask`
  still routes through `persistStartedTaskRecord`, which stamps the current
  account, so a retry after a library switch still overwrites the captured one.
  That is PP-4978's documented bound, deliberately left.
- This does NOT reproduce the defect against a real catalogue. The measurement in
  the ticket — 100 entries, 400 acquisition links, 200 distinct addresses, none
  shared between works — says the collision is not reachable by browsing. The fix
  is reasoned from the data model, which does not prevent it, and the tests carry
  a CONTROL that demonstrates the wrong adoption when a live task has no record.
- This does NOT verify anything on a device, or against a real Findaway /
  OverDrive / bearer-token server. Simulator and unit tests only.
- This does NOT change WHEN a download is started, retried, or cancelled. It only
  changes what is written down when one starts.
- Neither `RightsManagementDispatcher` nor `DownloadStateManager` has any
  mutation point on its changed lines — both are straight-line construction with
  no comparison, boolean, or return operator, so `palace_mutate` can say nothing
  about them. The dispatcher's guard was proven instead by deleting the
  `persistReissuedTask` call and observing `testBearerTokenHop_persistsTheTaskItStarts`
  fail BY NAME, then restoring. Recorded as hand-verification, never folded into a
  kill count.
- One mutant was deliberately ELIMINATED rather than killed. `if existing == nil {
  Log… }` is a comparison whose only consequence is a log line, so no assertion can
  distinguish it and it would sit forever as an unkillable critical-path survivor.
  It is now a coalesce that logs in its else-branch: same diagnostic, no untestable
  branch. That is preferred over both a coverage-only test and deleting a log that
  is the only signal a re-issue lost its provenance.

## Files in scope

DERIVED from `git diff $(git merge-base HEAD origin/develop) HEAD --name-only`, not
hand-maintained. Three consecutive review rounds blocked on this section being
wrong — each time a file was added to the diff and not to the list, and each time
only the file the reviewer named was added back. Listing the annotations by hand
is fine; deriving WHICH files appear is what stops the drift.

That command returns NINE paths; the list below has eight. The ninth is this
document, excluded because a scope list naming itself is noise. Said explicitly
because otherwise a reviewer re-running the stated command finds 9 against 8 and
has to work out which is missing — which is exactly the friction the derivation
exists to remove. Both reviewers hit it.

- `Palace.xcodeproj/project.pbxproj` — registers the new test file (PalaceTests target only)
- `Palace/MyBooks/BackgroundDownloadHandler.swift` — BEHAVIOUR: `followAcquisitionLink` persists, inherits the account, drops the superseded record
- `Palace/MyBooks/DownloadStateManager.swift` — BEHAVIOUR: `persistReissuedTask`, the account-preserving re-issue write
- `Palace/MyBooks/DownloadTaskPersistence.swift` — BEHAVIOUR: gains `upsert(bookID:inheritingFrom:transform:)`, a single-lock read-modify-write (plus comment corrections)
- `Palace/MyBooks/MyBooksDownloadCenter+ChallengeAccount.swift` — comments only: the credential-resolver census said both re-issue paths write no record, which this changeset reverses
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — BEHAVIOUR: the terminal cleanup skips `removePersistedRecord` for a live follow-up (plus comment corrections)
- `Palace/MyBooks/RightsManagementDispatcher.swift` — BEHAVIOUR: the bearer-token hop persists and reports `followUpTaskInFlight`
- `PalaceTests/MyBooks/DownloadReissuePersistenceTests.swift` — the suite

## Reproduction

Source-verified, not observed, and the ticket says so. `reconcile` computes
`contestedURLs` from `persisted` alone; `adoptableTask` then matches a record
against `liveTasks` by URL and adopts when exactly one live task carries it. A
live task with no record is absent from `contestedURLs` and present in
`liveTasks`, so a record naming that URL sees one live task on it and adopts it.

`testControl_anUnrecordedTaskOnAnotherBooksURL_isAdopted` reproduces that
mechanically: one record, one live task on the same URL, no record for the task's
owner, and `reconcile` returns `.adopt`. That control passes both before and
after the fix — it is the defect, not the guard, and it exists so the
fix-asserting test cannot pass for an unrelated reason.

## Root cause

`persistStartedTaskRecord` was only ever called from `addDownloadTask` and the
transfer-retry re-issue. The two mid-flight re-issue paths registered their new
task in the in-memory maps (`bookIdentifierToDownloadInfo`, `taskIdentifierToBook`)
and resumed it, but wrote nothing durable — so the hot maps and the durable store
disagreed about which tasks existed, and reconciliation reads only the durable
store.

The account field is the reason the fix is not simply "call the existing method".
That method stamps `accountScope.currentAccountID` and `DownloadTaskPersistence.record`
upserts by book id, so calling it on a re-issue would overwrite the account the
download started under — the exact field `startedForAccount` reads to choose which
library's bearer token the NEXT re-issue carries. Closing PP-5023 through it would
have opened PP-4978.

## Verification

TDD, red first. **Measured against an unmodified `origin/develop` tree** (a
throwaway worktree carrying only the final test file), not estimated:

    Executed 8 tests, with 10 failures

Seven of the eight fail; the eighth is the control, which passes there and here
because it asserts the DEFECT. **That baseline covers 8 of the 15 tests now in the
file.** Seven were added later in response to review — the two `followUpTaskInFlight`
arms, the two caller-level `handleDownloadCompletion` tests, and the two
inheritance-cell tests — and are pinned as follows — stated here rather
than promised, since an earlier draft said "recorded below" and recorded nothing:

  * `testBearerTokenHop_reportsALiveFollowUpTask…` and
    `testHandleDownloadCompletion_bearerHop_keepsTheRecordForTheLiveTask` — deleting
    `if !followUpTaskInFlight` makes the second fail BY NAME. Run twice: when the
    guard landed, and again after the fixture's Content-Type changed, because
    altering a fixture invalidates the proof that used it.
  * `testReissue_whenTheSourceHasNoRecordButTheTargetDoes…` and
    `testReissue_whenNeitherSourceNorTargetHasARecord…` — written to kill a MUTATION
    SURVIVOR (`DownloadTaskPersistence`'s target-record fallback, which survived
    until they existed). Mutation is their evidence, not a hand check.
  * `testHandleDownloadCompletion_opdsFollowUp_keepsTheRecordForTheLiveTask` — the
    acquisition-link half, which is guarded by `case .followUpStarted: return`
    short-circuiting before the terminal cleanup rather than by the bearer half's
    flag. Rewriting that arm to fall through makes it fail BY NAME. Its OPDS entry
    carries the SAME id as the original book on purpose: an id-changing follow-up
    records under the new id while the cleanup deletes the old one, so it survives
    a fall-through by accident and cannot detect the regression.
  * `testNonFollowUpDispatch_reportsNoLiveTask` and
    `testHandleDownloadCompletion_withoutAFollowUp_stillRetiresTheRecord` — controls.
    Their evidence is that they assert the OPPOSITE of the arms above and pass, so a
    flag wedged true (which would leak a record on every finished download) fails
    them. They are not independent behaviour pins and are not claimed as such.

Saying "all ten pass" here, as an earlier draft did, was itself the stale-figure
error this section warns about.

Two further tests
(`testBearerTokenHop_reportsALiveFollowUpTask_soTheCallerKeepsTheRecord` and
`testNonFollowUpDispatch_reportsNoLiveTask`) cannot be measured that way at all:
they assert `RightsManagementDispatchResult.followUpTaskInFlight`, which does not
exist on develop, so they fail to COMPILE — red by construction rather than by
assertion. All fifteen pass after the change.

An earlier version of this section said "five of seven". That was wrong and the
error is worth naming: it was recorded from a run against a tree that had already
been partly modified, and one test in it passed vacuously and was strengthened
afterwards. A red-first figure taken from anything but the committed baseline is
not a measurement.

One of the seven initially passed vacuously and was strengthened rather than
kept: `testFollowAcquisitionLink_preservesTheAccountTheDownloadStartedUnder` was
satisfied by the seeded record still carrying the right account simply because
nothing had rewritten it — the pre-fix state. It now also pins the record to the
NEW task's identifier and URL, so it can only pass once the path actually writes
one.

Mutation, `--diff-only` against `origin/develop`, re-measured on the final tip
with `--no-cache` (see the caveat below — this matters):

- `Palace/MyBooks/DownloadTaskPersistence.swift` — 3 points, **3 killed (100%)**
- `Palace/MyBooks/BackgroundDownloadHandler.swift` — 1 point, **1 killed (100%)**
- `Palace/MyBooks/DownloadStateManager.swift` — **0 points discovered**
- `Palace/MyBooks/RightsManagementDispatcher.swift` — **0 points discovered**
- `MyBooksDownloadCenter+ChallengeAccount.swift` — no points on changed lines
  (comment-only changes)
- `MyBooksDownloadCenter.swift` — no points on changed lines, and NOT because the
  change is comment-only. It carries `if !followUpTaskInFlight`, the guard that
  keeps a live download's record, and a bare `if` on a Bool offers no operator for
  `palace_mutate` to flip. Pinned by direct verification instead: deleting the
  guard makes `testHandleDownloadCompletion_bearerHop_keepsTheRecordForTheLiveTask`
  fail by name. Done twice — once when the guard landed, and again after the test
  fixture's Content-Type changed, since altering a fixture invalidates the proof
  that used it.

Re-measured again at the round-3 tip after the `upsert` delete predicate changed:
`DownloadTaskPersistence` 3 points, 3 killed. That run needed an ISOLATED
`PALACE_MUTATE_DERIVED_DATA_PATH` — a parallel toolkit test run had written into
the shared DerivedData, invalidating the precompiled header, and the mutation
BASELINE then failed. A failing baseline measures nothing; it is not a result in
either direction, and CLAUDE.md's "a build failure is not a kill" applies to the
baseline as much as to a mutant.

**The cached run lied, in the direction that matters.** A cached pass reported
`DownloadTaskPersistence` at 2 killed / 1 survived on a tip where the survivor was
already dead. `palace_mutate`'s cache key is derived from the PRODUCTION file, so
adding, changing or deleting tests does not invalidate it. Here that produced a
false RED, which is harmless. The same mechanism produces a false GREEN whenever a
test is weakened or removed without the production file changing — a cached
"killed" replayed against a suite that no longer kills it. Re-measure with
`--no-cache` before trusting any mutation figure quoted alongside a test change.

The third is the honest gap and is recorded as one rather than counted as a pass.
A straight-line call has no operator to flip, so `palace_mutate` can say nothing
about it. Its guard was verified by hand instead: deleting the
`persistReissuedTask` call made
`testBearerTokenHop_persistsTheTaskItStarts` fail by name, and the call was then
restored. A green suite alone would not have shown that the test bites.

The control test is the second half of the same discipline. `reconcile` declining
to adopt could be caused by many things; the control fixes one live task and one
record on a shared URL with NO record for the task's owner and asserts `.adopt`
IS returned. So the fix-asserting test's `XCTAssertFalse` is known to be
falsifiable rather than merely satisfied.

Not verified: any device, any real server, any Findaway / OverDrive / bearer
fulfilment. Simulator and unit tests only, per the anti-claims above.

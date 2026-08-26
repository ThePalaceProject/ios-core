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

## Anti-claims

- This does NOT make the contested-URL guard complete as a property of
  `reconcile`. Completeness is a property of the CALLERS — every future path that
  starts a download must persist, and nothing in `DownloadTaskPersistence` can
  enforce that. The invariant is stated in-source and pinned by
  `DownloadReissuePersistenceTests`; it is not mechanically guarded.
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
- The `RightsManagementDispatcher` change has NO mutation points — it is a
  straight-line call with no comparison, boolean, or return operator, so
  `palace_mutate` reports nothing to kill there. Its guard was proven instead by
  deleting the call and observing the named test fail, which is recorded rather
  than folded into a kill count.

## Files in scope

- `Palace/MyBooks/DownloadStateManager.swift` — `persistReissuedTask`
- `Palace/MyBooks/BackgroundDownloadHandler.swift` — `followAcquisitionLink`
- `Palace/MyBooks/RightsManagementDispatcher.swift` — the bearer-token hop
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — comment only, no behaviour
- `Palace/MyBooks/DownloadTaskPersistence.swift` — comments only, no behaviour
- `PalaceTests/MyBooks/DownloadReissuePersistenceTests.swift`
- `Palace.xcodeproj/project.pbxproj` — registers the new test file

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

TDD, red first. Five of the seven tests in
`PalaceTests/MyBooks/DownloadReissuePersistenceTests.swift` failed against the
unmodified tree, each for the stated reason — no record written — and the sixth
was the control, which passed then and passes now because it asserts the DEFECT.
All seven pass after the change.

One of the seven initially passed vacuously and was strengthened rather than
kept: `testFollowAcquisitionLink_preservesTheAccountTheDownloadStartedUnder` was
satisfied by the seeded record still carrying the right account simply because
nothing had rewritten it — the pre-fix state. It now also pins the record to the
NEW task's identifier and URL, so it can only pass once the path actually writes
one.

Mutation, `--diff-only` against `origin/develop`:

- `Palace/MyBooks/DownloadStateManager.swift` — 1 point, 1 killed (100%)
- `Palace/MyBooks/BackgroundDownloadHandler.swift` — 1 point, 1 killed (100%)
- `Palace/MyBooks/RightsManagementDispatcher.swift` — **0 points discovered**

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

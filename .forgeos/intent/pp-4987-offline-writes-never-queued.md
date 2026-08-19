# PP-4987 — offline writes are never queued for retry

## Claims

- `TPPNetworkResponder` preserves the underlying transport error when a task
  produces no HTTP response, instead of replacing it with the generic
  `invalidOrNoHTTPResponse` (914).
- Because `NetworkQueue.StatusCodes` is composed entirely of `NSURLError`
  values, preserving that error is what makes `willQueueOffline` able to be
  true at all — so an offline write now actually reaches the retry queue.
- A write the queue fails to persist is reported under its own Crashlytics code
  (`offlineQueueWriteFailed`, 916) rather than being dropped in silence.
- `PP-4965`'s `.queuedForRetry` case becomes reachable in production, and its
  cross-device E2E tripwire flips from expected-failure to a real assertion.

## Anti-claims — things this change explicitly does NOT do

- **It does not change behaviour for requests that DID get an HTTP response.**
  Only the no-response branch is touched; every non-2xx still yields the
  synthesized 909 alongside the response, exactly as before.
- **It does not add retry logic.** The queue's existing drain/retry path is
  untouched; this only makes writes reach it.
- **It does not silence anything NEW at enqueue.** PP-4965's silence is paid
  for by the drop reports above, both of which now file under 916.

  CORRECTED (round 3): the DRAIN side is still silent. `retryQueue()` deletes
  rows past `MaxRetriesInQueue = 5` without reporting, `retry()` logs a non-2xx
  locally only, and both `migrate()` and `retryQueue()` keep a bare
  `guard let db else { return }`. A write that can never drain is as lost as
  one never stored. That path has never carried traffic before this ticket and
  has no behavioural coverage; it is a follow-up, not something this change
  fixes.

- **It does not predict the 902 bucket either, and there are TWO confounders.**
  Pre-change, the annotation caller passed `nil` as the error, so every failure
  filed 902 flatly. It now passes the underlying error, which routes through
  `customSummaryAndCode` and re-codes `notConnectedToInternet` / `timedOut` /
  `connectionLost` to `.clientSideTransientError`. So 902 falls for un-queued
  transients too, independently of queueing — and separately, a non-2xx with a
  problem-document body is reported TWICE (once by `parseAndLogError` as
  `.problemDocAvailable`, once by the annotation caller as 902). Group the
  re-measurement by `metadata.statusCode` rather than reading the total.

- **It does not predict the 914 bucket.** Expect 914 to COLLAPSE app-wide:
  transport failures that were filed under it now carry their real NSURLError
  and re-bucket through `customSummaryAndCode`. A near-zero 914 after this
  ships is the substitution ending, not a defect being fixed — the exact
  symmetric trap to the 902 re-measurement PP-4965 warns about.
- **It does not claim the 902 bucket will fall by a specific amount.** It should
  fall, because genuinely-queued writes stop being reported — but the remaining
  volume is the real defect worth sizing, and that measurement belongs after
  this lands, not in it.

## Blast radius — deliberately widened, and why

Preserving the error revives four call sites that match on `NSURLError` codes
and have been unreachable for anything routed through this responder:
`TPPAlertUtils` (:68, :72), `PalaceError` (:596, :598),
`TPPSignInBusinessLogic` (:688), `PalaceAuth.AuthReducer` (:264). Patrons who
are offline will now get the specific "you appear to be offline" handling those
sites were written to provide, instead of a generic failure. This is the
intended consequence, not a side effect — but it is a user-visible change on
the sign-in path and should be called out in review.

## Round 3 — hardening required before this could land

Review blocked this twice more, and two of the findings were about turning the
queue ON rather than about the fix itself:

- **The credential was about to reach disk.** Callers build headers from
  `TPPNetworkExecutor.request(for:)`, whose `useTokenIfAvailable` defaults to
  TRUE, so `Authorization: Bearer …` was archived into the unencrypted
  `simplified.db`. Never executed before, because nothing was ever queued —
  this ticket is what would have started it. Now stripped at enqueue
  (`headersSafeToPersist`) and re-derived at drain from the CURRENT credential,
  which also stops a days-old row replaying an expired token.

- **The queue key collapsed distinct writes.** `addRequest` UPDATEs the row for
  `(libraryID, updateID)` and every annotation passed `updateID = bookID`, so
  two offline bookmarks in one title silently overwrote each other — with
  PP-4965 having already removed the report for that path. Keyed on motivation
  now: positions still collapse on the book (a newer position SHOULD supersede
  an older one), bookmarks key on book + selector.

- **916 was applied to only one of the two drop paths.** The `catch` used the
  bare `logError(_:summary:metadata:)` overload, which hardcodes `code:
  .ignore` — filing under the raw SQLite code with `error_origin = unknown`.
  Byte-for-byte the defect round 1 blocked this branch for, reintroduced in new
  code, and caught by all three reviewers. Fixed and now tested.

## Blast radius — what review established

Preserving the error revives `TPPAlertUtils`, `PalaceError`,
`TPPSignInBusinessLogic` and `PalaceAuth.AuthReducer`. Independently traced:
all message-only, no sign-out, and `DownloadErrorRecovery`'s retry policies are
bounded (3 attempts / 25–120s), so no retry storm.

It does NOT reach borrow/return/loans-sync: `TPPOPDSFeed+Networking.swift:113`
erases the transport error into `problemDocument?.dictionaryValue` (nil when
offline), so `BookReturnService.isOfflineNSURLError` and the OPDS-side
consumers stay dead. That is a SECOND erasure chokepoint of the same shape as
this ticket's, and it is worth its own ticket.

## Round 4 — the credential fix had its own leak

Fixing the at-rest problem introduced a worse one in transit, caught by two
reviewers independently. The drain-time provider resolved
`currentUserAccount`, while `retryQueue` drains EVERY row regardless of
library and each row's URL is its own library's host. A patron who queued a
write for library A and then switched to library B would have sent B's bearer
token to A's server — a cross-tenant credential disclosure, plus a guaranteed
401 on a write that had a valid token sitting in the keychain. The provider is
now keyed on the row's `libraryID` and resolved through
`accountsManager.userAccount(for:)`, which is the API that exists precisely to
stop this (see the "prevent TOCTOU races during account switches … causing
cross-account credential leaks" note on `TPPNetworkExecutor`).

The strip itself was also proven only on the helper: `headersSafeToPersist` had
unit tests, but nothing asserted `addRequest` CALLS it, and unwiring the call
site left the whole suite green. The E2E assertion that claimed to cover it sat
UPSTREAM of the strip, asserting a property that is false in production, and
passed only because that suite's executor happens to hold no token on a clean
runner — it went red the moment a sibling test left one behind. Both are now
asserted against the persisted row via `persistedRowsForTesting()`.

No legacy rows can carry a stored credential: nothing was ever queued before
this ticket (`willQueueOffline` could not be true), and the only other entry
point, `enqueueOfflineRequest`, has no production caller. So no migration is
needed to purge them.

## Files in scope

- `Palace/Network/TPPNetworkResponder.swift`
- `Palace/Network/TPPNetworkQueue.swift`
- `Palace/Logging/TPPErrorLogger.swift`
- `PalaceTests/Network/NetworkQueueTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`

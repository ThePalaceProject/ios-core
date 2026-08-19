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
- **It does not silence anything.** The only new silence is PP-4965's, and it
  is now paid for by the drop report above.
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

## Files in scope

- `Palace/Network/TPPNetworkResponder.swift`
- `Palace/Network/TPPNetworkQueue.swift`
- `Palace/Logging/TPPErrorLogger.swift`
- `PalaceTests/Network/NetworkQueueTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`

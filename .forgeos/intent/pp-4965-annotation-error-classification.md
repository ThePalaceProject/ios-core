# PP-4965 — annotation error classification

## Claims

- `postAnnotation` distinguishes five outcomes that were previously one bare
  `false`: succeeded, queued-for-retry, and failed (carrying the transport
  error and/or the HTTP response).
- A write handed to the offline queue is no longer reported to error logging.
- A real failure keeps its Crashlytics code **902 (`.apiCall`)** and its
  `error_origin` classification, and now also carries the status code.
- Transient conditions (no connection, timeout) can be split into their own
  buckets by `customSummaryAndCode`, which needs the underlying error.

## Anti-claims — things this change explicitly does NOT do

- **It does not reduce the 902 volume.** `.queuedForRetry` is unreachable in
  production until PP-4987 preserves the transport error, so nothing is
  currently reclassified. Any re-measurement of the bucket before PP-4987 lands
  is meaningless.
- **It does not change bookmark behaviour.** Both `postBookmark` variants remain
  byte-for-byte equivalent, including the 200-with-no-id case. Their silence on
  failure is a separate gap.

  CORRECTION (review round 2): this holds for `postBookmark`, but NOT for
  audiobook bookmarks. `postAudiobookBookmark` routes through
  `postReadingPosition(motivation: .bookmark)` with `queueOffline: true` — the
  changed path — and has two live callers in `AudiobookBookmarkBusinessLogic`.
  So bookmark-motivated annotations ARE in the 902 bucket today and their
  telemetry DOES change here. The earlier claim that the bucket is "entirely
  reading positions" is false as written and must not be used to scope the
  post-PP-4987 re-measurement. Patron-visible behaviour is still unchanged
  today (nil in, throw out, before and after).
- **It does not verify the offline enqueue.** Suppressing the report assumes a
  retry exists; asserting that requires a seam and belongs to PP-4987, where the
  branch first becomes reachable. `NetworkQueue.addRequest` is fire-and-forget
  and drops a write silently on a nil DB connection or a throwing insert, so
  PP-4987 must add enqueue-failure reporting at the same time it makes the
  branch live — otherwise this change's suppression becomes a real silent loss.
- **It does not move the Crashlytics code or origin dimension.** Reviewers
  caught an earlier revision doing exactly that via the bare `logError`
  overload; a test now pins `.apiCall`.

## Files in scope

- `Palace/Reader2/Bookmarks/TPPAnnotations.swift`
- `Palace/Logging/ErrorLogging.swift`
- `PalaceTests/Bookmarks/TPPAnnotationsTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`
- `PalaceTests/Mocks/ErrorLoggerSpy.swift`

## Review round 2 — what changed and why

The first round approved a claim that was false in production. `postAnnotation`
passed `response: nil` on the error branch, and because `TPPNetworkResponder`
synthesizes an NSError for EVERY non-2xx while `TPPNetworkExecutor.POST`
forwards `(nil, response, error)` together, that error branch — not the `else`
below it — is the one a server refusal actually takes. So `metadata`
["statusCode"] was never populated, the `400...599` arm of
`TPPErrorOrigin.classify` was unreachable from this call site, and
`.failed(underlying: nil, response: <non-nil>)` was dead code.

Two tests asserted the working behaviour by stubbing `(nil, httpResponse(500),
nil)` — an error-free non-2xx, a shape the stack never emits. Fixtures now go
through `serverRefusal(_:)`, which builds the exact triple production delivers.

This is the same fixture-vs-production drift the branch had already fixed for
the 914 transport case and left in place on the server path.

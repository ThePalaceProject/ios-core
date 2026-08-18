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
- **It does not verify the offline enqueue.** Suppressing the report assumes a
  retry exists; asserting that requires a seam and belongs to PP-4987, where the
  branch first becomes reachable.
- **It does not move the Crashlytics code or origin dimension.** Reviewers
  caught an earlier revision doing exactly that via the bare `logError`
  overload; a test now pins `.apiCall`.

## Files in scope

- `Palace/Reader2/Bookmarks/TPPAnnotations.swift`
- `Palace/Logging/ErrorLogging.swift`
- `PalaceTests/Bookmarks/TPPAnnotationsTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`
- `PalaceTests/Mocks/ErrorLoggerSpy.swift`

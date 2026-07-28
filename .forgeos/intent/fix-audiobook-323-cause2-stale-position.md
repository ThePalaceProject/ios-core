# Intent — 3.2.3 Cause 2: stale audiobook server position

## Context
Regression from 3.2.0: a stale/invalid **server** listening position becomes
authoritative on audiobook open, and is never cleaned up on return
(HelpSpot #18468 / #18019 / #18449). Three defects, per
`.forgeos/changesets/fix-audiobook-323-cause2-stale-position/fix-contract.md`.

## Claims
- `TPPAnnotations.deleteAllBookmarks(forBook:)` also deletes the
  `.readingProgress` annotation (the listening position), not just `.bookmark`,
  scoped to the returned book — and it extracts the server annotation ID from
  BOTH `TPPReadiumBookmark` and `AudioBookmark` (the old `as? [TPPReadiumBookmark]`
  array cast silently dropped the audiobook listening position).
- `RemotePositionWriter.cancel(for:)` is wired into production: called on
  `AudiobookSessionManager.stopPlayback` and on the `BookReturnService` return
  path (before/alongside `deleteAllBookmarks`) — previously zero production callers.
- `AudiobookSessionManager` manifest-validates the REMOTE resolved position with
  the SAME `validationFailure(for:in:)` gate the local path uses: a remote track
  key absent from the loaded manifest drops to the safe fallback instead of
  seeking verbatim.

## Anti-claims (explicitly NOT touched)
- The download-gate / streaming path (Cause 1) — untouched.
- OverDrive `#if FEATURE_OVERDRIVE` re-fulfill recovery (Cause 3) — untouched.
- EPUB/PDF bookmark deletion semantics — unchanged (PDF bookmarks still not
  deleted on return, exactly as before).
- No dependency / Readium / ios-audiobooktoolkit streaming-source change.
- No new user-facing copy / alerts / UX.

## Files in scope
- `Palace/Reader2/Bookmarks/TPPAnnotations.swift`
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`
- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `Palace/Audiobooks/AudiobookSessionManaging.swift`
- `Palace/MyBooks/BookReturnService.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (production wiring of the canceller)
- Tests: `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`,
  `PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift`,
  `PalaceTests/Audiobooks/AudiobookPositionRestoreTests.swift`,
  `PalaceTests/MyBooks/BookReturnServiceTests.swift`,
  `PalaceTests/Contract/BookReturnServiceContractTests.swift`

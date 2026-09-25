---
name: bookmark-deletion-log-persist-outside-barrier
created: 2026-09-24
author: Maurice Carrier
branch: fix/test-reset-registry-and-bookmark-hang
priority: test-suite hang (bookmark tests wedge at 0% CPU); no ticket, direct fix
---

# Intent: the deletion log's UserDefaults write must not run under its queue barrier

## Context

Local full runs wedged in `updateLocalBookmarks` tests at 0% CPU. A 10 s
`sample` of the wedged host showed the main thread in
`TPPBookmarkDeletionLog.pendingDeletions` (`queue.sync`) and a worker inside a
`clearDeletion` barrier, in `saveToDisk` → `defaults.set` →
`_CFXNotificationPost` → `-[NSOperation waitUntilFinished]`. `UserDefaults.set`
posts `didChangeNotification` synchronously, and the post waits for any
observer registered on an operation queue; with an observer on the main queue,
the barrier waits for main while main waits for the barrier.

## Claims

- **A.** No barrier on `TPPBookmarkDeletionLog.queue` performs a
  `UserDefaults` write. Barriers mutate and encode; the write runs on a serial
  `persistenceQueue`.
- **B.** A reader (`pendingDeletions`) never waits for a `UserDefaults` write,
  and sees the committed mutation before it is persisted.
- **C.** Persisted state keeps mutation order: the write is enqueued from
  inside the barrier, so the last mutation's snapshot is the last write.
- **D.** The fix covers all three barrier writers (`logDeletion`,
  `clearDeletion`, `clearAllDeletions`) through the single `saveToDisk`.

## Anti-claims

- Does not change the in-memory API or its barrier/sync semantics.
- Does not identify which main-queue observer of the standard defaults' change
  notification exists in the test host; the fix does not depend on it.
- Does not make persistence synchronous with the mutating call. A caller that
  needs the write on disk must wait (tests use `_waitForPendingWritesForTesting`).

## Files in scope

- `Palace/Reader2/Bookmarks/TPPBookmarkDeletionLog.swift` — persistence queue (Claims A–D)
- `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift` — blocked-write reader test (B), reload/order test (C)
- `PalaceTests/PalaceTestSetup.swift` — built-in resetters re-registered at every boundary (separate strand, test-only)
- `PalaceTests/PalaceTestSetupObservationTests.swift`
- `PalaceTests/Support/SingletonResetRegistryTests.swift`

## Verification

- `testPendingDeletions_whilePersistenceIsBlocked_returnsWithoutWaitingForTheWrite`
  fails (`timedOut`) with the write moved back under the barrier, and passes
  with it outside.

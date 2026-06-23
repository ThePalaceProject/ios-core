---
name: pp4632-stop-returned-audiobook
created: 2026-06-23
author: Maurice Carrier
branch: fix/PP-4632-stop-returned-audiobook
priority: PP-4632 (High) / 3.2.0 RC regression
---

# Intent: stop the audiobook player when the playing book is returned

## Context

PP-4632 (3.2.0 build 481, High): an audiobook opened in the new player then
returned **keeps playing** when Play is pressed — the mini-player stays up and
the returned book plays until a new book is opened.

Root cause: `AudiobookSessionManager` holds the loaded audiobook in memory
(`currentBook` + manager/audiobook/tracks) and never observes the book registry.
The return flow (`BookReturnService.returnBook`) deletes local content, purges
audiobook caches, and transitions the registry to `.unregistered` — but nothing
tells the in-memory session to stop. The already-loaded tracks keep playing
(open file handles survive the on-disk deletion). Account-switch teardown is the
only existing stop-on-removal path (`cleanupActiveContentBeforeAccountSwitch`);
single-book return was never wired.

Grounded surface:
- The registry already publishes `bookStatePublisher: AnyPublisher<(String, TPPBookState), Never>`
  and emits `(id, .unregistered)` on `removeBook` / `updateAndRemoveBook` (the
  return path). `TPPBookRegistryProvider` (the manager's dependency) exposes it.
- `AudiobookSessionManager.stopPlayback(dismissPhoneUI:persistFinalPosition:)`
  already performs the full teardown (pause + unload + release decryptor + nil
  currentBook + dismiss phone UI).

## Claims

- `AudiobookSessionManager` subscribes to `bookRegistry.bookStatePublisher` in
  init (`subscribeToBookReturn`, alongside the existing
  `subscribeToPhoneSideErrorAlerts`, stored in `lifecycleCancellables`).
- When the change is for the **currently-playing** book and its state is
  `.unregistered`, it calls
  `stopPlayback(dismissPhoneUI: true, persistFinalPosition: false)` —
  `persistFinalPosition: false` so a stale live position is not written back
  into a possibly re-borrowed registry record (FINDING-D).
- The decision is a `nonisolated static`
  `shouldStopPlaybackOnRegistryChange(state:changedIdentifier:currentBookIdentifier:)`
  (mirrors `networkValidationError`) so it is unit-testable without a live
  session.

## Verification

- Unit: `AudiobookSessionStateTests` — 4 tests on the pure decision
  (current+unregistered → true; different book → false; non-unregistered → false;
  no current book → false). `AudiobookSessionManagerShutdownTests` re-run to
  confirm init (now wiring the new subscription) + stopPlayback are unaffected.
- Runtime (device, pending QA on RC 483): borrow audiobook → Listen → minimize →
  Pause → return from My Books → press Play in the mini-player → player closes and
  does not resume.

## Files in scope

- `Palace/Audiobooks/AudiobookSessionManager.swift` — `subscribeToBookReturn()` +
  `handleRegistryStateChange(...)` + `nonisolated static shouldStopPlaybackOnRegistryChange(...)`, called from init.
- `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` — 4 decision tests.
- `Palace.xcodeproj/project.pbxproj` — build 482 → 483 (separate release-chore commit).

## Anti-claims

- Does NOT change the return flow (`BookReturnService`), cache purge, or registry
  semantics — only adds an observer on the player side.
- Does NOT stop playback for non-current books or for non-`.unregistered`
  transitions (download progress, used, etc.).
- Does NOT alter account-switch teardown (already handled; nils `currentBook`
  first, so this observer no-ops during it).
- Does NOT claim runtime device verification — only the pure decision is
  unit-tested; the on-device return-while-playing pass is pending on RC 483.

---
name: pp-4542-cold-load-auto-reopen-recovery
created: 2026-06-16
author: Maurice Carrier
branch: fix/pp4542-audiobook-coldload
ticket: PP-4542
priority: 3.2.0 regression (critical-path, audiobook playback)
---

# Intent: cold-load auto-reopen guard for LCP audiobook first-open failure

## Context

Suite-missed 3.2.0 regression (Chairman repro'd on device; reproduced in
simdrive 2026-06-16 on "Valley of the Moms", Main Street City Library). First
cold-open of an LCP audiobook (fresh borrow → download → immediate first open)
fails with the "Audiobook Unavailable" alert and recovers only on a manual
re-tap. Root cause: the LCP-encrypted package isn't fully materialized when
playback begins, so `LCPResourceLoaderDelegate` reads a byte-range past the
archive's available extent and Readium 3.9.0 (PP-4340, ReadiumZIPFoundation
3.0.1) surfaces `Archive.ArchiveError.rangeOutOfBounds` — where pre-3.2.0
Readium tolerated the short read. The loader forwarded the hard error to the
AVPlayerItem (`AVFoundationErrorDomain -11800`), and `handleManagerState`'s
`.playbackFailed` cold-load branch turned it into a permanent alert.

Primary fix is in the toolkit (retry the transient range read). This app-side
change is the belt-and-suspenders guard for cold-load failures the toolkit
retry doesn't absorb, mirroring the bounded OverDrive re-fulfill recovery
([[ws3-overdrive-expired-url-refulfill]]).

Critical-path (audiobook playback). Toolkit-coupled — submodule pin moves in
lockstep.

## Claims

- Adds a pure boundary predicate
  `shouldAutoReopenOnColdLoadFailure(hasEverStartedPlayback:hasCurrentBook:alreadyAttempted:)`
  returning true iff playback NEVER started this session (a genuine cold load),
  there is a current book to reopen, and a reopen has not already been attempted
  for this book this session.
- Adds a cold-load auto-reopen branch in `.playbackFailed` (PARALLEL to, and
  after, the SAML and OverDrive branches): on the first cold-load failure,
  silently `openAudiobook(book, startPlaying: true)` ONCE before publishing any
  error or surfacing the alert. Bounded by `coldLoadReopenAttemptedBookIds`
  (reset on a fresh user-initiated open).
- A mid-playback failure (`hasEverStartedPlayback == true`) does NOT silently
  reopen — it falls through to the existing error/alert path unchanged.
- A persistent cold-load failure (second attempt) surfaces the existing
  "Audiobook Unavailable" alert instead of looping.
- Bumps the `ios-audiobooktoolkit` submodule pin to carry the toolkit-side
  resource-loader retry fix.

## Anti-claims

- Does NOT retry on warm/mid-playback failures or when there is no current book.
- Does NOT loop: bounded to one auto-reopen per book per session.
- Does NOT add or change user-facing copy (reuses the existing
  "Audiobook Unavailable" alert on exhaustion).
- Does NOT change the SAML-reauth or OverDrive re-fulfill branches, nor other
  vendors' playback paths.

## Files in scope

- `Palace/Audiobooks/AudiobookSessionManager.swift` (predicate + cold-load
  auto-reopen branch + `coldLoadReopenAttemptedBookIds` bound/reset)
- `ios-audiobooktoolkit` (submodule pin → toolkit resource-loader retry)
- Tests: `PalaceTests/Audiobook/AudiobookColdLoadRecoveryTests.swift`
- Toolkit tests: `PalaceAudiobookToolkitTests/LCPResourceLoaderColdLoadRetryTests.swift`

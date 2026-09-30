---
name: pp-5241-media-services-reset-recovery
created: 2026-09-24
author: Maurice Carrier
branch: fix/PP-5241-media-services-reset
priority: PP-5241 (critical-path: audiobook playback)
---

# Intent: recover an audiobook session after iOS resets its media services (-11819)

## Context

About a third of sampled "-11800" audiobook failures are AVError -11819
(`mediaServicesWereReset`): iOS restarted mediaserverd, which invalidates every
AVFoundation player and audio-session object. Neither the app nor the toolkit
observes `AVAudioSession.mediaServicesWereResetNotification`. The failure is
usually followed within ~1.3 s by an `OpenAccessPlayerError.playerNotReady`
failure from the same dead player, and the patron sees an error.

## Claims

- Observes `AVAudioSession.mediaServicesWereResetNotification` on an injected
  `NotificationCenter`.
- Treats a `.playbackFailed` whose error, or any error in its
  `NSUnderlyingErrorKey` chain, is AVFoundationErrorDomain -11819 as the same
  reset signal.
- The notification and the failure, in either order, start ONE recovery.
- While a recovery is in flight, further failures for that book are swallowed
  and the session stays `.loading`.
- A patron who was playing gets a recovery re-open through the existing
  `openAudiobook(isRecoveryReopen:)` path. That path re-applies the audio
  session category and activation, and restores the persisted position.
- A patron who was paused gets the dead session torn down without persisting
  its position. They are not re-opened paused, because the `startPlaying: false`
  bind path restores no position.
- One recovery per episode: after a successful recovery, another -11819 before
  playback begins falls through to today's handling.
- A failed recovery with the session still `.loading` publishes today's
  terminal `.error`.

- Exactly ONE Crashlytics record per reset episode: the first reset-shaped
  failure of the episode, whether it started the recovery or arrived after
  the notification did. A reset arrives in two encodings (top-level
  AVFoundation -11819, seen in 11 of 30 sampled events; or -11800 with -11819
  in `NSUnderlyingErrorKey`), and PP-5242's deduplicator keys on structure,
  so it treats those as two failures. Episode identity comes from the
  coordinator. A notification-only episode records nothing, because there is
  no error to record. Pinned by coordinator tests, including both encodings
  in one episode.
- The record is sent through the hub's `sendPlaybackFailureRecordIfNew`, the
  same PP-5242 path (`playbackFailureRecordToSend` with the stored
  deduplicator) the ordinary failure path uses. That wiring is read-verified:
  no test drives `handleManagerState`.
- Hub (`AudiobookSessionManager.swift`) stays inside its line-count ceiling,
  ratcheted 1213 -> 1206. The recovery host moved to
  `AudiobookSessionManager+MediaServicesReset.swift`, and two pure error
  mappers moved unchanged to `AudiobookSessionManager+ErrorMapping.swift` to
  pay for the hub's remaining plumbing.

- When a recovery starts, the session's last cached live position is saved
  BEFORE anything is torn down, once per episode. Without it the rebuild
  restores the last autosave, up to 15 s old (measured on a test iPhone with a
  synthetic reset notification: 958 s before, 948 s after). The player is not
  read: after a real reset it is dead.

## Anti-claims

- Does not change `buildPlaybackFailureRecord` / `recordPlaybackFailure`
  (PP-5242 owns them).
- Does not change any position-saving code (PP-4963/4964 own it). It CALLS
  the existing `saveLocation` once per recovery, with the session's cached
  position, before tearing down (see Claims).
- Does not change the toolkit.

## Files in scope

- Palace/Audiobooks/MediaServicesResetRecovery.swift (new)
- Palace/Audiobooks/AudiobookSessionManager.swift
- Palace/Audiobooks/AudiobookSessionManager+MediaServicesReset.swift (new)
- Palace/Audiobooks/AudiobookSessionManager+ErrorMapping.swift (new, relocation only)
- scripts/check-file-size-ceiling.sh, scripts/tests/test_check_file_size_ceiling.py (cap 1213 -> 1206)
- PalaceTests/Audiobooks/MediaServicesResetRecoveryTests.swift (new)
- Palace.xcodeproj/project.pbxproj

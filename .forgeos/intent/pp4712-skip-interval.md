# Intent: PP-4712 — patron-configurable audiobook skip intervals

**Routed:** /swarm (critical-path audiobook, 2 modules) · required gates: hygiene, stanza,
tdd_red_first, review:SoD, review:architect, validation, verify_before_done.

## Claims (what the diff WILL do)
- Add independently-configurable skip-forward and skip-back intervals (default 30s each),
  set on the main Settings screen under a Playback section, applied globally to all audiobooks.
- ios-core: a UserDefaults-backed global store (`AudiobookSkipIntervalSettings`) + a Playback
  section in the main Settings view (two pickers, options 15/30/45/60) + wire the stored values
  into PlaybackBootstrapper `preferredIntervals` and into the toolkit at manager-construction.
- toolkit: replace the single `DefaultAudiobookManager.skipTimeInterval = 30` with configurable
  `skipForwardInterval` / `skipBackInterval` (default 30 each) used by AudiobookPlaybackModel
  (in-app skip + button labels in AudiobookPlayerView) and the remote-command skips.

## Anti-claims (what it will NOT do)
- No per-book / per-title intervals; no chapter-nav changes.
- No behavior change for existing users until they change a setting (defaults stay 30/30).
- No new network, DRM, or persistence-migration surface.

## Files in scope
- ios-core: Palace/Audiobooks/AudiobookSkipIntervalSettings.swift (new), Palace/Settings/* (main
  settings view), Palace/Audiobooks/PlaybackBootstrapper.swift, + PalaceTests.
- toolkit: PalaceAudiobookToolkit/Core/AudiobookManager.swift, UI/AudiobookPlaybackModel.swift,
  UI/AudiobookPlayerView.swift, + PalaceAudiobookToolkitTests.

## Verification
- TDD: store defaults/persistence/independence tests; toolkit interval-plumbing tests.
- Build + launch on sim; VoiceOver + Dynamic Type on the new controls; buttons reflect chosen values.

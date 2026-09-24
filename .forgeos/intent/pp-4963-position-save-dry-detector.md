---
name: pp-4963-position-save-dry-detector
created: 2026-09-24
author: Maurice Carrier
branch: feat/PP-4963-position-trace
priority: PP-4963 / audiobook position loss (critical-path)
---

# Intent: measure whether position saves stop during locked background playback

## Context

25 of 83 App Store reviews this year say the app forgets where the patron was,
losing hours. Four position fixes shipped across 3.2.x/3.3.0 and complaint
volume is flat. PP-4963 asks for a measurement before a fifth fix.

The reading (memory `audiobook-position-loss-two-defects`, re-verified against
the tree today) is that the autosave chain is two main-runloop stages:
`AudiobookManager.setupNowPlayingInfoTimer()` publishes
`Timer.publish(every:on: .main, in: .common)` → `.positionUpdated` →
`AudiobookPlaybackModel`'s `.throttle(5s, scheduler: RunLoop.main)` →
`saveLocation()`. The toolkit's own comment at
`AudiobookManager.swift:548-556` states iOS coalesces and suspends such timers
during long screen-locked background playback.

The HelpSpot 17865 fix moved the LOCK SCREEN off that timer onto
`positionPublisher` (playback-clock driven, `setupNowPlayingHeartbeat`) and
deliberately did NOT re-publish `.positionUpdated`, so the lock screen was
rescued and the autosave was left on the runloop. That is a reading of the
source, not a measurement.

**Why this is not answerable from Crashlytics today:** Crashlytics records
failures. A save that does not happen is an absence, and nothing can log its
own absence from inside the thing that stopped running. Nothing in the save
path logs success — `saveListeningPosition` uses `Log.debug`, and only
`Log.warn` / `TPPErrorLogger` reach Crashlytics.

`NowPlayingCoordinator.checkForDryStream()` (`:332`, code 403) already solves
exactly this shape for the lock-screen writer: a second clock notices the first
went quiet and reports on foreground return. This change applies that proven,
already-shipping pattern to the save path.

**Why not the simulator:** the mechanism under test is iOS power management
coalescing main-runloop timers under a locked screen during background audio.
The Simulator shares the host scheduler and does not emulate it, so a green
simulator run would carry no information. simdrive is used to validate the
instrument (lines emitted, gap arithmetic, threshold boundaries), not to take
the measurement.

## Claims

- Adds `PositionSaveDryPolicy.evaluate(...)`, a pure function returning
  `PositionSaveVerdict` (`.noPlayback` / `.playbackStale` / `.saving` /
  `.dry(seconds:)`), deciding on foreground return whether saves went quiet
  WHILE playback was demonstrably live. Finite input space, asserted as a
  transition table rather than by scenario.
- The liveness signal is subscribed from `player.positionPublisher`
  **directly**, never from `AudiobookPlaybackModel.$currentLocation` and never
  from a runloop timer. This is load-bearing: `$currentLocation` is fed by both
  the playback clock and the suspect timer, and a watchdog driven by the timer
  it is watching goes silent exactly when the defect fires, so silence would
  read as "no problem" — the instrument would fabricate the answer it is
  looking for.
- Adds `PositionRestoreGapPolicy.evaluate(...)`, a pure function returning
  `PositionRestoreGapVerdict`, computing the gap between the position actually
  restored and the last position the playback clock observed. The last-live
  marker is persisted on the PLAYBACK-CLOCK cadence, not on save — updating it
  on save makes the gap identically zero by construction and the instrument
  proves nothing.
- A marker whose track key is absent from the loaded manifest reports
  `.markerUnresolvable`, never `.aligned` — the 3.2.3 Cause 2 hazard, where an
  unresolvable position is silently treated as agreement.
- Adds `TPPErrorLogger` codes 404 (`audiobookPositionSaveDry`) and 405
  (`audiobookPositionRestoreGap`) in the audiobooks block.

## Anti-claims

- **Does NOT fix the defect.** No change to when, whether, or on which
  scheduler a position is saved. If the measurement confirms the reading, the
  fix is a separate ticket.
- Does NOT move `.positionUpdated` off the main-runloop timer, and does not
  touch `setupNowPlayingInfoTimer` or the throttle.
- Does NOT change what is restored. `resolveInitialPosition` and
  `validatedRemotePosition` keep their current behavior; the gap is observed
  alongside the restore, never used to alter it.
- Does NOT emit book identity, title, or patron identity in the fleet event.
  Patron reading position is a library record; the event carries a duration, an
  app state, and a resolution outcome. This is a deliberate narrowing of the
  ticket's "record every position save" for the fleet path — the full per-book
  detail stays in the existing local `AudiobookFileLogger`.
- Does NOT add a new UserDefaults-backed restore source. The last-live marker
  is diagnostic only; nothing reads it to decide where to open a book.
- No toolkit (`ios-audiobooktoolkit`) change. `positionPublisher` is already a
  public requirement on `public protocol Player`, so the whole change lands in
  ios-core and needs no submodule bump.

## Files in scope

- `Palace/Audiobooks/AudiobookPositionTrace.swift` (new — pure policies + marker)
- `Palace/Audiobooks/AudiobookPositionTraceRecorder.swift` (new — live recorder,
  plus the manifest offset resolver)
- `Palace/Audiobooks/AudiobookLoader.swift` (builds the recorder and subscribes
  `player.positionPublisher`; this is the only place the bookmark logic, the
  manager and the player all exist together)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (restore-gap observation)
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (save notification)
- `Palace/Logging/TPPErrorLogger.swift` (codes 404/405)
- `Palace/Settings/Debug/DebugSettings.swift` (the default-off trace switch)
- `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift` (exposes it)
- `Palace/Settings/DeveloperSettings/DeveloperSettingsView.swift` (the row)
- `PalaceTests/Audiobook/AudiobookPositionTraceTests.swift` (new)
- `PalaceTests/Audiobook/AudiobookPositionTraceRecorderTests.swift` (new)
- `Palace.xcodeproj/project.pbxproj` (via `scripts/pbxproj_add_swift.rb`)

`AudiobookSessionPresenter.swift` was listed here in the first draft and is NOT
touched: the recorder is owned by `LoadedAudiobook` from `AudiobookLoader`, so
the presenter needed no change.

## Verification

- Transition-table tests over both policies, including threshold boundaries
  (exactly-on-threshold is NOT dry) and the unresolvable-marker cell.
- Mutation via `scripts/palace_mutate.py --diff-only` on both new policy files.
- The instrument's own failure mode is tested: playback live + saves dry must
  produce `.dry`, and NO ticks must produce `.noPlayback` rather than `.dry`,
  so an inert recorder cannot be mistaken for a clean result.
- Device run (iPhone SE 2nd gen, passcode set, 3h locked background listen)
  reads the result. n=1 confirms a mechanism; the fleet detector supplies scale.

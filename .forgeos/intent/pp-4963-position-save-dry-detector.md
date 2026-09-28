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
- A tick-stream gap reports `.tickGap`, never `.saving`. A gap has two causes
  this signal cannot separate — the patron paused, or playback continued while
  main-queue delivery was suppressed — and the second is the hypothesis under
  test, so a stretch opened by a gap with no save of its own makes no health
  claim. `.dry` still outranks it, and a stretch that has since saved reports
  `.saving`.
- A tick reference sitting later than `now` reports `.clockRegressed`, never
  a measured verdict. Every interval is computed from that reference, so once
  it is ahead of the present none of them mean anything.
- Adds `TPPErrorLogger` codes 404 (`audiobookPositionSaveDry`), 405
  (`audiobookPositionRestoreGap`), 406 (`audiobookPositionTickGap`) and 407
  (`audiobookPositionClockRegressed`) in the audiobooks block. Each signal
  keeps its own code; 405 was lost to a collapse into 404 in an earlier round.
- Both fleet findings carry `tickGapCount` and `longestTickGapSeconds`. One
  session cannot separate a pause from a stall; across the fleet the gap count
  is what does.

## Anti-claims

- **Does NOT fix the defect.** No change to when, whether, or on which
  scheduler a position is saved. If the measurement confirms the reading, the
  fix is a separate ticket.
- Does NOT move `.positionUpdated` off the main-runloop timer, and does not
  touch `setupNowPlayingInfoTimer` or the throttle.
- Does NOT change what is restored. `resolveInitialPosition` and
  `validatedRemotePosition` keep their current behavior; the gap is observed
  alongside the restore, never used to alter it.
- Does NOT add book identity, title, or patron identity to the fleet event.
  Patron reading position is a library record; what this instrument contributes
  is a duration, an app state, and two counts. A deliberate narrowing of the
  ticket's "record every position save" for the fleet path — the full per-book
  detail stays in the existing local `AudiobookFileLogger`.

  Scoped deliberately to what this instrument adds, because the payload is not
  the whole event. `TPPErrorLogger.addAccountInfoToMetadata` attaches account
  name, UUID and catalog/loans URLs to every `logError(withCode:)`, and
  `FirebaseManager` sets a global md5(barcode) Crashlytics user id. Both are
  pre-existing and shared with shipped code 403, and no BOOK identity is
  reachable either way — so a patron's position in a book stays
  unreconstructible, which is the property that justifies shipping 404, 406 and
  407 ungated. It is not an end-to-end anonymity claim and must not be read as
  one.
- Does NOT add a new UserDefaults-backed restore source. The last-live marker
  is diagnostic only; nothing reads it to decide where to open a book.
- No toolkit (`ios-audiobooktoolkit`) change. `positionPublisher` is already a
  public requirement on `public protocol Player`, so the whole change lands in
  ios-core and needs no submodule bump.

## Files in scope

- `Palace/Audiobooks/AudiobookPositionTrace.swift` (new — pure policies + marker)
- `Palace/Audiobooks/AudiobookPositionTraceRecorder.swift` (new — live recorder,
  plus the manifest offset resolver)
- `Palace/Audiobooks/AudiobookLoader.swift` (`makePositionTrace` builds the
  recorder, installs the bookmark logic as `bookmarkDelegate` and subscribes the
  player; this is the only place the bookmark logic, the manager and the player
  all exist together)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (restore-gap observation)
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (OWNS the
  recorder; notifies it on every local write)
- `Palace/Logging/TPPErrorLogger.swift` (codes 404/405/406/407)
- `Palace/Settings/Debug/DebugSettings.swift` (the default-off trace switch)
- `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift` (exposes it)
- `Palace/Settings/DeveloperSettings/DeveloperSettingsView.swift` (the row)
- `PalaceTests/Audiobook/PositionSaveDryPolicyTests.swift` (new — holds
  `PositionSaveDryPolicyTests` and `PositionRestoreGapPolicyTests`; named for
  its classes after the original filename matched none of them, which made an
  `-only-testing` filter silently select nothing)
- `PalaceTests/Audiobook/AudiobookPositionTraceCallSiteTests.swift` (new — the
  two `noteSave` call sites and the marker store)
- `PalaceTests/Audiobook/AudiobookPositionTraceRecorderTests.swift` (new)
- `PalaceTests/Audiobook/AudiobookPositionTraceSeamTests.swift` (new — the
  joins: resolver against a real manifest, observe, dispatch, file trace)
- `PalaceTests/Audiobook/AudiobookPositionTraceReportTests.swift` (new — the key
  SET of every payload that leaves the device)
- `PalaceTests/Audiobooks/AudiobookLoaderPositionTraceWiringTests.swift` (new —
  the loader's three joins)
- `Palace.xcodeproj/project.pbxproj` (via `scripts/pbxproj_add_swift.rb`)

`AudiobookSessionPresenter.swift` was listed in the first draft and is NOT
touched.

**Ownership — corrected after review.** The recorder is owned by
`AudiobookBookmarkBusinessLogic`, injected as a `let` at init. It is retained
through `AudiobookManager.bookmarkDelegate` (strong) and
`AudiobookSessionManager.manager` (strong), so it lives exactly as long as the
save path it measures.

The first draft hung it off the `LoadedAudiobook` STRUCT, which
`AudiobookSessionManager.bind` destructures and drops, with every other
reference weak. That deallocated the recorder seconds after first play and made
the whole instrument inert — no verdict could ever fire, and an empty fleet
reads as "no defect". Do not move ownership back onto the struct or onto the
session manager: `AudiobookPositionTraceLifetimeTests` fails if the reference is
weakened, and session-manager ownership would let the recorder outlive a torn-
down delegate and report `.dry` for a session whose saver had legitimately gone
away.

## Verification

- Transition-table tests over both policies, including threshold boundaries
  (exactly-on-threshold is NOT dry) and the unresolvable-marker cell.
- Mutation via `scripts/palace_mutate.py --diff-only` on both new policy files.
- The instrument's own failure mode is tested AT THE VERDICT: playback live +
  saves dry must produce `.dry`, and NO ticks must produce `.noPlayback` rather
  than `.dry`. That discriminates the two in a unit test, and it does NOT carry
  to the fleet. `saveReportPayload` returns nil for `.noPlayback`,
  `.playbackStale` and `.saving`, so those three are silent at the Crashlytics
  sink, and an inert recorder produces none of the other three either — it has
  no tick stream to find a gap in and no reference to see a clock step against.
  Zero events on 404, 406 and 407 therefore means "no finding was observed",
  which is what a healthy install base looks like AND what a recorder that was
  never wired, lost its `observe(player:)` call, or saw a suspended
  `positionPublisher` looks like. Confirm liveness on a diagnostics-ON device
  before reading a null result as good news.
- The WIRING is tested, which is what makes the rule above actionable rather
  than only a caveat. `AudiobookLoaderPositionTraceWiringTests` drives
  `AudiobookLoader.makePositionTrace` and asserts the recorder is reachable from
  the manager after every local reference is dropped, dies with the bookmark
  delegate and not before, and answers a foreground return — so the three joins
  that would leave a shipped instrument inert fail a named test instead.
- Device run (iPhone SE 2nd gen, passcode set, 3h locked background listen)
  reads the result. n=1 confirms a mechanism; the fleet detector supplies scale.

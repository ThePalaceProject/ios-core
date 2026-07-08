# Module Startup-AppLifecycle — implementer transcript (swarm_27c181b5)

## Summary
Wired the built-but-unwired `AppLaunchTracker` at its production launch sites and
moved two main-thread launch costs off the synchronous launch path. No public API
was removed; two testability seams were added (both `internal`/DI, production-defaulted).

## Changes landed

### C1 — AppLaunchTracker instrumentation
- `Palace/AppInfrastructure/TPPAppDelegate.swift` — at the very top of
  `applicationDidFinishLaunching`, record `.processStart` then `.didFinishLaunching`
  in a single `Task` (actor-serialized so the two timestamps stay ordered).
  `processStart` recorded as early as possible so `timeToFirstFrame` /
  `timeToInteractive` compute non-nil.
- `Palace/AppInfrastructure/SceneDelegate.swift` — record `.firstFrame` immediately
  after `newWindow.makeKeyAndVisible()`.
- Enum cases already existed (`.processStart/.didFinishLaunching/.firstFrame/.catalogLoaded`)
  and `recordMilestone(_:)` already existed — no new AppLaunchTracker API needed.
  `.catalogLoaded` is owned by the CatalogUI implementer (CatalogViewModel) — NOT touched here.

### C2 — GeneralCache.clearCacheOnUpdate off-main purge
- `Palace/Utilities/ImageCache/GeneralCache.swift` — the version compare + flag
  write stay SYNCHRONOUS; the `clearAllCaches()` body is now dispatched onto
  `DispatchQueue.global(qos: .utility)`. Nothing on the launch path waits for the purge.
- Added a computed `static var cacheVersionKey` (computed, not stored — Swift forbids
  stored static properties on a generic type) and an `internal` testable overload
  `clearCacheOnUpdate(defaults:currentVersionBuild:purge:) -> Bool` that holds the
  gate logic. The public `clearCacheOnUpdate()` delegates to it, passing the off-main
  dispatch as the `purge` closure. Call-site `TPPAppDelegate` :105 unchanged (public no-arg).

### C3 — PlaybackBootstrapper defer audio session (Audiobooks critical path — conservative)
- `Palace/Audiobooks/PlaybackBootstrapper.swift`:
  - `ensureInitialized()` now calls `setupRemoteCommands()` SYNCHRONOUSLY first
    (CarPlay cold-start need — byte-identical body), then dispatches
    `configureAudioSession()` off the synchronous launch path via an injected
    `launchAudioSessionDispatcher` (production default: background utility queue).
  - `configureAudioSession()` made `nonisolated` (body byte-identical) so it can run
    off-main from the dispatcher while the synchronous re-run callers
    (`ensureAudioSessionActiveForPlayback`, `ensureInitializedForCarPlay`) still call
    it directly — those re-run-on-playback paths are UNCHANGED.
  - Added `launchAudioSessionDispatcher` DI param to both inits with a per-call-site
    default-argument literal (NOT a shared `static let`, to avoid the Swift 6
    non-Sendable-global rule while keeping the param type non-`@Sendable` so tests can
    inject a capturing dispatcher). AppContainer :337 construction unchanged (default applies).

## Tests added (all registered in PalaceTests target via pbxproj_add_swift.rb: added=3)
- `PalaceTests/Platform/AppLaunchTrackerWiringTests.swift`
  - `testLaunchTracker_recordsMilestones_computesTimeToInteractive` — records
    processStart→didFinishLaunching→firstFrame→catalogLoaded (with real sleeps),
    asserts `timeToInteractive` and `timeToFirstFrame` non-nil, strictly positive,
    and ordered (ttf < tti; didFinishLaunching→firstFrame > 0). Kills the
    `endTime - startTime` sign-flip mutant. Uses an injected `PerformanceMonitor()`
    instance — never `.shared`.
  - `testLaunchTracker_firstFrameUnrecorded_timeToFirstFrameIsNil` — nil-guard edge.
- `PalaceTests/Utilities/GeneralCacheClearOnUpdateTests.swift` (drives the internal seam
  with an isolated `UserDefaults(suiteName:)` — never `.standard`, never real Caches dir)
  - `testGeneralCache_clearOnUpdate_versionGateStaysSync_purgeOffMain` — version change:
    flag written synchronously on return, purge invoked exactly once.
  - `testGeneralCache_clearOnUpdate_sameVersion_doesNotPurge` — kills `!=`→`==` and the
    drop-the-guard-always-purge mutant.
  - `testGeneralCache_clearOnUpdate_firstLaunch_purgesAndSeedsFlag` — nil-vs-current edge.
- `PalaceTests/Audiobooks/PlaybackBootstrapperAudioSessionTests.swift` (@MainActor,
  per-test `makeTestAppContainer()`)
  - `testPlaybackBootstrapper_launch_defersAudioSession_keepsRemoteCommands` — asserts
    remote commands configured synchronously (skipForward [30], nextTrack disabled) while
    the audio-session config is DEFERRED (dispatchCount==1, captured closure non-nil);
    running the deferred closure sets `AVAudioSession.category == .playback` (proves the
    deferred work is the real config, not a no-op).
  - `testPlaybackBootstrapper_ensureInitialized_isIdempotent_doesNotRedispatch` — second
    call does not re-dispatch (kills the `guard !isInitialized` mutant).

## Definition-of-Done evidence
- **Verification greps (contract §Verification criteria):**
  - `grep -c 'recordMilestone(.didFinishLaunching)' …/TPPAppDelegate.swift` → 1 ✓ (plus processStart → 1)
  - `grep -c 'recordMilestone(.firstFrame)' …/SceneDelegate.swift` → 1 ✓
  - GeneralCache: `clearAllCaches()` inside `DispatchQueue.global(qos: .utility).async` closure; gate + flag write synchronous ✓
  - PlaybackBootstrapper: `configureAudioSession` dispatched off-main via `launchAudioSessionDispatcher`; `setupRemoteCommands` synchronous + body unchanged ✓
- **Check #1 SUT instantiation:** AppLaunchTracker( =1, GeneralCache<…>.clearCacheOnUpdate =3, PlaybackBootstrapper( =2 — all ≥1 ✓
- **Check #1b `scripts/check-test-name-vs-body.py`** on all 3 new files → exit 0 (0 fake-wiring) ✓
- **Check #9 `check-blast-radius.py --quiet`** → exit 0 ✓
- **Check #11 `check-superpartner-spectrum.py --quiet`** → exit 0 ✓
- **No force-unwraps** in changed prod/test files (grep clean) ✓
- **No `.shared`/network/keychain/UserDefaults.standard** hit by any new test (injected instances + suite-named defaults) ✓

## Deferred to integration (explicit — NOT silently dropped)
- **Check #5 mutation (PlaybackBootstrapper, Audiobooks critical path) and Check #6
  build + `verify-pr.sh --quick`** were NOT run here: the module task explicitly says
  "Do NOT run git or a full app build," and `palace_mutate.py` / `verify-pr.sh` require
  building + running on a sim. These are the orchestrator's integration-gate step.
  The C3 tests are designed to kill the diff-scoped mutants (dispatch-count assertion,
  deferred-vs-inline assertion, `.playback` category assertion, idempotency guard), so a
  ≥50% diff-scoped kill rate is expected — but it is unverified until the integration build.

## Files touched (in-scope only)
- Palace/AppInfrastructure/TPPAppDelegate.swift (C1 instrumentation only; Network cache-clear hunks untouched)
- Palace/AppInfrastructure/SceneDelegate.swift (C1)
- Palace/Utilities/ImageCache/GeneralCache.swift (C2)
- Palace/Audiobooks/PlaybackBootstrapper.swift (C3)
- PalaceTests/Platform/AppLaunchTrackerWiringTests.swift (new)
- PalaceTests/Utilities/GeneralCacheClearOnUpdateTests.swift (new)
- PalaceTests/Audiobooks/PlaybackBootstrapperAudioSessionTests.swift (new)
- Palace.xcodeproj/project.pbxproj (test-target registration via helper)

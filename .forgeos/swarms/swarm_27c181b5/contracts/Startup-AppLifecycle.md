# Module Startup-AppLifecycle — instrument launch + off-main cache purge + defer audio session (standard)

## Goal
Wire the built-but-unwired AppLaunchTracker so every other fix is measurable. Move
two main-thread launch costs off-main.

## Changes
- INSTRUMENT: `AppLaunchTracker.recordMilestone` (surface already exists) at
  `.didFinishLaunching` (TPPAppDelegate :39), `.firstFrame` (SceneDelegate :57 post
  makeKeyAndVisible), `.catalogLoaded` (CatalogViewModel.load — owned by CatalogUI,
  API dependency only). Record processStart as early as possible so
  timeToInteractive/timeToFirstFrame compute non-nil.
- C2: `GeneralCache.clearCacheOnUpdate` (:303-357) — keep the version-check + flag
  write synchronous; move the `clearAllCaches()` body to a background queue
  (nothing on the launch path depends on the purge completing).
- C3: `PlaybackBootstrapper` (:238 via TPPAppDelegate :68) — keep
  `setupRemoteCommands()` (CarPlay cold-start need); defer `configureAudioSession()`
  off-main / to first scene-connect. The call routinely fails -50 this early and
  re-runs later.

## Test contracts
1. `testLaunchTracker_recordsMilestones_computesTimeToInteractive` — record
   processStart → didFinishLaunching → firstFrame; assert timeToInteractive != nil.
2. `testGeneralCache_clearOnUpdate_versionGateStaysSync_purgeOffMain`.
3. `testPlaybackBootstrapper_launch_defersAudioSession_keepsRemoteCommands`.

## Files OFF-LIMITS
AccountsManager.swift; CatalogUI/*; Network/*; TPPAppDelegate N1 cache-clear hunks (Network).

## Verification criteria (grep-able)
1. `grep -c 'recordMilestone(.didFinishLaunching)' Palace/AppInfrastructure/TPPAppDelegate.swift` → ≥1
2. `grep -c 'recordMilestone(.firstFrame)' Palace/AppInfrastructure/SceneDelegate.swift` → ≥1
3. GeneralCache diff: `clearAllCaches` body inside a background-queue closure; version-check + flag write remain synchronous
4. PlaybackBootstrapper diff: `configureAudioSession` dispatched off-main; `setupRemoteCommands` unchanged
5. SUT + `check-test-name-vs-body.py` exit 0 on new test files
6. Mutation ≥50% diff-scoped on PlaybackBootstrapper (Audiobooks critical path)
7. `scripts/verify-pr.sh --quick` PASS

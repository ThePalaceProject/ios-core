# Bucket T1 — `Player` async protocol + OpenAccessPlayer + LCPStreamingPlayer migration

## Scope summary

Migrate the toolkit's `Player` protocol from completion-handler shape to `async/await`. Migrate the two AVPlayer-backed conformers (`OpenAccessPlayer` and its subclass `LCPStreamingPlayer`) to the new shape in the same commit — Swift's `override` matching requires base + subclass signatures to change atomically.

This bucket establishes the protocol shape that T2 (Findaway + external callers) must conform to. T2 stacks on this bucket's branch.

## In-scope files (exclusive write — toolkit submodule paths)

- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Player.swift`
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/OpenAccessPlayer.swift`
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/LCPStreamingPlayer.swift`
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkitTests/PlayerMock.swift` (must conform to new protocol)
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj` (only if you add new files — pure modifications don't touch the pbxproj)

## Files OFF-LIMITS

- **T2 territory:** `Player/FindawayPlayer.swift`, `Player/Helpers/AudiobookLifecycleManager.swift`, `Player/Helpers/FindawayPlaybackNotificationHandler.swift`, `Player/Helpers/FindawayDownloadNotificationHandler.swift`, `Core/AudiobookManager.swift`, `UI/AudiobookPlaybackModel.swift`
- **T3 territory:** `Core/AudiobookSessionManager.swift`, `Player/Helpers/OpenAccessBackgroundListener.swift`, `Player/Helpers/OverdriveBackgroundListener.swift`
- **Out of swarm scope:** anything under `Network/`, `Tracker/`, `DRM/`, `UI/` (except `PlayerMock.swift` is allowed because it's already in T1 scope)
- **Read-only references:** `Core/Audiobook.swift`, `Core/AudiobookMetadata.swift`, `Core/Cursor.swift`, `Player/Helpers/Tracks/*`, `Player/UnifiedPositionSystem.swift`

## Public protocol shape — REQUIRED

Migrate the three completion-handler methods on `Player` to throwing async equivalents:

```swift
public protocol Player: NSObject {
    // ... unchanged read-only state surface (isPlaying, currentOffset,
    // tableOfContents, currentTrackPosition, currentChapter,
    // playbackRate, isLoaded, playbackStatePublisher, positionPublisher,
    // queuesEvents, isDrmOk) ...

    init?(tableOfContents: AudiobookTableOfContents)

    // Synchronous lifecycle (unchanged):
    func play()
    func pause()
    func unload()

    // Async navigation (NEW):
    /// Skips the playhead by `timeInterval` seconds (negative for back).
    /// Returns the resulting `TrackPosition`, or nil if no position
    /// could be determined (e.g. player not loaded).
    func skipPlayhead(_ timeInterval: TimeInterval) async -> TrackPosition?

    /// Begins playback at the given position. Throws if seek/load fails.
    func play(at position: TrackPosition) async throws

    /// Moves the playhead to fractional progress `value` (0.0..1.0) of the
    /// whole audiobook. Returns the resulting `TrackPosition`, or nil if
    /// the move could not be resolved.
    func move(to value: Double) async -> TrackPosition?
}
```

The `Completion` typealias on `Player` is removed (it was only used for the migrated methods).

### Why throwing-async on `play(at:)` only

`play(at:)` is the only method whose old completion shape exposed `Error?`. `skipPlayhead` and `move(to:)` returned `TrackPosition?` with no error channel — those map naturally to non-throwing async. Preserve that asymmetry; don't introduce throws on the non-throwing methods.

### Internal seek helpers stay sync OR get separate async overloads

`OpenAccessPlayer.seekTo(position:completion:)` is `public` but called by `LCPStreamingPlayer.override` and by `AudiobookManager.swift` (line 219 — T2 territory). You may:

1. **Migrate `seekTo` to async** — preferred if it cleans up the LCP override. T2 picks up the AudiobookManager call-site migration.
2. **Keep `seekTo` callback-shaped for now** — acceptable if the migration scope balloons. Document in the transcript.

Either path: T2's contract specifies how AudiobookManager's `seekTo` call-site adapts.

## Test contracts the bucket must satisfy

### Tests to update (existing files)

- `PalaceAudiobookToolkitTests/PlayerMock.swift` — rewrite its 3 completion methods as the new async shape. Mock returns must be deterministic (return the pre-set `currentTrackPosition`).
- Any existing test in `PalaceAudiobookToolkitTests/` that calls `playerMock.skipPlayhead(_:completion:)` etc. must be updated to `await` the new shape. Likely-affected (read to confirm): `AudiobookManagerLifecycleTests.swift`, `AudiobookPlaybackModelTests.swift`, `TrackTransitionTests.swift`, `SleepTimerTests.swift`.

### Tests to add (NEW)

- `OpenAccessPlayerAsyncContractTests` — at least these named cases:
  - `testSkipPlayhead_returnsAdjustedPosition` — call `await player.skipPlayhead(30)`, assert the returned `TrackPosition` has the expected offset.
  - `testPlayAt_throwsOnInvalidPosition` — call `try await player.play(at: invalidPos)`, assert the thrown error case.
  - `testMoveTo_returnsNilWhenNotLoaded` — call `await player.move(to: 0.5)` on an unloaded player, assert nil.
  - `testCancellation_skipPlayhead` — start `skipPlayhead`, cancel the task, assert the player state is not stuck (no pending operation lingers).
- `LCPStreamingPlayerAsyncContractTests` — at minimum:
  - `testSeekWithinSameTrack_doesNotRebuild` — confirms the LCP override-only fast-path is preserved post-migration (the `isSeekingWithinSameTrack` flag logic must still work).
  - `testPlayAtPosition_rebuildsQueue` — confirms rebuild semantics preserved.

## Acceptance criteria

- Toolkit builds: `xcodebuild -project PalaceAudiobookToolkit.xcodeproj -scheme PalaceAudiobookToolkit -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds.
- Toolkit tests pass: same command with `test`. No new test failures; pre-existing failures (if any) documented in transcript.
- All `override` declarations in `LCPStreamingPlayer.swift` match base signatures exactly. Compiler should enforce this.
- `PlayerMock.swift` conforms to the new protocol; all toolkit tests compile.
- No completion-handler shape remains on the migrated three methods anywhere in toolkit source. (Internal helpers may keep callbacks; protocol surface is async.)
- Mutation-kill ≥75% on critical paths: `OpenAccessPlayer.swift` `play(at:)`, `LCPStreamingPlayer.swift` `seekTo` + `play(at:)`. (Deferred to implementer to verify via toolkit-side tooling; flag in transcript if no mutation tool is wired in the toolkit repo.)
- TDD per Palace CLAUDE.md: every behavior change has a test that would fail without the change. No fluff tests (set-and-assert, tautology, coverage-only).

## Migration trade-off the implementer must call out

If migrating `seekTo` is non-trivial (LCP has 14 `override` declarations; some seek helpers cascade), the implementer should:

1. Either keep `seekTo` callback-shaped, OR
2. Migrate it and accept the additional churn in AudiobookManager (which is T2 — coordinate the contract update with T2).

Document the choice in the transcript with the LOC impact.

## Worktree + dispatch instructions

The implementer for this bucket will:

1. `cd /Users/mauricework/PalaceProject/ios-audiobooktoolkit` and confirm the submodule's remote (`origin` = `https://github.com/ThePalaceProject/ios-audiobooktoolkit.git`).
2. Create a toolkit worktree:
   ```bash
   git -C /Users/mauricework/PalaceProject/ios-core/ios-audiobooktoolkit \
     worktree add -b feat/swarm_efd1f0c3-T1 \
     /Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T1 \
     origin/main
   ```
3. Run the build + tests baseline before any edits to confirm a green starting point.
4. Implement the contract, commit on `feat/swarm_efd1f0c3-T1`.
5. Push the toolkit branch to toolkit origin: `git push -u origin feat/swarm_efd1f0c3-T1`.
6. Open a toolkit PR to `main` (NOT `develop`). Title prefix: `feat(player): migrate Player protocol to async/await (T1)`.
7. Write the transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T1.md` on the ORCHESTRATOR branch (back in `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_efd1f0c3-orchestrator/`). Include: files modified, tests added, decisions on `seekTo` migration, build/test commands, toolkit PR URL.

## Implementer prompt (ready-to-paste)

> You are the T1 implementer for swarm `swarm_efd1f0c3` (toolkit-side audiobook overhaul). Your contract is at `.forgeos/swarms/swarm_efd1f0c3/contracts/T1-Player-Protocol-OpenAccess.md` on the orchestrator branch.
>
> Migrate the toolkit's `Player` protocol from completion-handler shape to async/await. The protocol shape is defined in your contract — the three async methods replace the three completion-handler methods exactly. You must migrate `OpenAccessPlayer` and `LCPStreamingPlayer` in the same branch (LCP subclasses OpenAccess; signatures must match). Update `PlayerMock.swift` and any toolkit tests that compile against the old completion shape.
>
> Work in a toolkit worktree at `/Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T1/` off `origin/main` (toolkit primary branch). Branch name: `feat/swarm_efd1f0c3-T1`.
>
> Validate build + tests via the commands in the contract. TDD: write the failing async test first for each new behavior. No fluff tests; every test must kill at least one mutant (flip a conditional, negate a return).
>
> Decide on the `seekTo` migration (keep callback OR migrate to async) and document the choice + LOC impact in your transcript. Coordinate with the T2 contract author if you change `seekTo` — T2 needs to know.
>
> When done: push toolkit branch, open toolkit PR to `main`, write transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T1.md` on the orchestrator branch.
>
> Do NOT touch T2 or T3 territory. Do NOT bump the Palace submodule pin. Do NOT open a Palace PR.

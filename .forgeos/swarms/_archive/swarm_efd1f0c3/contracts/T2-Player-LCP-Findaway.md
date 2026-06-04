---
name: swarm_efd1f0c3-contract-T2-Player-LCP-Findaway
type: immutable
status: active
created: 2026-05-21T00:00:00Z
last_refresh: 2026-05-22
freshness_window: never
owners: [audiobook]
description: Bucket T2 — FindawayPlayer migration + external caller migration
---

# Bucket T2 — FindawayPlayer migration + external caller migration

## Scope summary

Migrate `FindawayPlayer` (the third `Player` conformer; uses AudioEngine SDK) to the async protocol shape defined by T1. Migrate the two external callers of the completion-handler player API — `AudiobookManager.swift` (3 sites) and `AudiobookPlaybackModel.swift` (7 sites) — to `await` the new methods.

This bucket **stacks on T1's branch** because it conforms to T1's protocol. Dispatch order: after T1 has committed and pushed `feat/swarm_efd1f0c3-T1`.

## In-scope files (exclusive write — toolkit submodule paths)

- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/FindawayPlayer.swift`
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookManager.swift` — call sites at lines 219/223/847/861 (current numbering on `7577ecb6`); seek + skipPlayhead + play(at:) calls only. Do NOT touch unrelated methods on this 33KB file.
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/UI/AudiobookPlaybackModel.swift` — call sites at lines 48/178/189/199/409/443/483; `play(at:)`, `skipPlayhead`, `move(to:)` calls only.
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Helpers/FindawayPlaybackNotificationHandler.swift` — only if Findaway's notification callbacks need adapter changes for the async migration.

## Files OFF-LIMITS

- **T1 territory:** `Player/Player.swift`, `Player/OpenAccessPlayer.swift`, `Player/LCPStreamingPlayer.swift`, `PlayerMock.swift`. T1 already migrated these on the base branch you're stacking on; you read them but do NOT modify.
- **T3 territory:** `Core/AudiobookSessionManager.swift`, `Player/Helpers/OpenAccessBackgroundListener.swift`, `Player/Helpers/OverdriveBackgroundListener.swift`.
- **Out of swarm scope:** `Network/`, `Tracker/`, `DRM/`, the rest of `UI/` beyond `AudiobookPlaybackModel.swift`. Do NOT edit `AudiobookPlayerView.swift` (its `playbackModel.move(to:)` call goes through your migrated method automatically).
- **AudiobookManager scope-fence:** only the 3 call sites listed above. The bulk of `AudiobookManager.swift` (state-publishing, bookmark surface, sleep timer integration) is read-only.

## Behavior to preserve (test-locked)

- `AudiobookManager.skipForward()` / `skipBack()` semantics unchanged (consumer-visible) — the line 847/861 callers go through `audiobook.player.skipPlayhead(...)`.
- `AudiobookManager.play(at:)` line 223 — the error path (logged + propagated via state publisher) must remain wired after the `try await` migration.
- `AudiobookPlaybackModel.move(to:)` UI delegate semantics unchanged — the SwiftUI binding consumer (`AudiobookPlayerView.swift:208`) must still see the same observable updates.
- Findaway's `FAEPlaybackEngine` notification-driven state machine is untouched — only the protocol-conforming surface migrates. SDK callbacks stay as-is.

## Public protocol shape — INHERITED FROM T1

You implement against T1's async protocol verbatim:

```swift
func skipPlayhead(_ timeInterval: TimeInterval) async -> TrackPosition?
func play(at position: TrackPosition) async throws
func move(to value: Double) async -> TrackPosition?
```

For Findaway, the SDK callbacks are bridged via `withCheckedContinuation` / `withCheckedThrowingContinuation`. Example pattern:

```swift
func play(at position: TrackPosition) async throws {
    return try await withCheckedThrowingContinuation { continuation in
        // Existing FAEPlaybackEngine call with completion-like callback;
        // resume the continuation in the callback's success/failure branches.
        // EXACTLY ONE resume per continuation — Findaway's notification
        // bridge can fire multiple times, so guard with an atomic flag.
    }
}
```

The atomic single-resume guard is REQUIRED for Findaway because `FAEPlaybackEngine` does emit duplicate state notifications on rapid track skips — without the guard, the continuation crashes on second resume.

## Test contracts the bucket must satisfy

### Tests to update

- `PalaceAudiobookToolkitTests/AudiobookManagerLifecycleTests.swift` — any test that mocks `audiobook.player.play(at:completion:)` needs to migrate to mocking the async version (`PlayerMock.swift` is already migrated by T1).
- `PalaceAudiobookToolkitTests/AudiobookPlaybackModelTests.swift` — same.
- `PalaceAudiobookToolkitTests/BearerTokenRefreshTests.swift` — verify Bearer-token path through `play(at:)` still works after migration.

### Tests to add (NEW)

- `FindawayPlayerAsyncContractTests`:
  - `testPlayAt_resumesContinuationOnce` — race-test: trigger duplicate `FAEPlaybackEngine` notifications, assert no crash (continuation guard works).
  - `testSkipPlayhead_findawayBoundsClamping` — Findaway's chapter-boundary clamping logic preserved.
  - `testPlayAt_throwsOnDRMError` — Findaway's DRM-error path maps to the new throws channel.
- `AudiobookManagerAsyncCallSiteTests` — at least:
  - `testSkipForward_propagatesAdjustedPosition` — calls `audiobook.player.skipPlayhead(...)` through `AudiobookManager.skipForward()`, asserts the state publisher emits with the awaited result.
  - `testPlayAt_errorPath` — error path through `try await audiobook.player.play(at:)` reaches the state publisher.
- `AudiobookPlaybackModelAsyncCallSiteTests`:
  - `testMoveTo_updatesSelectedLocation` — `await playbackModel.move(to: 0.5)` results in `selectedLocation` matching the returned `TrackPosition`.

### Specifically out-of-scope tests

The full FindawayPlayer SDK integration test surface is unchanged; you only add tests for the migrated protocol methods. The internal `FAEPlaybackEngine` state machine has its own tests in `AudiobookPlaybackModelTests` — re-run them as a regression gate, don't expand.

## Acceptance criteria

- Toolkit builds + tests pass on this stacked branch (`feat/swarm_efd1f0c3-T2` based on `feat/swarm_efd1f0c3-T1`).
- All three players (`OpenAccessPlayer`, `LCPStreamingPlayer`, `FindawayPlayer`) conform to T1's async protocol without compiler workarounds.
- All external call sites in `AudiobookManager.swift` and `AudiobookPlaybackModel.swift` use `await`/`try await`; no callback shims remain.
- Findaway continuation guard exists and is exercised by `testPlayAt_resumesContinuationOnce`.
- No behavioral regression in `AudiobookManagerLifecycleTests` or `AudiobookPlaybackModelTests` (your migration must keep these green).
- Mutation-kill ≥75% on critical paths: `FindawayPlayer.play(at:)` (continuation bridge), `AudiobookManager` line-219-223 block (error propagation).
- TDD per CLAUDE.md — every async call site has at least one test that would fail if the `await` were dropped (e.g. assert the post-await side effect).

## Worktree + dispatch instructions

This bucket STACKS on T1's branch:

1. Wait for T1 implementer to push `feat/swarm_efd1f0c3-T1` to toolkit origin.
2. Create your worktree:
   ```bash
   git -C /Users/mauricework/PalaceProject/ios-core/ios-audiobooktoolkit \
     fetch origin
   git -C /Users/mauricework/PalaceProject/ios-core/ios-audiobooktoolkit \
     worktree add -b feat/swarm_efd1f0c3-T2 \
     /Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T2 \
     origin/feat/swarm_efd1f0c3-T1
   ```
3. Implement, commit on `feat/swarm_efd1f0c3-T2`.
4. Push: `git push -u origin feat/swarm_efd1f0c3-T2`.
5. Open toolkit PR to `main` with **base = `feat/swarm_efd1f0c3-T1`** (stacked PR pattern). The toolkit reviewer merges T1 first; the PR base auto-retargets to `main`.
6. Write transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T2.md` on the orchestrator branch.

## Implementer prompt (ready-to-paste)

> You are the T2 implementer for swarm `swarm_efd1f0c3` (toolkit-side audiobook overhaul). Your contract is at `.forgeos/swarms/swarm_efd1f0c3/contracts/T2-Player-LCP-Findaway.md` on the orchestrator branch.
>
> Wait for T1's branch `feat/swarm_efd1f0c3-T1` to be pushed to toolkit origin (the orchestrator will notify you). Then base your worktree off `origin/feat/swarm_efd1f0c3-T1` — you are stacking on T1, not on `main`.
>
> Migrate `FindawayPlayer` to T1's async `Player` protocol. Migrate the external completion-handler call sites in `AudiobookManager.swift` (3 sites: 219/223/847/861-area) and `AudiobookPlaybackModel.swift` (7 sites) to `await` / `try await`. Use `withCheckedContinuation` / `withCheckedThrowingContinuation` to bridge Findaway's SDK callbacks; the continuation MUST be guarded against duplicate resumes (Findaway emits duplicate notifications on rapid skips).
>
> Work in a toolkit worktree at `/Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T2/`. Branch name: `feat/swarm_efd1f0c3-T2`.
>
> Validate build + tests via the commands in the contract. TDD: write the failing async test first. The continuation-guard test is non-negotiable — it's the load-bearing regression gate for Findaway's SDK quirk.
>
> When done: push toolkit branch, open toolkit PR to `main` with base = T1's branch (stacked PR). Write transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T2.md` on the orchestrator branch.
>
> Do NOT touch T1 territory (`Player.swift`, `OpenAccessPlayer.swift`, `LCPStreamingPlayer.swift`, `PlayerMock.swift`) or T3 territory (`AudiobookSessionManager.swift`, listener helpers). Do NOT bump Palace submodule pin.

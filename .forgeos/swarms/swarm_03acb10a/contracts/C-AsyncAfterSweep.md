# Module C — AsyncAfter sweep + AudiobookDataManager structured concurrency

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- MOD `Palace/Audiobooks/NowPlayingCoordinator.swift` — replace the `DispatchQueue.main.asyncAfter` at line 280 with `Task { @MainActor in; try? await Task.sleep(for: .seconds(delay)); … }`
- MOD `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — migrate `UIApplication.beginBackgroundTask` + `syncQueue.async(flags: .barrier)` + `DispatchQueue.main` callback patterns (lines 134-160 area) to `Task.detached(priority: .background)` for background work + `@MainActor` for UI side effects
- (Optional) MOD `PalaceTests/Audiobook/NowPlayingCoordinatorTests.swift` (if exists) — adapt
- MOD `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` — the existing `syncQueue.sync {}` drain pattern still works (the queue stays internal); test signature unchanged. If the migration changes observable behavior, this test catches it.
- MOD `PalaceTests/Audiobooks/AudiobookEventsTests.swift` — same (4 sites use `dataManager.syncQueue.sync {}`)

## Out-of-scope (read-only)

- `Palace/Audiobooks/AudiobookLoader.swift` — Swarm 1 already restructured; architect MAY authorize edits if residual pyramid surface exists, but default is no edits
- `Palace/Audiobooks/AudiobookSessionManager.swift` — Module B territory
- `Palace/Audiobooks/PlaybackBootstrapper.swift` — Module B territory
- All files in swarm-wide don't-touch list

## Behavior carve-out

`NowPlayingCoordinator.swift:280`:
```swift
// Before:
DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

// After:
let delaySec = delay
Task { @MainActor in
    try? await Task.sleep(for: .seconds(delaySec))
    workItem.perform()
}
```

The `workItem` cancellation contract must be preserved — if the existing code uses `DispatchWorkItem.cancel()`, the new code uses `Task.cancel()`.

`AudiobookDataManager.swift`:
The current pattern wraps a sync action in a background task lifetime:
```swift
let id = UIApplication.shared.beginBackgroundTask(withName: "audiobook-sync") { ... }
syncQueue.async(flags: .barrier) {
    self.performNetworkPost { result in
        UIApplication.shared.endBackgroundTask(id)
        DispatchQueue.main.async { completion(result) }
    }
}
```

Migrate to:
```swift
Task.detached(priority: .background) {
    await self.beginBackgroundLifetime("audiobook-sync") {
        let result = await self.performNetworkPost()
        await MainActor.run { completion(result) }
    }
}
```

`beginBackgroundLifetime` is a small helper that wraps `UIApplication.beginBackgroundTask` / `endBackgroundTask` around an async closure. Architect may decide to inline rather than helper-extract.

## Acceptance criteria

- `grep "DispatchQueue\.main\.asyncAfter" Palace/Audiobooks/ --include='*.swift'` (excluding comments) returns 0
- `grep "UIApplication\.shared\.beginBackgroundTask" Palace/Audiobooks/` migrates to async-wrapped form
- `AudiobookDataManagerSyncTests` + `AudiobookEventsTests` still pass (the `syncQueue.sync {}` drain may still work; the test signature unchanged)
- `AudiobookLoader.swift` LOC unchanged or smaller (architect verifies)

## Implementer prompt

You are Module C implementer for `swarm_03acb10a`. You're independent of Modules A and B — can dispatch in parallel.

PRE-WORK:
1. Write transcript skeleton FIRST.
2. Read NowPlayingCoordinator.swift around line 280 — what's the asyncAfter delay value? What cancels the workItem?
3. Read AudiobookDataManager.swift lines 134-160 — what's the background-task contract? syncQueue's purpose?
4. Read `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` — what does it verify? Will the migration preserve observable behavior?

The migration goal is structured concurrency (`Task.sleep`, `Task.detached`, `@MainActor`), NOT semantic change. Tests gate.

Validate: `xcodebuild build` + run AudiobookDataManagerSyncTests + AudiobookEventsTests + NowPlayingCoordinatorTests (if exists) — all must pass.

Write transcript. Do NOT commit, push, or dispatch agents.

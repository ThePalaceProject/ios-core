# Bucket T3 — Rename toolkit's `AudiobookSessionManager` → `AudiobookDownloadCoordinator`

## Scope summary

Pure rename inside the toolkit module. The toolkit's `AudiobookSessionManager` (a `.shared` singleton that coordinates background download sessions, NOT playback) is misnamed; the class actually orchestrates `URLSession` background downloads. Renaming clarifies intent and removes the cross-package naming collision with Palace's distinct `Palace.AudiobookSessionManager` (added in Phase 3 / PR #982).

**Scope per ADR: pure rename, `.shared` stays.** The toolkit's `AudiobookSessionManager` is a process-wide singleton because iOS delivers background-session reconnection to a global handler in `AppDelegate`/`SceneDelegate` — binding it to an instance would force AppDelegate-side wiring across consumer apps. Out of scope for this bucket. (If the implementer finds `.shared` removal becomes a clean 1-line extension during the rename, document the trade-off in the transcript but DO NOT remove it.)

## In-scope files (exclusive write — toolkit submodule paths)

- RENAMED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookSessionManager.swift` → `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookDownloadCoordinator.swift` (via `git mv` to preserve history)
- MODIFIED inside the renamed file: class declaration, doc comment, log strings referencing the type name.
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Helpers/OpenAccessBackgroundListener.swift` — 5 call sites (`AudiobookSessionManager.shared.<method>` → `AudiobookDownloadCoordinator.shared.<method>`).
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Helpers/OverdriveBackgroundListener.swift` — call sites with the same pattern (the same 4-5 method calls).
- MODIFIED `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj` — 4 path-field updates where `AudiobookSessionManager.swift` appears (lines around 82/89/124/249 — confirm by grep on your worktree).
- MODIFIED any toolkit test that references `AudiobookSessionManager` by name (run a grep before touching — `PalaceAudiobookToolkitTests/` may have direct references; if none, no test edits needed).

## Files OFF-LIMITS

- **T1 territory:** `Player/Player.swift`, `Player/OpenAccessPlayer.swift`, `Player/LCPStreamingPlayer.swift`, `PlayerMock.swift`.
- **T2 territory:** `Player/FindawayPlayer.swift`, `Core/AudiobookManager.swift`, `UI/AudiobookPlaybackModel.swift`.
- **Not yours even though tempting:** the actual download-task implementations (`OpenAccessDownloadTask.swift`, `OverdriveDownloadTask.swift`) — these are referenced from your file via `AudiobookSessionManager.migrateDownloadsFromCaches()` but their bodies stay untouched.
- **Out of scope:** any Palace-side files. Palace's `Palace.AudiobookSessionManager` is a different class in a different module; it is NOT being renamed.

## Type/API changes

```swift
// BEFORE
public final class AudiobookSessionManager { /* ... */
  public static let shared = AudiobookSessionManager()
  // ... unchanged surface ...
}

// AFTER
public final class AudiobookDownloadCoordinator { /* ... */
  public static let shared = AudiobookDownloadCoordinator()
  // ... unchanged surface ...
}
```

Surface preserved:
- `static let shared` — KEEP
- All public methods (`registerBackgroundCompletionHandler`, `callCompletionHandler`, `storeReconnectedSession`, `handleBackgroundDownloadCompletion`, `handleBackgroundDownloadError`, `registerActiveDownload`, `updateDownloadProgress`, `removeActiveDownload`, `activeDownloads(forBookID:)`, `downloadInfo(forSessionIdentifier:)`, `clearAllState`, `migrateDownloadsFromCaches`) — KEEP
- Public types (`DownloadInfo`, `AudiobookDownloadEvent`, `DownloadInfo.DownloadState`) — KEEP, unchanged
- `downloadStatePublisher` — KEEP

Log strings inside the file should reference the new type name (`ATLog(.debug, "AudiobookDownloadCoordinator: …")` instead of the old one) for log clarity.

## Optional: provide a deprecated typealias for source compatibility

**Recommendation: do NOT.** The toolkit class has no Palace call sites (confirmed by architect grep). Internal-only callers (`OpenAccessBackgroundListener`, `OverdriveBackgroundListener`) get updated atomically with the rename. A `@available(*, deprecated, renamed: ...)` typealias would persist a misleading name for no benefit.

If the implementer finds a hidden external caller (e.g. an Overdrive/Findaway SDK extension), add a deprecated typealias and document the discovery in the transcript.

## Test contracts the bucket must satisfy

### Tests to update

- Grep `PalaceAudiobookToolkitTests/**/*.swift` for `AudiobookSessionManager`. Update any direct references. (Architect grep on `7577ecb6` found zero direct toolkit-test references to the type — confirm on your worktree.)
- If any test uses `AudiobookSessionManager.shared.clearAllState()` in `setUp/tearDown`, update to `AudiobookDownloadCoordinator.shared.clearAllState()`.

### Tests to add (NEW — minimal, 1-2 cases)

- `AudiobookDownloadCoordinatorRenameTests` — a single sanity test:
  - `testTypeName_isAudiobookDownloadCoordinator` — `XCTAssertEqual(String(describing: type(of: AudiobookDownloadCoordinator.shared)), "AudiobookDownloadCoordinator")`. This is the one tautology-adjacent test that's allowed here because it locks the rename against an accidental future revert. **One test only** — do not pad with fluff.

**Don't add coverage-only tests for the rename.** The rename's correctness is provable by build success — the toolkit compiles iff every reference is updated. A failing build IS the test.

## Acceptance criteria

- Toolkit builds: `xcodebuild -project PalaceAudiobookToolkit.xcodeproj -scheme PalaceAudiobookToolkit -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds.
- Toolkit tests pass: same command with `test`.
- `git log --follow` on `PalaceAudiobookToolkit/Core/AudiobookDownloadCoordinator.swift` shows the full history of the old file (proves `git mv` preserved history, not a delete-and-add).
- No string `AudiobookSessionManager` remains in `PalaceAudiobookToolkit/` source files except inside doc comments that explicitly reference the rename (e.g. "formerly named AudiobookSessionManager").
- pbxproj has exactly 0 references to `AudiobookSessionManager.swift` after the rename; exactly N references to `AudiobookDownloadCoordinator.swift` where N matches the pre-rename count.
- No behavioral change: download flow behavior is unchanged. `AudiobookManagerLifecycleTests` and any background-download-touching tests still pass without modification (because the API surface didn't change).

## Worktree + dispatch instructions

This bucket is FULLY PARALLEL with T1 — no dependency. Dispatch concurrently with T1.

1. Create worktree off toolkit `main`:
   ```bash
   git -C /Users/mauricework/PalaceProject/ios-core/ios-audiobooktoolkit \
     worktree add -b feat/swarm_efd1f0c3-T3 \
     /Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T3 \
     origin/main
   ```
2. Perform the rename + reference updates + pbxproj edits in one commit.
3. Run build + tests — should be green with zero behavioral changes.
4. Push: `git push -u origin feat/swarm_efd1f0c3-T3`.
5. Open toolkit PR to `main`. Title: `refactor(core): rename AudiobookSessionManager → AudiobookDownloadCoordinator (T3)`.
6. Write transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T3.md` on the orchestrator branch.

## Implementer prompt (ready-to-paste)

> You are the T3 implementer for swarm `swarm_efd1f0c3` (toolkit-side audiobook overhaul). Your contract is at `.forgeos/swarms/swarm_efd1f0c3/contracts/T3-Rename-DownloadCoordinator.md` on the orchestrator branch.
>
> Rename the toolkit's `AudiobookSessionManager` class to `AudiobookDownloadCoordinator`. This is a pure rename — the `.shared` singleton and all public methods stay. Use `git mv` to preserve file history. Update references in `OpenAccessBackgroundListener.swift`, `OverdriveBackgroundListener.swift`, and the toolkit `project.pbxproj`.
>
> Work in a toolkit worktree at `/Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T3/` off toolkit `origin/main`. Branch: `feat/swarm_efd1f0c3-T3`. You are FULLY PARALLEL with T1 — no need to wait for it.
>
> Validate build + tests. The toolkit compiles iff every reference is updated — a failing build IS your regression gate. Add exactly one sanity test locking the new type name; no fluff coverage tests.
>
> When done: push toolkit branch, open toolkit PR to `main`. Write transcript to `.forgeos/swarms/swarm_efd1f0c3/transcripts/T3.md` on the orchestrator branch.
>
> Do NOT touch T1 or T2 territory. Do NOT remove `.shared`. Do NOT add a deprecated typealias unless you discover an external caller (none expected). Do NOT bump Palace submodule pin.

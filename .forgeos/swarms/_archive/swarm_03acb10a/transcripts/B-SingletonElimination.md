---
name: swarm_03acb10a-transcript-B-SingletonElimination
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: 180d
owners: [general]
description: Module B — Singleton Elimination — Transcript
---

# Module B — Singleton Elimination — Transcript

Swarm: `swarm_03acb10a` (Phase 3 of audiobook systemic overhaul)
Module: B — Delete `AudiobookSessionManager.shared` + `PlaybackBootstrapper.shared`; migrate callers to AppContainer cached factories
Status: **COMPLETE** — build green for Palace AND Palace-noDRM; targeted tests 37/37 passing
Worktree: `.claude/worktrees/swarm_03acb10a-orchestrator`
Branch: `swarm/swarm_03acb10a-scaffold`

## Files modified

| File | Edit type | LOC delta |
|---|---|---|
| `Palace/Audiobooks/AudiobookSessionManager.swift` | DELETE `static let shared` (line 87) + parameterless `private convenience init()` (lines 197–206) | −14 |
| `Palace/Audiobooks/PlaybackBootstrapper.swift` | DELETE `static let shared` (line 56) + parameterless `private convenience init()` (lines 90–95); drop default closure on `audiobookSessionProvider:` (line 103); update 2 doc-comment references to `.shared` | −13 (net) |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` | 1-line: `PlaybackBootstrapper.shared.ensureInitialized()` → `AppContainer.production().playbackBootstrapper.ensureInitialized()` | 0 |
| `Palace/CarPlay/CarPlaySceneDelegate.swift` | 1-line: same pattern for `ensureInitializedForCarPlay()` | 0 |
| `Palace/Book/UI/BookDetail/BookService.swift` | 1-line: `await AudiobookSessionManager.shared.openAudiobook(...)` → `await AppContainer.production().audiobookSession.openAudiobook(...)` | 0 |
| `Palace/Accounts/Library/AccountsManager.swift` | Doc comment update — `AudiobookSessionManager.shared.openAudiobook` → `AppContainer.production().audiobookSession.openAudiobook` (line 307) | 0 |
| `Palace/CarPlay/CarPlayAudiobookBridge.swift` | **OUT-OF-CONTRACT FIX**: 4th production call site not in contract — default-init parameter `init(sessionManager: AudiobookSessionManager = .shared)`. Changed field type to `AudiobookSessionManaging` protocol + accessor to optional resolved through `AppContainer.production().audiobookSession`. Surface verified protocol-clean (all 12 call sites covered) | +3 |
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | Added instance var `manager`; setUp constructs `AudiobookSessionManager(appContainer:)`; removed 10 `let manager = AudiobookSessionManager.shared` lines | −2 (net) |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | Added instance var `sessionManager`; replaced 2 `PlaybackBootstrapper.shared` reads with `AppContainer.production().playbackBootstrapper`; replaced 2 `AudiobookSessionManager.shared` reads with locally-constructed instance | +2 (net) |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | Added instance var `manager`; setUp constructs `AudiobookSessionManager(appContainer:)`; removed 4 `let manager = AudiobookSessionManager.shared` lines | +1 (net) |
| `PalaceTests/CarPlay/CarPlayTests.swift` | Line 36: `Palace.AudiobookSessionManager.shared` → `Palace.AudiobookSessionManager(appContainer: AppContainer.production())`. Lines 23, 28 (`AudiobookSessionManager.shared.clearAllState()`) **LEFT IN PLACE** — resolves to PalaceAudiobookToolkit's `AudiobookSessionManager` (still has `.shared` + `clearAllState`). Module D deletes these per D8. | +2 |
| `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift` | **OUT-OF-CONTRACT FIX**: line 155 referenced `Palace.AudiobookSessionManager.shared` — migrated to `AppContainer.production().audiobookSession` | 0 |

## Migration applied

All 6 locked diff blocks from the contract landed:

1. **AudiobookSessionManager.swift**: `static let shared` deleted; parameterless `private convenience init()` (the singleton seed) deleted. The designated `private init(...)` at line 171 stays private; the `convenience init(appContainer:)` at (former) line 212 is the only construction path. Verified ✓.

2. **PlaybackBootstrapper.swift**: `static let shared` deleted; parameterless `private convenience init()` (the singleton seed) deleted. Default closure value on `audiobookSessionProvider:` parameter removed — AppContainer's factory now always supplies an explicit closure. The designated `private init(...)` and the public-conformance `convenience init(appContainer:audiobookSessionProvider:)` are both intact. Verified ✓.

3. **TPPAppDelegate.swift:55**: `PlaybackBootstrapper.shared.ensureInitialized()` → `AppContainer.production().playbackBootstrapper.ensureInitialized()`. Verified ✓.

4. **CarPlaySceneDelegate.swift:43**: `PlaybackBootstrapper.shared.ensureInitializedForCarPlay()` → `AppContainer.production().playbackBootstrapper.ensureInitializedForCarPlay()`. Verified ✓.

5. **BookService.swift:75**: `await AudiobookSessionManager.shared.openAudiobook(book, startPlaying: true)` → `await AppContainer.production().audiobookSession.openAudiobook(book, startPlaying: true)`. Verified ✓.

6. **AccountsManager.swift:307**: doc comment updated. Verified ✓.

### Additional production-side fixes (not in contract, discovered at build time)

- **CarPlayAudiobookBridge.swift:136** — default-init parameter `init(sessionManager: AudiobookSessionManager = .shared)` failed compilation after `Palace.AudiobookSessionManager.shared` was deleted. The bridge field was changed from concrete `AudiobookSessionManager` to protocol `AudiobookSessionManaging` (all 12 in-file usages are protocol-conformant — verified via grep + protocol-surface read). Init became optional-arg with fallback through `AppContainer.production().audiobookSession`. Cleaner than a force-cast in the init body.
- **PlaybackBootstrapper.swift** doc comments lines 36–38 and 60–66 — two narrative references to `AudiobookSessionManager.shared` updated to `AppContainer.production().audiobookSession`. These were in `///` comments only; no functional change.

## Test file edits

Per-file `.shared` → local instance / AppContainer accessor replacements:

| File | `.shared` reads replaced | Strategy |
|---|---|---|
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | 11 (setUp + 10 test bodies) | Instance var pattern; removed redundant `let manager = .shared` from each test body, body uses `self.manager` from setUp |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | 4 (setUp + 3 test bodies, two of which referenced `PlaybackBootstrapper.shared`) | Instance var `sessionManager` for the Audiobook session; `PlaybackBootstrapper.shared` → `AppContainer.production().playbackBootstrapper` directly |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | 4 (4 test bodies, no prior setUp) | Added instance var pattern + setUp |
| `PalaceTests/CarPlay/CarPlayTests.swift` | 1 (line 36; lines 23/28 stay — resolve to toolkit's still-extant singleton) | Inline `Palace.AudiobookSessionManager(appContainer: AppContainer.production())` |
| `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift` | 1 (line 155, out-of-contract build fix) | `AppContainer.production().audiobookSession` direct |

**Note on AudiobookReliabilityTests.swift**: untouched. Lines 26, 30, 43, 52, 63, 72, 75, 89, 97 reference `AudiobookSessionManager.shared.<method>` where `<method>` ∈ {`clearAllState`, `registerActiveDownload`, `activeDownloads`, `updateDownloadProgress`, `downloadInfo`, `registerBackgroundCompletionHandler`, `callCompletionHandler`}. These ALL resolve to **PalaceAudiobookToolkit.AudiobookSessionManager** (not `Palace.AudiobookSessionManager`) — the toolkit class still has `static let shared` plus all 7 methods. Module D deletes this class block per D7.

## Validation

### Grep gates (all GREEN)

```
=== static let shared in Palace/Audiobooks/ — must be 0 ===
(no matches — OK)

=== Palace prod .shared callers OUTSIDE AppContainer.swift — must be 0 ===
(no matches — OK)
```

### Builds (BOTH GREEN)

- `xcodebuild -scheme Palace ... build` → `** BUILD SUCCEEDED **` (exit 0)
- `xcodebuild -scheme Palace-noDRM ... build` → `** BUILD SUCCEEDED **` (exit 0)

### Targeted tests (37/37 passing)

```
xcodebuild ... -only-testing:PalaceTests/AudiobookSessionStateTransitionTests \
              -only-testing:PalaceTests/PlaybackBootstrapperTests \
              -only-testing:PalaceTests/AudiobookSessionManagerShutdownTests \
              -only-testing:PalaceTests/AppContainerAudiobookFactoryTests \
              test
→ Test Suite 'Selected tests' passed
  Executed 37 tests, with 0 failures (0 unexpected) in 0.115 (0.142) seconds
→ ** TEST SUCCEEDED ** (exit 0)
```

xcresult: `/tmp/swarm_03acb10a_derived/Logs/Test/Test-Palace-2026.05.21_13-02-23--0400.xcresult`

## Hand-off to D

### Test-cleanup opportunities Module B left in place

1. **AudiobookSessionStateTests.swift**: `setUp` still calls `await manager.stopPlayback(dismissPhoneUI: false)` — now a no-op on a fresh instance. Comment in setUp marks it as Module D's target. Plus `testSessionManager_initialState_isIdle` has a leftover `await manager.stopPlayback(dismissPhoneUI: false)` near the top that's also no-op.

2. **PlaybackBootstrapperTests.swift**: same setUp no-op (`sessionManager.stopPlayback`). The instance var `sessionManager` was added but is only read by ONE test (`testAudiobookSessionManager_InitialState_IsIdle`); the other tests use a `bootstrapper` local — Module D can prune the field if it inlines that one.

3. **AudiobookSessionManagerShutdownTests.swift**: the instance var `manager` was added to keep the diff small. Module D can consider per-test locals if the setUp body is otherwise empty (it is — fresh instance per test is the cleaner shape; the F-001 watchdog scenarios test process-lifetime invariants, which a per-test instance still exercises).

4. **CarPlayTests.swift:23,28** — `AudiobookSessionManager.shared.clearAllState()` dead-API calls (D8). Both go through PalaceAudiobookToolkit's session manager; D's job is to remove them and replace setUp/tearDown bodies with no-ops (Palace's session is now fresh per test by construction; the toolkit's still leaks, but Module D's job is to stop these tests from depending on it).

5. **AudiobookReliabilityTests.swift** — the whole `AudiobookSessionManagerTests` class block (lines 17–105) targets dead API on the toolkit singleton. Per D7 this class deletes wholesale; the file's other test classes (DownloadWatchdogTests etc., lines 107+) stay.

### Architectural notes for D

- **CarPlayAudiobookBridge** is now protocol-typed (`AudiobookSessionManaging`). If D writes a `MockAudiobookSession` mock (one doesn't exist yet — see triage D7), the bridge accepts it directly via the optional `sessionManager:` init parameter. No `@testable` access trickery needed.
- **AccountsManager.swift:307 doc comment** is the only audiobook-side `.shared` mention remaining in production source. Module B's edit (`AppContainer.production().audiobookSession.openAudiobook`) is final.

### Boundaries respected

- `AppContainer.swift` — UNTOUCHED (Module A)
- `NowPlayingCoordinator.swift` — UNTOUCHED (Module C)
- `AudiobookDataManager.swift` — UNTOUCHED (D5 drop)
- `TPPUserAccountMock.resetShared()` — UNTOUCHED (meta-test enforced)
- `AudiobookReliabilityTests.swift` — UNTOUCHED (Module D deletes class block per D7)
- `AppContainerAudiobookFactoryTests.swift` — UNTOUCHED (Module A's new file)

Ready for D.

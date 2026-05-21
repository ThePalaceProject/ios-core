# Swarm 3 Triage Transcript — swarm_03acb10a

**Architect:** orchestrator agent
**Date:** 2026-05-21
**Branch:** `swarm/swarm_03acb10a-scaffold` (off `swarm/swarm_f4fbef9c-scaffold@52e99443f`)
**Base state:** PRs #979 (Swarm 1 vendor adapters) + #980 (Swarm 2 PositionWriter) both open. Both stacks under this branch.

## 1. Material deviations

The original ADR + plan made several assumptions about current code state that
the recon-pass had already mostly debunked. Architect triage validates them
against the actual file contents and surfaces 8 deviations.

### D1. AppContainer is a `struct`, not a class — per-account caching pattern needs adjustment

Contract A's skeleton said "follow whatever per-account pattern AppContainer already exposes (architect verifies — PR #967 Account state machine Phase 2 should have established the precedent)." After reading `AppContainer.swift` and `PR #967` (commits `9607160da` + `b3bdb9fc7`):

- **AppContainer is `struct`, not `class`.** No instance-level mutable caching is possible without `static` ceremony. The existing pattern (`bookCellModelCache`, `samplePreviewManager` at lines 30-53) uses `@MainActor private static var _xxx` as the cache cell. That works but is dispatch-once-pinned globally — NOT per-account.
- **PR #967 did NOT add a per-account factory to AppContainer.** It added per-account *cache-keying inside CatalogRepository* (URL+accountID key) and *per-account directory injection into MyBooksDownloadCenter* (closure-injected). Both are "consumers of currentAccount" patterns, not "factory cached by account" patterns.

**Implication:** Module A does NOT add per-account caching. Audiobook session is naturally a process-wide singleton that reads `accountsManager.currentAccount` internally on each operation (this is what `AudiobookSessionManager` already does). The factory exposes a single shared instance — same lifetime as `playbackBootstrapper`. If a future requirement needs per-account isolation, that's a separate sprint.

Contract A's per-account caching tests (`testAudiobookSession_differentAccount_returnsDifferentInstance`, `testAudiobookSession_accountSwitch_evictsOldInstance`) are **dropped** — they encode an invariant we are explicitly NOT building.

### D2. AudiobookSessionManager already has an `init(appContainer:)` convenience — Module B's job is *minimal*

`AudiobookSessionManager.swift:212-226` ALREADY defines:

```swift
convenience init(
    appContainer: AppContainer,
    reachabilityProvider: @escaping () -> Reachability = { AppContainer.production().reachability },
    bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry = { TPPBookCoverRegistry.shared },
    navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub = { AppContainer.production().navigationCoordinatorHub }
)
```

Module B's `init` work is trivial: this convenience just needs to drop the `private` modifier on the designated `init` (line 171) and the parameterless `private convenience init()` at line 197 needs to go away — that's the singleton-only init. The `init(appContainer:)` becomes the only construction path.

### D3. PlaybackBootstrapper already has the audiobookSessionProvider seam — Module B's job is to **remove the `static let shared` default closure**

`PlaybackBootstrapper.swift:101-109` ALREADY defines:

```swift
convenience init(
    appContainer: AppContainer,
    audiobookSessionProvider: @escaping () -> AudiobookSessionManaging = { AudiobookSessionManager.shared }
)
```

Module B's edit to PlaybackBootstrapper: drop the parameterless `private convenience init()` at line 90 (singleton seed) and drop the default closure value on line 103 once `AudiobookSessionManager.shared` is gone. The `init(appContainer:audiobookSessionProvider:)` becomes the only path; callers must supply the provider.

### D4. BookService is `static` (line 75 is in a static method) — uses `AppContainer.production()` directly

`Palace/Book/UI/BookDetail/BookService.swift:75` is inside a `static func openBook(_:onFinish:)` method. There is no `self.appContainer` to inject through. The edit is straightforward:

```swift
// Before:
_ = await AudiobookSessionManager.shared.openAudiobook(book, startPlaying: true)

// After:
_ = await AppContainer.production().audiobookSession.openAudiobook(book, startPlaying: true)
```

Contract B's "preferred `self.audiobookSession.openAudiobook(...)` if BookService already has an AppContainer injected" path does **not** apply — BookService is static.

### D5. AudiobookDataManager's `syncQueue` is NOT a Module C migration target — it's the GCD `asyncAfter` replacement

`Palace/Audiobooks/Tracker/AudiobookDataManager.swift:106-111` has an explicit comment:

> `internal access so @testable import tests can syncQueue.sync {} to deterministically wait for pending barrier writes to drain before asserting against store — that race used to be papered over with DispatchQueue.main.asyncAfter sleeps, which flaked under load and were banned by CLAUDE.md.`

The `syncQueue` was put in place SPECIFICALLY to replace `DispatchQueue.main.asyncAfter` for test determinism. Migrating it to `Task.detached` would reverse a deliberate hardening fix and re-introduce the flake. The 4 `dataManager.syncQueue.sync {}` calls in `AudiobookEventsTests.swift` (lines 53, 80, 110, 141) are deterministic drain points — they break if `syncQueue` goes away.

**Implication:** Module C's `AudiobookDataManager` work is limited to the `UIApplication.beginBackgroundTask` migration on lines 147-160. The `syncQueue.async(flags: .barrier)` at line 134 and `syncQueue.async [weak self]` at line 156 STAY as-is. `Task.detached` is appropriate for *background-task lifetime* (the iOS UIApplication.beginBackgroundTask side), not for *thread-serialization* (the syncQueue side).

A tighter alternative: leave `AudiobookDataManager` entirely alone in this swarm. The BG-task migration is a structured-concurrency NICE-TO-HAVE that doesn't unlock anything, and `UIApplication.beginBackgroundTask` + counted completion handler in lines 147-205 is already correctly written. **Recommendation:** drop AudiobookDataManager from Module C scope.

### D6. NowPlayingCoordinator workItem cancellation contract preserved

`Palace/Audiobooks/NowPlayingCoordinator.swift`:

- Line 53: `private var pendingUpdate: DispatchWorkItem?`
- Line 227, 249, 272: `pendingUpdate?.cancel()` at three sites
- Line 277-280: schedule new workItem then `DispatchQueue.main.asyncAfter`

Migration to `Task`:
- Replace `pendingUpdate: DispatchWorkItem?` with `pendingUpdate: Task<Void, Never>?`
- `cancel()` semantics preserved by `Task.cancel()`
- The workItem body at line 272-276 is already inside `Task { @MainActor in ... }` — so the migration is mostly mechanical.

Module C scope: **only this file**. AudiobookDataManager dropped per D5.

### D7. The "Module D delete `setUp resets shared mock`" target is mis-named — what's actually there is **broken tests against a deleted API surface**

The recon predicted `TPPBookRegistryMock.shared` / `reset.*shared` etc. as Module D's target. The grep landed differently:

- **`TPPUserAccountMock.resetShared()`** is the dominant pattern (~30+ instances in SignInLogic tests). This is a TEST MOCK with `resetShared()` as a deliberate isolation hook enforced by `PalaceTests/MetaTests/MockIsolationLintTests.swift` (lints any mock with a `static let shared` and requires `resetShared()`). **These are NOT to be touched.** The meta-test will fail if Module D deletes them.

- **The actual audiobook-side shared-state resets are 4 distinct test files** — see Module D inventory in section 4.

- **`AudiobookReliabilityTests.swift` (PalaceTests/Audiobook/) references methods that DO NOT EXIST on production**: `clearAllState()`, `registerActiveDownload(sessionIdentifier:bookID:trackKey:originalURL:localDestination:)`, `activeDownloads(forBookID:)`, `updateDownloadProgress(sessionIdentifier:progress:)`, `downloadInfo(forSessionIdentifier:)`, `registerBackgroundCompletionHandler(_:forSessionIdentifier:)`, `callCompletionHandler(forSessionIdentifier:)`. These tests test a download-tracking surface that AudiobookSessionManager USED TO HAVE pre Phase-6.6 refactor. **The tests are currently broken on this branch** (they reference dead API). Module D's value just increased — these need to be deleted (preferable) or rewritten to drive the new singleton-free API surface. Total LOC in `AudiobookReliabilityTests.swift` lines 21-105 (the `AudiobookSessionManagerTests` class block) is ~85 LOC of dead-API tests; ~25 LOC of setUp/tearDown. **This is net-negative LOC removal.**

### D8. `CarPlayTests.swift` also references `AudiobookSessionManager.shared.clearAllState()` — same dead-API issue

Same fix as D7 — `CarPlayTests.swift:23, 28` calls a method that doesn't exist on production. The remaining body of `CarPlayTests` (lines 36-227) appears to still work with the live API. Module D deletes the `clearAllState()` calls and adjusts setUp/tearDown to drive the new injected-session pattern.

## 2. Contract refinements

### Module A — AppContainer wiring

**Scope reduction:** No per-account caching. Single shared instance (cached statically), like `playbackBootstrapper`.

**Locked API surface:**

```swift
extension AppContainer {
    /// The process-wide audiobook session manager. Reads
    /// `accountsManager.currentAccount` internally on every operation, so
    /// account switches are observed without per-account caching.
    @MainActor
    var audiobookSession: AudiobookSessionManaging { get }

    /// The process-wide playback bootstrapper. Owns the warm-start CarPlay
    /// session initialization invariant (was `PlaybackBootstrapper.shared`).
    @MainActor
    var playbackBootstrapper: PlaybackBootstrapper { get }
}
```

Backing storage mirrors the `_bookCellModelCache` pattern:

```swift
@MainActor private static var _audiobookSession: AudiobookSessionManager?
@MainActor private static var _playbackBootstrapper: PlaybackBootstrapper?
```

The cache cell stores a `AudiobookSessionManager` (concrete), surfaced through the `AudiobookSessionManaging` protocol on read. Lazy-init on MainActor matches the existing pattern (background-thread first access of `production()` was the cycle that bit `_bookCellModelCache`).

**Lock LOC budget:** ≤60 LOC added to AppContainer (two cache cells + two computed properties + two factories). Down from the contract's 80 LOC budget.

**Locked tests** (4 → 2, per scope reduction):

- `testAudiobookSession_returnsSameInstance` — caching invariant (a single shared instance survives across reads)
- `testPlaybackBootstrapper_returnsSameInstance` — same
- DROPPED: `testAudiobookSession_differentAccount_returnsDifferentInstance` (no per-account caching)
- DROPPED: `testAudiobookSession_accountSwitch_evictsOldInstance` (no per-account caching)

Add one positive test:

- `testAudiobookSession_constructsWithProductionAppContainer` — verifies the cached instance is built from `AppContainer.production()` (i.e. no hardcoded `.shared` reads inside the factory). This is the migration-correctness test.

### Module B — Singleton elimination

**Locked migration steps:**

1. `Palace/Audiobooks/AudiobookSessionManager.swift`:
   - DELETE line 87: `public static let shared = AudiobookSessionManager()`
   - DELETE lines 197-206: `private convenience init() { self.init(...) }` (the singleton seed)
   - The `private init(...)` at line 171 becomes the only designated init. Drop the `private` access modifier so the `AppContainer` factory can call it. Or keep `internal` access via the `convenience init(appContainer:)` at line 212.
   - Make `init(appContainer:)` not `private` (already not — line 212 reads `convenience init`, no `private`). Verify access path.

2. `Palace/Audiobooks/PlaybackBootstrapper.swift`:
   - DELETE line 56: `public static let shared = PlaybackBootstrapper()`
   - DELETE lines 90-95: `private convenience init() { self.init(...) }` (the singleton seed)
   - Drop the default closure value on line 103 (`audiobookSessionProvider: @escaping () -> AudiobookSessionManaging = { AudiobookSessionManager.shared }` → `audiobookSessionProvider: @escaping () -> AudiobookSessionManaging`). Module A's factory supplies the closure.
   - Drop the `private` on the designated `init` (line 75) to make it accessible to AppContainer.

3. `Palace/AppInfrastructure/TPPAppDelegate.swift:55`:
   - `PlaybackBootstrapper.shared.ensureInitialized()` → `AppContainer.production().playbackBootstrapper.ensureInitialized()`

4. `Palace/CarPlay/CarPlaySceneDelegate.swift:43`:
   - `PlaybackBootstrapper.shared.ensureInitializedForCarPlay()` → `AppContainer.production().playbackBootstrapper.ensureInitializedForCarPlay()`

5. `Palace/Book/UI/BookDetail/BookService.swift:75`:
   - `_ = await AudiobookSessionManager.shared.openAudiobook(book, startPlaying: true)` → `_ = await AppContainer.production().audiobookSession.openAudiobook(book, startPlaying: true)`

6. Test files (architect inventory in section 4) — handled by Module D, not B. Module B's only test edit is to update any **build-blocking** references (e.g. `AudiobookSessionStateTests.swift:115-221` reads `AudiobookSessionManager.shared` 11 times for test instances — Module B must replace those with locally-constructed instances so the file compiles; Module D's job is the broader test-cleanup audit).

**Acceptance:**
- `grep "static let shared" Palace/Audiobooks/ --include="*.swift"` returns 0
- `grep "AudiobookSessionManager\.shared\|PlaybackBootstrapper\.shared" Palace --include="*.swift"` returns 0 (the comment at AccountsManager.swift:307 is updated to refer to `AppContainer.production().audiobookSession`)
- Production `.shared` migration is exhaustive: TPPAppDelegate.swift:55, CarPlaySceneDelegate.swift:43, BookService.swift:75 — verified by the grep above
- Tests that previously read `.shared` to drive the session (`AudiobookSessionStateTests`, `PlaybackBootstrapperTests`, `AudiobookSessionManagerShutdownTests`) compile against the new injection. Module B does the *minimum* test edits to keep them compiling; Module D does the cleanup.

### Module C — AsyncAfter sweep (NowPlayingCoordinator only)

**Scope:** ONE file (`NowPlayingCoordinator.swift`). AudiobookDataManager is dropped per D5.

**Locked migration:**

```swift
// Field declaration (line 53):
// Before:
private var pendingUpdate: DispatchWorkItem?
// After:
private var pendingUpdate: Task<Void, Never>?

// At each cancel site (lines 227, 249, 272):
// Before:
pendingUpdate?.cancel()
pendingUpdate = nil
// After: same — both work the same on Task<Void, Never>?

// Scheduling site (lines 272-280):
// Before:
let workItem = DispatchWorkItem { [weak self] in
    Task { @MainActor in
        self?.performUpdate(info, isPlaying: isPlaying)
    }
}
pendingUpdate = workItem

let delay = Configuration.updateDebounceInterval - timeSinceLastUpdate
DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

// After:
let delay = Configuration.updateDebounceInterval - timeSinceLastUpdate
let task = Task { @MainActor [weak self] in
    do {
        try await Task.sleep(for: .seconds(delay))
    } catch is CancellationError {
        return
    } catch {
        return
    }
    guard !Task.isCancelled else { return }
    self?.performUpdate(info, isPlaying: isPlaying)
}
pendingUpdate = task
```

The `CancellationError` swallowing matches the prior `DispatchWorkItem.cancel()` semantic (cancelled item simply doesn't fire — no error surfaced).

**Acceptance:**
- `grep "DispatchQueue\.main\.asyncAfter" Palace/Audiobooks/ --include='*.swift'` (excluding comments) returns 0
- `NowPlayingCoordinatorTests` + `NowPlayingCoordinatorBackgroundTests` both pass — they currently exercise the debounce window via `applicationStateProvider` and `now()` injection seams (lines 53-60 of the production file), neither of which the migration touches
- `AudiobookLoader.swift` untouched — Module C does **not** edit it (Swarm 1 territory; no residual pyramid surface)
- `AudiobookDataManager.swift` untouched — see D5

### Module D — Test cleanup

**Locked file list** — see section 4 below for the full inventory. Module D owns:

1. `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` — **DELETE** the `AudiobookSessionManagerTests` class block (lines 17-105) entirely. Tests reference dead API. The other test classes in the file (DownloadWatchdogTests at 107, DownloadPersistenceStoreTests at 158, etc.) STAY.
2. `PalaceTests/CarPlay/CarPlayTests.swift` — DELETE setUp/tearDown bodies' `clearAllState()` calls (lines 23, 28). Replace with no-op or with construction of a local `AudiobookSessionManager` instance scoped to the test class.
3. `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` — purely tests `AudiobookSessionState` value-type behavior (lines 17-180). No setUp shared-reset. Module B may need light touches if any of the file's lower classes drive the manager (architect's read of lines 1-50 shows only value-type tests; verifier-confirms during dispatch).
4. `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` — currently does `await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)` in `setUp`. Module B replaces `.shared` with a locally-constructed manager; Module D removes the now-pointless setUp body (the local manager is fresh, no reset needed).
5. `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` — same. `await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)` in setUp → removed.
6. `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` — uses `AudiobookSessionManager.shared` directly. Module B replaces with local injection; Module D removes any setUp-reset boilerplate.

**Locked LOC delta:**
- `AudiobookReliabilityTests.swift`: −90 LOC (dead-API class deletion)
- Other files: −5 to −15 LOC each (setUp body shrinks once `.shared` resets are no-op)
- **Expected net: −100 to −130 LOC** across Module D's file list.

**Acceptance:**
- `grep "clearAllState\|registerActiveDownload\|activeDownloads(forBookID" PalaceTests --include='*.swift'` returns 0
- All remaining audiobook tests pass — `xcodebuild test -only-testing:PalaceTests/<each class>` for each touched class
- Net negative LOC on Module D's diff

## 3. Disjointness check

| File | Module |
|---|---|
| `Palace/AppInfrastructure/AppContainer.swift` | **A only** |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | **B only** |
| `Palace/Audiobooks/PlaybackBootstrapper.swift` | **B only** |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` | **B only** (line 55) |
| `Palace/CarPlay/CarPlaySceneDelegate.swift` | **B only** (line 43) |
| `Palace/Book/UI/BookDetail/BookService.swift` | **B only** (line 75) |
| `Palace/Audiobooks/NowPlayingCoordinator.swift` | **C only** |
| `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift` | **A only** (new) |
| `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` | **D only** (class deletion) |
| `PalaceTests/CarPlay/CarPlayTests.swift` | **D only** (setUp/tearDown cleanup) |
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | **B + D shared** — B replaces `.shared` reads to keep file compiling; D removes the now-redundant setUp body. Convention: B does the **minimum** to keep build green; D follows up to remove dead boilerplate. |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | Same B + D split |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | Same B + D split |
| `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` | **No edits** (pure value-type tests) |

**Shared-file rule (B + D):** Module B touches the .shared reads ONLY to keep the build green. Module D follows in a separate commit (within the same swarm sequence) to remove the now-redundant setUp/tearDown bodies. If both modules want to touch the same line, Module B yields — Module D's pass owns final state of test cleanup.

No production-file overlaps. AudiobookLoader.swift is in Swarm 1's don't-touch list — confirmed untouched by all 4 modules.

## 4. Module D test-cleanup inventory

| File | Class | Lines | What it does today | Module D action | LOC delta (estimated) |
|---|---|---|---|---|---|
| `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` | `AudiobookSessionManagerTests` | 17–105 | References 7 dead-API methods (`clearAllState`, `registerActiveDownload`, `activeDownloads(forBookID:)`, `updateDownloadProgress`, `downloadInfo(forSessionIdentifier:)`, `registerBackgroundCompletionHandler`, `callCompletionHandler`). The download-tracking surface tested here doesn't exist on production AudiobookSessionManager (verified via `grep -rn "func clearAllState\|func registerActiveDownload" Palace --include="*.swift"` → 0 results) | DELETE the class block | **−~90 LOC** |
| `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` | `DownloadWatchdogTests`, `DownloadPersistenceStoreTests`, `AudiobookStorageLocationTests`, `BackgroundListenerTests` | 107–417 | Tests `DownloadWatchdog`, `DownloadPersistenceStore`, etc. — production classes still exist | LEAVE ALONE | 0 |
| `PalaceTests/CarPlay/CarPlayTests.swift` | `CarPlayTests` | 18–227 | setUp/tearDown call `AudiobookSessionManager.shared.clearAllState()` at lines 23, 28. Body methods (line 36+) call other `.shared` reads but only as the session manager handle — not the dead API | DELETE the two `clearAllState()` calls in setUp/tearDown; replace `let sessionManager = AudiobookSessionManager.shared` at line 36 with a locally-constructed manager via `AppContainer.production().audiobookSession` (Module B did the build-fix; Module D verifies it's idiomatic) | **−4 LOC** |
| `PalaceTests/CarPlay/CarPlayTests.swift` | `CarPlayIntegrationTests` + others (lines 228–613) | Various | No `clearAllState` references; some `.shared` reads as handles | Module B already handles the `.shared` replacement; Module D verifies no leftover dead-state resets | 0 |
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | `AudiobookSessionStateTransitionTests` | 17–280 | setUp body: `await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)` at line 22. Body methods at 115, 130, 140, 150, 159, 170, 181, 197, 208, 221 all do `let manager = AudiobookSessionManager.shared` | Module B replaces `.shared` reads (10 sites) with local construction; Module D removes the setUp body's reset call since fresh instances don't need stopPlayback | **−4 LOC** (setUp body shrinks) |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | `PlaybackBootstrapperTests` | 17–169 | setUp body: `await AudiobookSessionManager.shared.stopPlayback(...)`. Body methods at lines 30, 50, 65 use `.shared` reads | Module B replaces `.shared` reads; Module D removes setUp body | **−5 LOC** |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | `AudiobookSessionManagerShutdownTests` | 1–249 | Uses `let manager = AudiobookSessionManager.shared` at line 54 + likely several more sites. Targets F-001 watchdog crash | Module B replaces with local injection; Module D verifies no orphaned setUp reset boilerplate emerges | **−~10 LOC** (state-reset boilerplate likely scattered) |

**Total estimated Module D net:** **−110 to −130 LOC** (well within the "net negative LOC" acceptance gate).

**TPPUserAccountMock.resetShared() instances — NOT touched.** ~30 instances across `PalaceTests/SignInLogic/`, `PalaceTests/Integration/`, `PalaceTests/Network/`, `PalaceTests/TPPSignInBusinessLogicTests.swift`. These are test-mock isolation hooks enforced by `PalaceTests/MetaTests/MockIsolationLintTests.swift`. The lint REQUIRES any mock with `static let shared` to declare `resetShared()` and tearDown to call it. Touching these violates the meta-test.

**Audiobook test-mock isolation note:** there is no `AudiobookSessionManagerMock` mock class (verified — no file matches `grep -rn "AudiobookSessionManagerMock\|MockAudiobookSession" PalaceTests`). Tests have been using the live singleton, which is exactly why Module B's elimination is high-value (and why the `clearAllState()` workaround method was added — and then removed in some prior refactor, leaving the tests stranded).

**Flake-timeout bumps tied to shared state:** `grep "expectation.timeout = [0-9]" PalaceTests/Audiobook PalaceTests/Audiobooks --include="*.swift"` returned 0 in the audiobook tests. The 3-second `waitForExpectations(timeout: 3.0)` at `AudiobookReliabilityTests.swift:96` is part of the deleted-class block — gone with D7. No further flake-timeout reductions are in scope.

## 5. Dispatch verdict

**OK to dispatch.** All 4 contracts can be locked. Major changes from the original plan:

- Module A scope reduced (no per-account caching). 4 tests → 3.
- Module B scope unchanged in production count (3 .shared call sites + 2 `static let shared` removals), but the migration is mechanically smaller than expected: the `AudiobookSessionManager.init(appContainer:)` convenience already exists, and `PlaybackBootstrapper.init(appContainer:audiobookSessionProvider:)` already exists with default closure. Module B is mostly "delete the parameterless conveniences + drop default closures + update 3 call sites."
- Module C scope reduced to ONE file (NowPlayingCoordinator.swift). AudiobookDataManager dropped per D5.
- Module D's value increased — the dead-API tests in AudiobookReliabilityTests.swift are LOC-negative gold. Net delta is −110 to −130 LOC.

**Predicted module wallclock (revised):**
- Module A: 20–30 min (smaller — single shared instance + 3 tests)
- Module B: 60–90 min (the test-edit volume is the bulk; 10 sites in AudiobookSessionStateTests alone)
- Module C: 20–30 min (single file, mechanical translation)
- Module D: 25–40 min (deletion-heavy + setUp body shrink)

**Total swarm wallclock budget:** 2.5–4 hours (faster than Swarm 2's actual 3-4 hours given the scope reductions).

**Don't-touch list violations to watch:**
- No edits to `AudiobookLoader.swift` (Swarm 1; confirmed Module C drops it)
- No edits to `AudiobookDataManager.swift` (architect drop per D5)
- No edits to `TPPUserAccountMock.resetShared()` instances (meta-test enforced)

Manifest update needed: `C-AsyncAfterSweep` `files_scope` should drop `AudiobookDataManager.swift` and `AudiobookDataManagerSyncTests.swift` references; add note that `AudiobookLoader.swift` is **confirmed untouched**.

---
name: swarm_03acb10a-contract-D-TestCleanup
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [general]
description: Module D — Test cleanup
---

# Module D — Test cleanup

**Status:** REFINED post-triage — file list LOCKED.

## Scope summary

Three classes of cleanup, all net-negative LOC:

1. **DELETE the dead-API class block in `AudiobookReliabilityTests.swift`** —
   ~90 LOC of tests calling methods that no longer exist on production
   (`clearAllState`, `registerActiveDownload`, etc.). The methods were
   removed in a prior refactor; the tests were never updated and are
   currently broken on this branch.
2. **REMOVE `setUp.shared.clearAllState()` / `setUp.shared.stopPlayback()`
   boilerplate** from 4 audiobook + CarPlay test files that no longer need
   it after Module B replaces `.shared` reads with local injection.
3. **Verify the AudiobookEventsTests' `dataManager.syncQueue.sync {}` drain
   pattern still works** — Module C dropped AudiobookDataManager from its
   scope (architect D5), so the syncQueue stays and those 4 sync sites are
   stable. Module D's only action here is verification, not edit.

**TPPUserAccountMock.resetShared() instances are NOT touched.** ~30 instances
across SignInLogic/Integration/Network/TPPSignInBusinessLogic. These are test-
mock isolation hooks enforced by `PalaceTests/MetaTests/MockIsolationLintTests.swift`.
The meta-test will fail if Module D deletes them.

## In-scope files (exclusive write)

| File | Class | Action | Estimated delta |
|---|---|---|---|
| `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` | `AudiobookSessionManagerTests` (lines 17–105) | **DELETE the entire class block** | **−~90 LOC** |
| `PalaceTests/CarPlay/CarPlayTests.swift` | `CarPlayTests` setUp/tearDown | Remove `clearAllState()` calls (lines 23, 28); verify Module B's `.shared` → local-injection migration is idiomatic | **−4 LOC** |
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | `AudiobookSessionStateTransitionTests` setUp | Remove now-redundant `await AudiobookSessionManager.shared.stopPlayback(...)` (Module B replaced with fresh instance) | **−4 LOC** |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | `PlaybackBootstrapperTests` setUp | Same — remove redundant reset | **−5 LOC** |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | `AudiobookSessionManagerShutdownTests` | Verify Module B's `.shared` migration; remove any orphaned reset boilerplate that emerges | **−~10 LOC** |

**Net target: −110 to −130 LOC.**

## Out-of-scope (read-only)

- All production code (Modules A/B/C)
- `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` classes OTHER than
  `AudiobookSessionManagerTests` (DownloadWatchdogTests, DownloadPersistenceStoreTests,
  AudiobookStorageLocationTests, BackgroundListenerTests — these test live
  production classes and stay)
- `PalaceTests/Audiobooks/AudiobookEventsTests.swift` — verify only; do NOT
  edit (the 4 `dataManager.syncQueue.sync {}` calls at lines 53, 80, 110, 141
  are stable; Module C dropped AudiobookDataManager)
- `PalaceTests/Contract/` (cross-swarm — do not touch)
- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` (P0 regression gate)
- All `TPPUserAccountMock.resetShared()` instances (meta-test enforced)
- `PalaceTests/MetaTests/MockIsolationLintTests.swift` (the lint that enforces
  resetShared() — DO NOT WEAKEN)
- All files in swarm-wide don't-touch list

## Locked migration

### 1. `AudiobookReliabilityTests.swift` — delete the dead-API class

```diff
-final class AudiobookSessionManagerTests: XCTestCase {
-
-    override func setUp() {
-        super.setUp()
-        // Clear state before each test
-        AudiobookSessionManager.shared.clearAllState()
-    }
-
-    override func tearDown() {
-        AudiobookSessionManager.shared.clearAllState()
-        super.tearDown()
-    }
-
-    func testRegisterActiveDownload() {
-        // ... references registerActiveDownload, activeDownloads — both gone from production ...
-    }
-
-    func testUpdateDownloadProgress() {
-        // ... references updateDownloadProgress, downloadInfo(forSessionIdentifier:) — both gone ...
-    }
-
-    func testBackgroundCompletionHandlerRegistration() {
-        // ... references registerBackgroundCompletionHandler, callCompletionHandler — both gone ...
-    }
-}
-
 // MARK: - Download Watchdog Tests

 final class DownloadWatchdogTests: XCTestCase {
     // ... stays ...
```

**Justification for deletion vs rewrite:** the deleted tests covered an old
download-tracking surface on AudiobookSessionManager that no longer exists.
The current surface (download tracking) lives on `MyBooksDownloadCenter` /
`DownloadStateManager` / `BackgroundDownloadHandler` and has its own test
coverage in `PalaceTests/MyBooks/`. Rewriting against the new surface would
either duplicate `PalaceTests/MyBooks/` coverage or create coupling tests
that exercise things AudiobookSessionManager no longer owns. Net better to
delete and link to the canonical coverage in the implementer transcript.

### 2. `CarPlayTests.swift` — remove dead-API resets

```diff
 class CarPlayTests: XCTestCase {

     override func setUp() {
         super.setUp()
-        // Clear shared state to prevent test pollution
-        AudiobookSessionManager.shared.clearAllState()
     }

     override func tearDown() {
-        // Clear shared state after each test
-        AudiobookSessionManager.shared.clearAllState()
         super.tearDown()
     }
```

Once both setUp + tearDown bodies are empty (`super.setUp()` / `super.tearDown()`
only), Module D may delete the override entirely — Swift's default behavior
calls super.

If after Module B's migration line 36 reads
`let sessionManager = AudiobookSessionManager(appContainer: AppContainer.production())`,
verify that's idiomatic. If a local helper method would DRY it across the 7
test classes in the file, Module D may add it (but only if it doesn't grow
overall LOC).

### 3. `AudiobookSessionStateTests.swift` + `PlaybackBootstrapperTests.swift` — remove redundant setUp reset

```diff
     override func setUp() async throws {
         try await super.setUp()
-        // AudiobookSessionManager.shared is a singleton — reset before each
-        // test so .state assertions see .idle and not pollution from a prior
-        // test (same pattern as PlaybackBootstrapperTests).
-        await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)
+        // Each test constructs a fresh AudiobookSessionManager via the
+        // AppContainer factory — no shared-state pollution to reset.
     }
```

If setUp body is now empty other than super, delete the override entirely.

### 4. `AudiobookSessionManagerShutdownTests.swift` — verify + cleanup

Module B will have replaced `let manager = AudiobookSessionManager.shared`
with a locally-constructed instance. Module D verifies:
- No leftover `static let` references
- No leftover state-reset boilerplate in setUp/tearDown
- The 10-cycle rapid-stopPlayback test (line 50+) still works against a
  locally-constructed manager

## Acceptance criteria

- `grep "clearAllState\|registerActiveDownload\|activeDownloads(forBookID\|updateDownloadProgress\|downloadInfo(forSessionIdentifier\|registerBackgroundCompletionHandler\|callCompletionHandler" PalaceTests --include='*.swift'`
  returns 0
- `grep "AudiobookSessionManager\.shared\|PlaybackBootstrapper\.shared" PalaceTests --include='*.swift'`
  returns 0 (Module B did the heavy lifting; Module D verifies completeness)
- Module D diff: net negative LOC (target −110 to −130)
- No new `XCTSkip` annotations
- All touched test classes still pass:
  - `xcodebuild test -only-testing:PalaceTests/CarPlayTests` passes
  - `xcodebuild test -only-testing:PalaceTests/AudiobookSessionStateTransitionTests` passes
  - `xcodebuild test -only-testing:PalaceTests/PlaybackBootstrapperTests` passes
  - `xcodebuild test -only-testing:PalaceTests/AudiobookSessionManagerShutdownTests` passes
  - `xcodebuild test -only-testing:PalaceTests/DownloadWatchdogTests` passes (lives in AudiobookReliabilityTests.swift; lower in the file, unaffected by deletion)
  - `xcodebuild test -only-testing:PalaceTests/DownloadPersistenceStoreTests` passes (same file)
- `PalaceTests/MetaTests/MockIsolationLintTests` (the resetShared() enforcer)
  still passes — Module D didn't touch TPPUserAccountMock or any mock with a
  `static let shared`

## Implementer prompt

You are Module D implementer for `swarm_03acb10a`. You depend on Modules A, B,
and C — all production code is in place and the build is green.

PRE-WORK:
1. Write transcript skeleton FIRST at
   `.forgeos/swarms/swarm_03acb10a/transcripts/D-TestCleanup.md` with 5
   section headings (Read steps / Dead-API deletion / setUp cleanup /
   Verification / LOC delta).
2. Read this contract + `transcripts/triage.md` section 4 (the inventory table).
3. Read Module B's transcript — note exactly what `.shared` replacements
   were made, so Module D doesn't undo them.
4. Read each in-scope test file before editing.

This module is measured in LOC removed. Target: −110 to −130 LOC across
the 5 files. If your diff is positive or only marginally negative, re-scope —
something's off.

**Forbidden actions:**
- Touching `TPPUserAccountMock.resetShared()` or any mock with `static let shared`
- Touching `MockIsolationLintTests.swift`
- Touching production code
- Touching `AudiobookPositionPolicyTests.swift` (P0 regression gate)
- Adding `XCTSkip` annotations
- Rewriting deleted tests against the new download-tracking API (covered in
  `PalaceTests/MyBooks/` instead — cross-link in your transcript)

Validate each file's tests pass individually after edits. Run a final pass:

```bash
xcodebuild test -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/AudiobookReliabilityTests \
  -only-testing:PalaceTests/CarPlayTests \
  -only-testing:PalaceTests/AudiobookSessionStateTransitionTests \
  -only-testing:PalaceTests/PlaybackBootstrapperTests \
  -only-testing:PalaceTests/AudiobookSessionManagerShutdownTests \
  -only-testing:PalaceTests/MetaTests
```

Write transcript with LOC delta numbers. Do NOT commit, push, or dispatch agents.

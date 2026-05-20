# Contract: Logging-TestSeams (swarm_d5a3d473, Track B)

**Sequence:** Parallel with ImageLoading-Consolidation. File scopes are disjoint.
**Estimated LOC:** ~110 production + ~280 test (3 protocol shims + 3 init-injection ctors + 3 test classes refactored end-to-end).
**Phase 0 note:** You'll run in an implementer worktree off the orchestrator's `swarm/swarm_d5a3d473-scaffold` branch per the new `/swarm` skill discipline.

## Goal

Three test classes (`AudiobookFileLoggerTests`, `PersistentLoggerTests`, `DeviceSpecificErrorMonitorTests`) currently reach `.shared` directly across ~50+ sites total, defeating the production DI seam and creating cross-test state pollution (e.g., `PersistentLogger.shared` is an actor with a shared log file). Add init-injection ctors + protocol seams to the three production singletons; refactor the three test classes to construct + inject the SUT directly. Production `.shared` accessors stay (non-test call sites are unchanged), preserving binary + behavioral compat.

## Read FIRST

1. `CLAUDE.md` — TDD discipline, "Use mocks/stubs for dependencies. Never hit real singletons."
2. `Palace/Packages/PalaceLogging/Sources/PalaceLogging/Log.swift` — line 60 (`PersistentLogger.shared.log(...)` in the .error/.fault path) — this consumer keeps `.shared`
3. `Palace/Logging/ErrorLogExporter.swift` — two prod consumers of `AudiobookFileLogger.shared` + one of `PersistentLogger.shared` that keep `.shared`
4. `Palace/MyBooks/MyBooksDownloadCenter.swift:135,245,600` — example of the pattern we want: `let deviceSpecificErrorMonitor: DeviceSpecificErrorMonitor = .shared` default-arg DI
5. `PalaceTests/Mocks/MockImageCache.swift` — reference protocol-mock style

## Files in scope (edit)

### Production (3 files, ~30 LOC each)

1. **`Palace/Logging/AudiobookFileLogger.swift`** — add:
   - `protocol AudiobookFileLogging { func getLogsDirectoryUrl() -> URL?; func logEvent(forBookId: String, event: String); func retrieveLog(forBookId: String) -> String?; func retrieveLogs(forBookIds: [String]) -> [String: String] }`
   - Conformance: `class AudiobookFileLogger: AudiobookFileLogging`
   - Make ctor `internal init(logsRootURL: URL? = nil)` accepting an optional override; if nil, derive from the `.documentDirectory` path as today. This makes tests use a tempdir.
   - Keep `static let shared = AudiobookFileLogger()` — production call sites (`AudiobookDataManager.swift:113`, `ErrorLogExporter.swift:131,156`) unchanged.

2. **`Palace/Packages/PalaceLogging/Sources/PalaceLogging/PersistentLogger.swift`** — add (SPM PACKAGE — internal vs public matters):
   - `public protocol PersistentLogging { func log(level: OSLogType, tag: String, message: String) async; func retrieveAllLogs() async -> String; func clearLogs() async }`
   - Conformance: `public actor PersistentLogger: PersistentLogging`
   - Add `public init(logsRootURL: URL? = nil)` that overrides `getLogsDirectory()` (lift the private fn to `logsRootURL ?? defaultLogsRootURL()`).
   - Keep `public static let shared = PersistentLogger()` — `Log.swift:60` and `ErrorLogExporter.swift:215` unchanged.
   - Note: this file lives in the `PalaceLogging` SPM package. The new `init` must be `public`; the protocol must be `public`. Verify `Palace/Packages/PalaceLogging/Package.swift` requires no change (it doesn't — the existing target exports everything public automatically).

3. **`Palace/Utilities/DeviceSpecificErrorMonitor.swift`** — add:
   - `protocol DeviceSpecificErrorMonitoring { func initialize() async; func getDeviceID() -> String; func isEnhancedLoggingEnabled() -> Bool; func logError(_ error: Error, context: String, metadata: [String: Any]); func logDownloadFailure(book: TPPBook, reason: String, error: Error?, metadata: [String: Any]); func logNetworkFailure(url: URL?, error: Error, context: String, metadata: [String: Any]); func getDeviceInfo() -> [String: String] }`
   - Conformance: `final class DeviceSpecificErrorMonitor: DeviceSpecificErrorMonitoring`
   - Add `internal init(firebaseManager: FirebaseManager = .shared)` accepting an override; default keeps current behavior.
   - Keep `static let shared = DeviceSpecificErrorMonitor()`. Production consumers unchanged (`TPPDeveloperSettingsTableViewController.swift` is OFF-LIMITS per PR #956 collision; `MyBooksDownloadCenter.swift:135,245,600` already uses `.shared` default arg — leave it).
   - **Note**: `FirebaseManager` is itself a singleton. To make tests truly hermetic, the implementer may extract `protocol FirebaseManaging` AND make `FirebaseManager: FirebaseManaging`; tests then inject a stub `FirebaseManager` mock. If the FirebaseManager surface is too wide to mock in this swarm, the test alternative is: inject `firebaseManager` but use the real one (most tests already exercise it via `.shared`); use only the device-ID + log-no-throw paths in tests; document the FirebaseManager-mock follow-up as out-of-scope.

### Tests (3 files, ~90 LOC each — full rewrite)

4. **`PalaceTests/Logging/AudiobookFileLoggerTests.swift`** — refactor 10 `.shared` sites:
   - `setUp()`: `sut = AudiobookFileLogger(logsRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("test-audiobook-logs-\(UUID().uuidString)"))`
   - `tearDown()`: `try? FileManager.default.removeItem(at: testLogsRoot)`
   - All 10 `.shared` reads become `sut.…`
   - **Delete fluff tests** that violate `CLAUDE.md`:
     - `testShared_isNotNil` (line 26-31) — `XCTAssertNotNil(AudiobookFileLogger.shared, …)` is the banned tautology pattern (`XCTAssertNotNil(Singleton.shared)`). Replace with a real init test: `testInit_withCustomLogsRoot_usesProvidedDirectory` that constructs with a custom URL and asserts `getLogsDirectoryUrl()` returns the same URL.
   - Add new edge-case tests that the singleton-coupled version couldn't write:
     - `testLogEvent_concurrentWritesToSameBook_noDataLoss` — fire 50 `logEvent` calls in parallel via `DispatchQueue.concurrentPerform`; assert all 50 events appear in retrieved log (catches race conditions the previous test couldn't because `.shared` had file-handle reuse).
     - `testCleanup_whenOverSizeLimit_deletesOldestFiles` — write 12MB of logs across 5 books (> the 10MB limit); call `logEvent` once more; assert oldest log file is gone.
     - `testRetrieveLog_truncatesAbove1MB` — write 1.5MB to a single book; assert returned string starts with `"...[truncated"`.

5. **`PalaceTests/Logging/PersistentLoggerTests.swift`** — refactor 7 `.shared` sites:
   - `setUp()`: `sut = PersistentLogger(logsRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("test-persistent-\(UUID().uuidString)"))`
   - `tearDown()`: `await sut.clearLogs(); try? FileManager.default.removeItem(at: testLogsRoot)`
   - All 7 `.shared` reads become `await sut.…`
   - Delete `testShared_returnsSameInstance` (line 17-26) — tautology; replace with `testInit_withCustomLogsRoot_writesToProvidedDirectory` that logs once, then asserts the file exists at the injected URL.
   - **NOTE: `PalaceTests/Logging/LogTests.swift` is OUT OF SCOPE** — it tests the `Log.swift` → `PersistentLogger.shared` bridge end-to-end (6 `.shared` sites). That's testing the production `.shared` integration path; leave it alone.
   - Add new tests the singleton-coupled version couldn't write:
     - `testLog_rotatesAtMaxFileSize` — write > 5MB of log lines; assert a `palace_error.1.log` file appears (rotation).
     - `testClearLogs_removesAllRotatedFiles` — log + rotate + clear; assert no files remain in injected dir.

6. **`PalaceTests/Logging/DeviceSpecificErrorMonitorTests.swift`** — refactor 16 `.shared` sites:
   - `setUp()`: `sut = DeviceSpecificErrorMonitor()`
   - All 16 `.shared` reads become `sut.…`
   - Delete `testShared_providesFunctionalInstanceWithDeviceIDAndInfo` (line 21-29) and `testShared_returnsSameInstance` (line 31-38) — both are singleton-identity tautologies banned by `CLAUDE.md`. Replace with:
     - `testInit_returnsIndependentInstance` — `let a = DeviceSpecificErrorMonitor(); let b = DeviceSpecificErrorMonitor(); XCTAssertFalse(a === b)` — pins the DI seam.
     - `testInit_eachInstance_canQueryDeviceInfo` — both `a` and `b` return non-empty `getDeviceInfo()` independently.
   - Keep behavioral tests (`testGetDeviceID_looksLikeUUIDAndFormatIsStableAcrossCalls`, `testLogError_doesNotCrashAndPreservesMonitorState`, etc.) — they test real behavior, just retarget to `sut`.
   - If FirebaseManager stays a hard `.shared` dependency, document in the test file header: `// NOTE: This SUT still depends on FirebaseManager.shared. Follow-up: extract FirebaseManaging protocol.`

## Files OFF-LIMITS (do NOT edit)

Verbatim copy of the swarm_81b5099e frozen set + concurrent PR set (same list as ImageLoading contract):

**swarm_81b5099e frozen (concurrent swarm):**
- `Palace/Accounts/Library/` (entire dir)
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` lines 281, 309, 732, 736, 753, 781
- `Palace/SignInLogic/TPPSignInBusinessLogic+BookmarkSyncing.swift`
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift:17`
- `Palace/Accounts/User/TPPUserAccount.swift:99,102`
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift`
- `Palace/Notifications/NotificationService.swift`

**PR #956 collision (test capability uplift, in flight):**
- `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift` (has 3 `DeviceSpecificErrorMonitor.shared` refs — leave them on `.shared`; defer to follow-up swarm once PR #956 merges)
- `Palace/Audiobooks/AudiobookSessionManager.swift` and `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift`
- All other files in PR #956 — re-check before any edit in `PalaceTests/Audiobooks/`, `PalaceTests/Contract/`, `PalaceTests/Integration/`, `PalaceTests/DRM/`, `PalaceTests/CatalogDomain/`, `PalaceTests/CatalogUI/`, `Palace/Packages/PalaceCatalog/`, `Palace/Packages/PalaceNetwork/`, `Palace/Network/`, `Palace/Reader2/Bookmarks/`, `Palace/MyBooks/MyBooks/BookCell/`, `Palace/MyBooks/MyBooksDownloadCenter.swift`, `Palace/MyBooks/BookFileManager.swift`, `Palace/AppInfrastructure/AppTabHostView.swift`, `Palace/AppInfrastructure/ReaderService.swift`, `Palace/Audiobooks/AudioBookVendors+Extensions.swift`, `Palace/Audiobooks/AudiobookLoader.swift`, `Palace/Book/UI/BookDetail/`. Run `gh pr view 956 --repo ThePalaceProject/ios-core --json files --jq '.files[].path'` and treat the union as off-limits.

**PR #963 collision (Bucket A migration, in flight):**
- All paths from `gh pr view 963 --repo ThePalaceProject/ios-core --json files`.

**Track A scope (Logging-TestSeams must NOT touch):**
- `Palace/Utilities/ImageCache/`
- `Palace/Book/Models/TPPBookCoverRegistry.swift`
- `Palace/Book/Models/TPPBook+Presentation.swift`
- `Palace/Book/Models/TPPBookRegistry.swift`
- `Palace/Book/Models/TPPBook.swift`
- `Palace/AppInfrastructure/AppContainer.swift`
- `Palace/AppInfrastructure/TPPAppDelegate.swift`
- `Palace/CarPlay/CarPlayImageProvider.swift`
- `Palace/Settings/Debug/DebugSettings.swift`
- `Palace/OPDS2/Models/OPDS2PublicationExtended.swift`
- `Palace/MyBooks/MyBooks/BookListView.swift`

## Mutation gate

**Target kill rate ≥50% on all 3 changed prod files.** Logging is NOT on the critical-path strict list per `CLAUDE.md`, but pin a number so we don't regress.

```bash
python3 scripts/palace_mutate.py --file Palace/Logging/AudiobookFileLogger.swift          --tests PalaceTests/Logging/AudiobookFileLoggerTests
python3 scripts/palace_mutate.py --file Palace/Packages/PalaceLogging/Sources/PalaceLogging/PersistentLogger.swift --tests PalaceTests/Logging/PersistentLoggerTests
python3 scripts/palace_mutate.py --file Palace/Utilities/DeviceSpecificErrorMonitor.swift --tests PalaceTests/Logging/DeviceSpecificErrorMonitorTests
```

Rationale for the target: mutation kill rate must be unchanged-or-better. Previous tests exercised global state (the singleton's persisted file), which often catches mutations accidentally. The DI-injected versions need richer assertions to compensate — that's the point of the new concurrent-write, rotation, and clear-removes-rotated tests.

## pbxproj

No new prod files. New test files? No, we're rewriting in place. No `pbxproj_add_swift.rb` calls needed.

`PalaceLogging` SPM package's `PersistentLogger.swift` is a source-only edit; SPM picks it up automatically.

## Acceptance criteria

- Build green on Palace AND Palace-noDRM.
- All refactored tests pass with the new init-injection seam.
- Existing prod call sites (`Log.swift:60`, `ErrorLogExporter.swift:131,156,215`, `AudiobookDataManager.swift:113`, `MyBooksDownloadCenter.swift`) UNCHANGED — verify via grep that `.shared` references in those files have not changed.
- Mutation kill rate ≥50% on all 3 changed prod files.
- No edits outside this contract's scope.
- `LogTests.swift` (out of scope) is unchanged.
- `scripts/verify-pr.sh --quick` passes.
- LOC delta within budget: ~110 prod + ~280 test.

## Reporting back

Write `.forgeos/swarms/swarm_d5a3d473/transcripts/Logging-TestSeams.md` with: summary, files modified (with line counts), tests added/deleted/refactored, mutation kill rates per file, build + test command outputs, any FirebaseManager-mock follow-up notes.

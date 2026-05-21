# Module A — `PalaceReadingPosition` SPM package

**Status:** refined by architect 2026-05-21. See `transcripts/triage.md` Deviation 4 for the Platform-migration rationale.

## In-scope files (exclusive write)

### New SPM package at `Palace/Packages/PalaceReadingPosition/`
- `Package.swift` (template: copy `Palace/Packages/PalaceKeychain/Package.swift` shape; iOS 16+, Package v5.9)
- `Sources/PalaceReadingPosition/PositionWriter.swift` — protocol
- `Sources/PalaceReadingPosition/RemotePositionWriter.swift` — concrete impl (NOTE: renamed from `CanonicalPositionWriter` to avoid concept collision with existing `Palace/Platform/PositionSyncService` — see triage Deviation 4)
- `Sources/PalaceReadingPosition/PositionSnapshot.swift` — wire-shaped DTO
- `Sources/PalaceReadingPosition/PositionWriterError.swift` — error enum
- `Sources/PalaceReadingPosition/PositionNetworkAdapter.swift` — network seam protocol
- `Tests/PalaceReadingPositionTests/RemotePositionWriterTests.swift`
- `Tests/PalaceReadingPositionTests/PositionSnapshotTests.swift`

### Migrated files (move from `Palace/Platform/` into SPM)
- MOVE `Palace/Platform/ReadingPosition.swift` → `Sources/PalaceReadingPosition/ReadingPosition.swift` (150 LOC, no changes needed beyond `public` access)
- MOVE `Palace/Platform/PositionSyncService.swift` → `Sources/PalaceReadingPosition/PositionSyncService.swift` (155 LOC; `static let shared` becomes `public static let shared`)
- MOVE `Palace/Platform/PositionSyncServiceProtocol.swift` → `Sources/PalaceReadingPosition/PositionSyncServiceProtocol.swift`
- MOVE `Palace/Platform/CrossFormatMapping.swift` → `Sources/PalaceReadingPosition/CrossFormatMapping.swift`
- MOVE `Palace/Platform/PositionSyncRecord.swift` → `Sources/PalaceReadingPosition/PositionSyncRecord.swift`
- **LEAVE** `Palace/Platform/PositionSyncBanner.swift` in the Palace target (UI code; SwiftUI; not part of the model layer)

### Updated test imports (one-line per file edit, owned by Module A)
- MOD `PalaceTests/Platform/ReadingPositionTests.swift` — add `import PalaceReadingPosition` after `@testable import Palace`
- MOD `PalaceTests/Platform/PositionSyncServiceTests.swift` — same
- MOD `PalaceTests/Platform/CrossFormatMappingTests.swift` — same

### pbxproj edit
- `Palace.xcodeproj/project.pbxproj`: add SPM dependency on `PalaceReadingPosition` (XCRemoteSwiftPackageReference style, like `PalaceKeychain`); remove the now-moved Platform .swift files from both Sources phases (`Palace` + `Palace-noDRM`).

## Public surface (LOCKED)

```swift
public protocol PositionWriter: Sendable {
    /// Persist a position snapshot.
    /// Throttling, queue management, and background-task lifetime are the implementation's concern.
    /// Returns a server-assigned identifier when the upload completes; returns nil when throttled (queued, not yet sent) or when the network adapter chose not to send.
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID?

    /// Load the most-recent position for a book from the writer's remote source.
    /// Returns nil if no remote position exists.
    /// Does NOT apply conflict resolution against any local position — the caller owns that.
    /// Implementations MAY cache; callers MUST treat the return value as a snapshot at time of fetch.
    func load(for bookID: String) async throws -> PositionSnapshot?

    /// Cancel any pending writes for a book. Used at session teardown.
    /// Idempotent.
    func cancel(for bookID: String) async
}

public struct PositionSnapshot: Equatable, Sendable, Codable {
    public let bookID: String
    public let format: Format
    public let payload: Data        // format-specific serialized form
    public let timestamp: Date
    public let device: String

    public init(bookID: String, format: Format, payload: Data, timestamp: Date, device: String) { ... }

    public enum Format: String, Codable, Sendable {
        case audiobook
        case epubLocator
        case pdfPage
    }
}

public typealias ServerPositionID = String

public enum PositionWriterError: Error, Equatable, Sendable {
    case throttled
    case networkUnavailable
    case unauthorized
    case serverError(statusCode: Int, body: String?)
    case malformedSnapshot
    case cancelled
}

public protocol PositionNetworkAdapter: AnyObject, Sendable {
    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID
    func fetch(bookID: String) async throws -> PositionSnapshot?
}

public final class RemotePositionWriter: PositionWriter {
    public init(
        network: PositionNetworkAdapter,
        throttle: TimeInterval = 15.0,           // matches TPPLastReadPositionPoster.throttlingInterval
        clock: @escaping () -> Date = { Date() } // injectable for tests; no Swift Clock requirement (iOS 16 compat)
    )
    // PositionWriter conformance + private serial queue impl
}
```

### Re-exported migrated types (also public in the SPM)

```swift
public struct ReadingPosition: Codable, Equatable, Sendable { /* moved from Palace/Platform */ }
public enum ReadingFormat: String, Codable, Sendable { case epub, audiobook, pdf }
public struct CrossFormatMapping: Codable, Equatable, Sendable { /* moved */ }
public enum PositionSyncEvent: Sendable { case positionRecorded(ReadingPosition), syncAvailable(from: ReadingPosition, to: ReadingPosition) }
public protocol PositionSyncServiceProtocol: Sendable { /* moved */ }
public actor PositionSyncService: PositionSyncServiceProtocol { /* moved; static let shared = ... stays */ }
```

### Bridging extension (optional, ergonomic)

```swift
public extension PositionSnapshot {
    /// Convert from the cross-format ReadingPosition (for callers that already have one).
    init(from readingPosition: ReadingPosition) throws { ... }

    /// Project back into ReadingPosition for cross-format sync recording.
    func asReadingPosition() throws -> ReadingPosition { ... }
}
```

## Behavior contract (LOCKED)

1. **Throttling** — `save()` honors a configurable throttle interval (default 15.0 seconds) per `bookID`. Inside the window, returns `nil` and queues the snapshot. The MOST RECENT queued snapshot replaces older ones for the same `bookID`. After the window elapses, the queued snapshot posts on the next `save()` or via a deferred dispatched task.
2. **No cache** — `load()` always calls `network.fetch(bookID:)`. Caching is the caller's concern (book registry already caches locally). This is the simplest correct behavior and matches `TPPLastReadPositionSynchronizer`'s current loadshape.
3. **Cancellation** — `cancel(for:)` clears pending queue + outstanding network task for a book. Subsequent `save()` for the same book starts a fresh window.
4. **Concurrency** — all methods safe under concurrent calls for the same OR different `bookID`s. Impl: private serial `DispatchQueue` (matches existing `TPPLastReadPositionPoster.serialQueue` pattern).
5. **Errors** — `save()` and `load()` re-throw `PositionWriterError` from the adapter. Adapter is the place where `URLSession` errors get mapped to `PositionWriterError`.
6. **Background-task lifetime** — on iOS, `save()` wraps its dispatched network work in `UIApplication.beginBackgroundTask(...)` / `endBackgroundTask(...)` (matches existing `AudiobookDataManager.syncValues` pattern, lines 149-153). This stays in the writer; callers don't worry about it.

## Tests owned

### `RemotePositionWriterTests` (13 cases)
- `testSave_firstSnapshotInWindow_postsImmediately_returnsServerID`
- `testSave_secondSnapshotInWindow_queuesAndReturnsNil`
- `testSave_secondSnapshotInWindow_overwritesQueuedSnapshot_onlyLatestPosted`
- `testSave_thirdAfterThrottleElapsed_postsImmediately`
- `testSave_networkFailure_propagatesError`
- `testSave_cancelDuringPending_dropsQueuedSnapshot_noPostFires`
- `testLoad_returnsSnapshotFromAdapter`
- `testLoad_adapterReturnsNil_returnsNil`
- `testLoad_adapterThrows_propagatesError`
- `testCancel_isIdempotent_canBeCalledTwice`
- `testCancel_differentBookID_doesNotAffectOtherQueue`
- `testConcurrent_saveDifferentBookIDs_doNotInterfere`
- `testConcurrent_saveSameBookID_serializesProperly_noDataRace`

### `PositionSnapshotTests` (5 cases)
- `testEquatable_sameFields_returnsTrue`
- `testEquatable_differentTimestamp_returnsFalse`
- `testCodable_audiobookFormat_roundtrips`
- `testCodable_epubLocatorFormat_roundtrips`
- `testCodable_pdfPageFormat_roundtrips`

## Acceptance criteria

- `Package.swift` declares iOS 16+ deployment target.
- SPM package builds standalone: `cd Palace/Packages/PalaceReadingPosition && swift build` succeeds.
- `swift test` inside the package directory: 18 tests pass.
- `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds with the new SPM dep.
- `PalaceTests/Platform/{ReadingPositionTests,PositionSyncServiceTests,CrossFormatMappingTests}.swift` all pass with the `import PalaceReadingPosition` addition.
- ≥80% mutation kill rate on `RemotePositionWriter.swift` (`palace_mutate.py --diff-only`).
- All migrated public types have `Sendable` conformance.
- No imports of `Foundation` cycle inward to the SPM (adapter protocol stays in SPM; concrete `URLSession`-using impl lives in Palace target as an `extension RemotePositionWriter` or a separate concrete adapter).

## Implementer prompt

You are Module A implementer for `swarm_f4fbef9c`. You're creating a NEW SPM package at `Palace/Packages/PalaceReadingPosition/` AND migrating 5 existing files from `Palace/Platform/` into it (see "Migrated files" section above). The migration is the key non-obvious part — read the architect's `transcripts/triage.md` Deviation 4 before starting.

**Step order (do not skip):**
1. Write `transcripts/A-PalaceReadingPositionSPM.md` skeleton FIRST (5 section headings, save). Swarm 1 lesson: 2 implementer streams timed out at transcript-write step.
2. Create the SPM package skeleton (Package.swift mirroring `Palace/Packages/PalaceKeychain/Package.swift`).
3. Write the 5 new files (PositionWriter.swift, RemotePositionWriter.swift, PositionSnapshot.swift, PositionWriterError.swift, PositionNetworkAdapter.swift).
4. Move the 5 Platform files into the SPM, marking types `public`. Use `git mv` to preserve history.
5. Update the 3 PalaceTests/Platform test-file imports.
6. Update `Palace.xcodeproj/project.pbxproj` to add the SPM dependency AND remove the now-moved Platform .swift entries. Use `ruby scripts/pbxproj_add_swift.rb` analog if it supports SPM; otherwise hand-edit minimally.
7. Run `swift test` in the package directory; iterate to green.
8. Run `xcodebuild ... build` to verify project compiles.
9. Run mutation testing on `RemotePositionWriter.swift`; iterate to ≥80% kill rate.
10. Fill out the transcript with files added/moved, test count, mutation rate, key decisions, and any gaps for B/C consumers.

Throttle window default (15.0s) is locked. `TPPLastReadPositionPoster.throttlingInterval` is the source. No `Duration`/`Clock` API — use `TimeInterval` and `() -> Date` for iOS 16 compat.

`RemotePositionWriter` is a `final class` with serial `DispatchQueue`, NOT an `actor`. Reason: it owns iOS background-task lifetime via `UIBackgroundTaskIdentifier`, which is fiddly inside an actor (UIApplication APIs are not actor-isolated). The existing `TPPLastReadPositionPoster.serialQueue` pattern is the template.

The conflict-resolution rule (which side wins when local and remote disagree) is **caller responsibility**. The writer's `load()` returns what's on the server; the caller (TPPLastReadPositionSynchronizer for EPUB, AudiobookBookmarkBusinessLogic for audiobook) owns the merge.

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds; `swift test` inside the package passes 18 tests; `python3 scripts/palace_mutate.py --file Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/RemotePositionWriter.swift --tests PalaceReadingPositionTests/RemotePositionWriterTests --diff-only` shows ≥80% kill rate.

Do NOT commit. Do NOT push. Stage for the integrator.

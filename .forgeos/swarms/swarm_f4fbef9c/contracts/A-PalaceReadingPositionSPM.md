# Module A — `PalaceReadingPosition` SPM package

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

New SPM package at `Palace/Packages/PalaceReadingPosition/`:
- `Package.swift`
- `Sources/PalaceReadingPosition/PositionWriter.swift`
- `Sources/PalaceReadingPosition/CanonicalPositionWriter.swift`
- `Sources/PalaceReadingPosition/PositionSnapshot.swift`
- `Sources/PalaceReadingPosition/PositionWriterError.swift`
- `Tests/PalaceReadingPositionTests/CanonicalPositionWriterTests.swift`
- `Tests/PalaceReadingPositionTests/PositionSnapshotTests.swift`

Plus `Palace.xcodeproj/project.pbxproj` — add SPM dependency (use `scripts/pbxproj_add_swift.rb` analog for SPM, or manual `xcodeproj` Ruby edit). Same pattern as `PalaceKeychain`/`PalaceCatalog`/etc.

## Public surface (architect to lock)

```swift
public protocol PositionWriter: AnyObject {
    /// Persist a position snapshot. Throttling, retry, and queue management are the implementation's concern.
    /// Returns a server-side identifier when the upload succeeds; nil when throttled (not yet sent) or local-only.
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID?

    /// Load the canonical position for a book. Returns nil if no position exists.
    /// Implementations MAY return cached values; staleness is the writer's contract, not the caller's.
    func load(for bookID: String) async -> PositionSnapshot?

    /// Cancel any pending writes for a book. Used at session teardown.
    /// Idempotent.
    func cancel(for bookID: String)
}

public struct PositionSnapshot: Equatable, Sendable {
    public let bookID: String
    public let format: Format  // .audiobook(toolkit-trackPosition serialized) | .epubLocator(Readium) | .pdfPage
    public let payload: Data  // format-specific serialized form
    public let timestamp: Date
    public let device: String

    public enum Format: String, Codable, Sendable {
        case audiobook
        case epubLocator
        case pdfPage
    }
}

public typealias ServerPositionID = String

public enum PositionWriterError: Error, Equatable {
    case throttled
    case networkUnavailable
    case unauthorized
    case serverError(statusCode: Int, body: String?)
    case malformedSnapshot
    case cancelled
}

public final class CanonicalPositionWriter: PositionWriter {
    public init(network: PositionNetworkAdapter, throttle: Duration = .seconds(15), clock: any Clock<Duration> = ContinuousClock())
    // ...
}

public protocol PositionNetworkAdapter: AnyObject {
    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID
    func fetch(bookID: String) async throws -> PositionSnapshot?
}
```

## Behavior contract

1. **Throttling** — `save()` honors a configurable throttle interval (default 15s) per `bookID`. Inside the window, returns `nil` and queues the snapshot. The MOST RECENT queued snapshot replaces older ones for the same `bookID`.
2. **Cache-on-load** — `load()` first checks an in-memory LRU; on miss calls `network.fetch()` and caches.
3. **Cancellation** — `cancel(for:)` clears pending queue + outstanding network task for a book. Subsequent `save()` for the same book starts a fresh window.
4. **Concurrency** — all methods must be safe under concurrent calls for the same OR different `bookID`s. Use `actor` or `@MainActor` + serial sync queue (architect's call — but the existing audiobook `syncQueue` pattern is one option).
5. **Errors** — `save()` re-throws `PositionWriterError` from the adapter; does NOT silently swallow. Caller decides logging/UI.

## Tests owned

### CanonicalPositionWriterTests (architect to enumerate)
- `testSave_firstSnapshotInWindow_postsImmediately`
- `testSave_secondSnapshotInWindow_queuesAndReturnsNil`
- `testSave_secondSnapshotInWindow_overwritesQueuedSnapshot`
- `testSave_thirdAfterThrottleElapsed_postsImmediately`
- `testSave_networkFailure_propagatesError`
- `testSave_cancelDuringPending_dropsQueuedSnapshot`
- `testLoad_cacheMiss_callsFetchAndCaches`
- `testLoad_cacheHit_doesNotCallFetch`
- `testCancel_isIdempotent`
- `testCancel_differentBookID_doesNotAffectOtherQueue`
- `testConcurrent_saveDifferentBookIDs_doNotInterfere`

### PositionSnapshotTests (smaller — value semantics)
- `testEquatable_sameFields_returnsTrue`
- `testEquatable_differentTimestamp_returnsFalse`
- `testCodable_audiobookFormat_roundtrips`
- `testCodable_epubLocatorFormat_roundtrips`

## Acceptance criteria

- `Package.swift` declares iOS 16+ deployment target
- SPM package builds standalone via `swift build` from `Palace/Packages/PalaceReadingPosition/`
- ≥80% mutation kill rate on `CanonicalPositionWriter` (the throttle + cancel + cache are the load-bearing logic)
- All public types have `Sendable` conformance where appropriate (compiler enforces given strict-concurrency settings)
- No `import Foundation` cycles — adapter protocol stays in SPM, concrete impls live in Palace target

## Implementer prompt (architect to refine)

You are Module A implementer for `swarm_f4fbef9c`. You're creating a NEW SPM package at `Palace/Packages/PalaceReadingPosition/`. Mirror the structure of existing `Palace/Packages/PalaceKeychain/` or `Palace/Packages/PalaceCatalog/` for `Package.swift` shape.

The public surface above is the contract for Modules B and C — DO NOT change the protocol signatures without updating this file and notifying the architect/integrator.

`CanonicalPositionWriter` is the workhorse. Implement it as an `actor` if iOS 16 supports your usage; otherwise a final class with a serial `DispatchQueue` is acceptable.

The throttle window default (15s) matches the existing `TPPLastReadPositionPoster.throttlingInterval`. Verify that value by reading `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` before starting.

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds with the new SPM dep; `swift test` inside the package directory passes the 13+ named tests; `python3 scripts/palace_mutate.py --file Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/CanonicalPositionWriter.swift --tests PalaceReadingPositionTests/CanonicalPositionWriterTests --diff-only` shows ≥80% kill rate.

When done, write `.forgeos/swarms/swarm_f4fbef9c/transcripts/A-PalaceReadingPositionSPM.md` (write the transcript skeleton FIRST, before final tests — Swarm 1 lesson: 2 implementer streams timed out at transcript-write step). Include: files added, public surface confirmed, test count, mutation kill rate, key decisions, any gaps for B/C consumers.

Do NOT commit. Do NOT push. Stage for the integrator.

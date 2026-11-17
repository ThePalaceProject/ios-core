//
//  DownloadTaskPersistence.swift
//  Palace
//
//  Durable downloads. DownloadStateManager's task<->book maps are in-memory,
//  but iOS keeps background downloads running across app death. This file
//  persists a crash-surviving mirror and the pure launch reconciliation that
//  decides what to do with each record given the live URLSession tasks and the
//  registry's per-book state. Registry state is the source of truth; a live
//  task is always adopted, never restarted or failed.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

// MARK: - Types

/// Durable record of one in-flight download task. Codable/Sendable so it can be
/// JSON-persisted and fed to the pure reconciler across the actor boundary.
struct PersistedDownloadRecord: Codable, Sendable, Equatable {
    let bookID: String
    let taskIdentifier: Int
    let downloadURL: URL
    let account: String
    let expectedBytes: Int64?
    let startedAt: Date
}

/// The decision the launch reconciler makes for a single persisted record.
enum ReconcileDecision: Equatable {
    /// Task is still running — re-adopt it into the in-memory maps so its
    /// completion callbacks route to the right book. No second task started.
    case adopt(bookID: String, taskIdentifier: Int)
    /// Task died but the registry still wants the content — restart the download.
    case restart(bookID: String)
    /// Task died and the registry already records the download as failed —
    /// pin the terminal failed state and drop the stale record.
    case markFailed(bookID: String)
    /// Nothing to do (completed while suspended, or the book was returned /
    /// unregistered) — just drop the stale record.
    case cleanup(bookID: String)
}

// MARK: - Pure reconciliation

enum DownloadReconciliation {

    /// The live task this record should be adopted onto, or nil.
    ///
    /// Matches on URL and returns the live identifier, not the persisted one,
    /// so it works whether or not a background session preserves
    /// `taskIdentifier` across relaunch (unsettled on device): an exact
    /// identifier+URL match wins, otherwise a unique URL match. Requiring both
    /// would refuse a still-running renumbered download; `.restart` is inert
    /// for a `.downloading` book, so it would end as `.downloadFailed` and the
    /// patron would have to retry.
    ///
    /// Two live tasks on one URL are ambiguous and neither is adopted unless
    /// one carries this record's exact identifier.
    ///
    /// A book id in `URLSessionTask.taskDescription` would be an exact
    /// discriminator, but that field holds the dispatching account (PP-4986).
    /// Add a `book=` key through `TaskProvenance`; assigning `taskDescription`
    /// directly would erase the account and reopen a credential leak.
    private static func adoptableTask(
        for record: PersistedDownloadRecord,
        in liveTasks: [Int: URL]
    ) -> Int? {
        if liveTasks[record.taskIdentifier] == record.downloadURL {
            return record.taskIdentifier
        }
        let sameURL = liveTasks.filter { $0.value == record.downloadURL }.map(\.key)
        return sameURL.count == 1 ? sameURL[0] : nil
    }

    /// - Parameter liveTasks: still-running download tasks, keyed by task
    ///   identifier, valued by the URL that task is actually fetching.
    ///
    ///   PP-4997: identifiers alone are not enough. `taskIdentifier` is unique
    ///   only within its session and restarts from 1 after relaunch, so a stale
    ///   record could adopt a different book's task and deliver the wrong title.
    ///   The URL is the discriminator; the identifier is only a hint.
    ///
    ///   Do not cancel an unadoptable task. It can be a real in-flight download
    ///   (contested URL, a start that recorded no URL, a future start path). An
    ///   orphan costs bandwidth; `MyBooksDownloadCenter` ignores unmapped
    ///   identifiers, so its bytes are discarded rather than misrouted.
    ///
    ///   Invariant: within one pass, a download URL identifies at most one book.
    ///   Two books can share a URL (one open-access title in two catalogs), so
    ///   records with a contested URL are refused adoption. This is enforced
    ///   for records only: `contestedURLs` cannot see a live task with no
    ///   record, so every path that starts a download must persist a record
    ///   (PP-5023 covers `followAcquisitionLink` and the bearer-token hop;
    ///   `persistStartedTaskRecord` still writes nothing when it resolves no
    ///   URL). `DownloadReissuePersistenceTests` pins the known re-issue paths.
    ///
    /// Pure: no URLSession, no I/O.
    ///
    /// - Note: `registryStates` carries the per-book `TPPBookState`, not the
    ///   whole-registry load state.
    static func reconcile(
        persisted: [PersistedDownloadRecord],
        liveTasks: [Int: URL],
        registryStates: [String: TPPBookState]
    ) -> [ReconcileDecision] {
        // Book ids sharing a download URL. Their records cannot be told apart by
        // the discriminator, so none of them may be adopted (see the invariant
        // above). Computed once for the whole pass rather than per record.
        var bookIDsByURL: [URL: Set<String>] = [:]
        for record in persisted {
            bookIDsByURL[record.downloadURL, default: []].insert(record.bookID)
        }
        let contestedURLs = Set(bookIDsByURL.filter { $0.value.count > 1 }.map(\.key))

        return persisted.map { record in
            // A still-running task is adopted, never restarted or failed. A
            // colliding identifier on a different URL is not this record's task;
            // the registry decides, as for a dead task.
            if !contestedURLs.contains(record.downloadURL),
               let liveID = adoptableTask(for: record, in: liveTasks) {
                return .adopt(bookID: record.bookID, taskIdentifier: liveID)
            }

            // Task is dead. The registry (source of truth) decides.
            switch registryStates[record.bookID] {
            case .some(.downloadSuccessful), .some(.used):
                // Completed while suspended (or the registry heal already
                // promoted it) — nothing to restart; drop the record.
                return .cleanup(bookID: record.bookID)

            case .some(.downloading), .some(.downloadNeeded), .some(.SAMLStarted):
                // The book still wants its content but the task is gone — restart.
                return .restart(bookID: record.bookID)

            case .some(.downloadFailed):
                // Already failed — keep the terminal state, drop the record.
                return .markFailed(bookID: record.bookID)

            case .some(.unregistered), .some(.holding), .some(.returning),
                 .some(.unsupported), .none:
                // The book no longer wants this download — drop the stale record.
                return .cleanup(bookID: record.bookID)
            }
        }
    }

    /// Launch reconciliation sequence: registry-loaded gate → load persisted →
    /// live tasks → registry state → reconcile → apply. Closures are injected so
    /// production and the launch-order contract test run the same code. The
    /// gate comes first: reconciliation never runs before the registry loads.
    static func runLaunchReconciliation(
        isRegistryLoaded: () -> Bool,
        loadPersisted: () -> [PersistedDownloadRecord],
        liveTasks: () async -> [Int: URL],
        registryState: (String) -> TPPBookState,
        apply: (ReconcileDecision) async -> Void
    ) async {
        guard isRegistryLoaded() else {
            Log.info(#file, "Launch reconciliation skipped — registry not loaded yet")
            return
        }
        let persisted = loadPersisted()
        guard !persisted.isEmpty else { return }

        let live = await liveTasks()

        var states: [String: TPPBookState] = [:]
        for record in persisted {
            states[record.bookID] = registryState(record.bookID)
        }

        let decisions = reconcile(
            persisted: persisted,
            liveTasks: live,
            registryStates: states
        )
        for decision in decisions {
            await apply(decision)
        }
    }
}

// MARK: - Durable store

/// Crash-durable mirror of the in-flight download records, in its own JSON file
/// in Application Support (not the registry file). Read at launch
/// reconciliation and, since PP-4978, once per re-issue by
/// `BackgroundDownloadHandler.startedForAccount(for:delegate:)`, so its read
/// cost matters at runtime.
///
/// `@unchecked Sendable`: the sole mutable state is the on-disk file, guarded by
/// `lock`; every accessor takes the lock for the read-modify-write.
final class DownloadTaskPersistence: @unchecked Sendable {

    private let fileURL: URL
    private let lock = NSLock()

    /// Default location: `<Application Support>/download-tasks.json`. Tests inject
    /// a temp URL so they never touch the real store.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if TPPProcessInfo.isRunningTests {
            // Never touch the real Application Support store from the suite —
            // incidental writes (e.g. an existing test that starts a download)
            // land in a throwaway temp dir instead.
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PalaceTests-DownloadTasks", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("download-tasks.json")
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("download-tasks.json")
        }
    }

    /// All persisted records. Never throws — a missing or corrupt file yields
    /// an empty array (durability must not become a launch crash).
    func all() -> [PersistedDownloadRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Upsert one record, keyed by `bookID` (one in-flight download per book).
    func record(_ record: PersistedDownloadRecord) {
        lock.lock(); defer { lock.unlock() }
        var records = loadLocked()
        records.removeAll { $0.bookID == record.bookID }
        records.append(record)
        saveLocked(records)
    }

    /// Read-modify-write one book's record under a SINGLE lock acquisition.
    ///
    /// `all()` followed by `record(_:)` takes the lock twice, so a concurrent
    /// `remove` landing between them resurrects a deleted record. Callers that
    /// derive a new record from the existing one must use this instead.
    ///
    /// `transform` receives the current record for `bookID` (or nil) and
    /// returns the record to store. It runs while the non-recursive lock is
    /// held, so it must not call back into this store.
    ///
    /// Precondition (not enforced): `transform` returns a record for `bookID`;
    /// a foreign id would leave a stale record under `bookID`. The only caller,
    /// `DownloadStateManager.persistReissuedTask`, always does.
    ///
    /// - Parameter inheritingFrom: read the record under THIS id and write under
    ///   `bookID`. They differ when a re-issue re-registers the download under a
    ///   book parsed from the server whose identifier is not the original's.
    func upsert(
        bookID: String,
        inheritingFrom sourceBookID: String? = nil,
        transform: (PersistedDownloadRecord?) -> PersistedDownloadRecord
    ) {
        lock.lock(); defer { lock.unlock() }
        var records = loadLocked()
        let sourceID = sourceBookID ?? bookID
        // Fall back to the TARGET's own record when the source has none, so an
        // id-changing re-issue cannot blank an account that is already correct
        // under the target id.
        let existing = records.first { $0.bookID == sourceID }
            ?? records.first { $0.bookID == bookID }
        let updated = transform(existing)
        records.removeAll { $0.bookID == updated.bookID }
        records.append(updated)
        saveLocked(records)
    }

    /// Remove the record for a book on terminal completion. No-op if absent.
    func remove(bookID: String) {
        lock.lock(); defer { lock.unlock() }
        var records = loadLocked()
        let before = records.count
        records.removeAll { $0.bookID == bookID }
        if records.count != before {
            saveLocked(records)
        }
    }

    /// Drop everything (account reset).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        saveLocked([])
    }

    // MARK: - Locked helpers (caller holds `lock`)

    private func loadLocked() -> [PersistedDownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PersistedDownloadRecord].self, from: data)) ?? []
    }

    private func saveLocked(_ records: [PersistedDownloadRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            Log.error(#file, "Failed to encode \(records.count) download records")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(#file, "Failed to persist download records: \(error.localizedDescription)")
        }
    }
}

/// Reference box so the launch-reconciliation orchestrator can snapshot live
/// URLSession tasks inside the `getAllTasks` completion (non-`Sendable` task
/// objects never cross the continuation boundary) and hand them to `apply`.
///
/// `@unchecked Sendable`: the storage is `private` and every accessor takes the
/// lock, for reads as well as writes, because the type is module-visible and
/// cannot rely on all writes happening inside one `getAllTasks` completion.
final class LiveDownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [Int: URLSessionDownloadTask] = [:]
    /// URL each live task is fetching, captured INSIDE the `getAllTasks`
    /// completion so no non-Sendable task is touched afterwards.
    private var urls: [Int: URL] = [:]

    /// URLs of every captured task. A copy, taken under the lock.
    var capturedURLs: [Int: URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    /// Captured tasks. A copy, taken under the lock.
    var capturedTasks: [Int: URLSessionDownloadTask] {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    /// Record a live task and the URL it is fetching.
    ///
    /// Falls back to `currentRequest`: a redirected task can report a nil
    /// `originalRequest`. Returns false when the task has no URL at all; it can
    /// never be adopted, and the caller logs it.
    ///
    /// The argument binding below is untestable: a test-constructed task
    /// reports the same URL for both requests. The decision itself is covered
    /// through `downloadURL(original:current:)`.
    @discardableResult
    func capture(_ task: URLSessionDownloadTask) -> Bool {
        let id = task.taskIdentifier
        let url = Self.downloadURL(original: task.originalRequest?.url,
                                   current: task.currentRequest?.url)
        lock.lock()
        defer { lock.unlock() }
        map[id] = task
        guard let url else { return false }
        urls[id] = url
        return true
    }

    /// The URL a live task is fetching, given what its two requests report.
    ///
    /// Split out so the branches can be tested; a real `URLSessionDownloadTask`
    /// cannot be built to reach them.
    ///
    /// `originalRequest` wins because it survives a redirect: `currentRequest`
    /// holds the redirected URL, and the persisted record carries the URL the
    /// download STARTED from. Preferring `currentRequest` would stop a
    /// redirected download from ever matching its own record.
    static func downloadURL(original: URL?, current: URL?) -> URL? {
        original ?? current
    }
}

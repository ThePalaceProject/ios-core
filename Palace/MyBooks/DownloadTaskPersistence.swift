//
//  DownloadTaskPersistence.swift
//  Palace
//
//  Reliability WS-A — Durable Downloads (seam S1).
//
//  The task<->book maps in DownloadStateManager are in-memory only: a kill
//  mid-download loses them, so an actually-still-running background task (iOS
//  keeps background downloads alive across app death) is orphaned — the app
//  never re-adopts it. This file adds the durable, crash-surviving mirror plus
//  the PURE reconciliation that decides, at launch, what to do with each
//  persisted record given the set of still-live URLSession tasks and the
//  registry's per-book state.
//
//  Ownership contract (seam S1): registry state is the source of truth for a
//  book's lifecycle; we reconcile URLSession tasks TO it. We only heal a
//  persisted record whose task is NOT live — a live task is always adopted,
//  never restarted or failed (INV-4).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - Seam S1 types

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

    /// PURE — no URLSession, no I/O. Unit-testable exhaustively over the
    /// {live task / dead task} × {registry state} matrix.
    ///
    /// - Note: `registryStates` is keyed by book id and carries the *per-book*
    ///   lifecycle state (`TPPBookState`), which is the source of truth for the
    ///   book's download lifecycle. (Seam S1's draft typed this as
    ///   `TPPBookRegistry.RegistryState`, but that enum is the whole-registry
    ///   load state — `.unloaded/.loading/.loaded/...` — not per-book. INV-4's
    ///   healing contract is explicitly about the per-book `.downloading`
    ///   record, so the per-book `TPPBookState` is the correct input.)
    /// The live task this record should be adopted onto, or nil.
    ///
    /// Matches on URL, and returns the LIVE identifier — not the persisted one.
    /// That distinction is the whole fix, and it is deliberately agnostic about a
    /// question nobody has settled on device: whether a background session
    /// preserves `taskIdentifier` across an app relaunch.
    ///
    ///   - if identifiers ARE preserved, the record's own task is found by the
    ///     exact branch and the live identifier equals the persisted one;
    ///   - if identifiers are RENUMBERED, the exact branch misses and the unique
    ///     URL branch still finds the record's own task under its new identifier.
    ///
    /// Requiring identifier AND url (the first attempt at PP-4997) is only correct
    /// in the first world. In the second it refuses to adopt a download that is
    /// still running, falls through to `.restart`, and `startDownload` has no
    /// live-task guard — so it would cause the double-start INV-4 exists to
    /// prevent, in the COMMON case, while fixing a rare one.
    ///
    /// Ambiguity is declined rather than guessed: two live tasks on the same URL
    /// cannot be told apart, so unless one of them carries this record's exact
    /// identifier, neither is adopted and the registry restarts the book.
    ///
    /// The exact discriminator would be `URLSessionTask.taskDescription` carrying
    /// the book id — it survives relaunch and needs no inference. Nothing sets it
    /// today; that is the follow-up, and it makes this helper collapse to one
    /// lookup.
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
    ///   PP-4997: this used to be a bare `Set<Int>` of identifiers, and that is
    ///   not enough to identify a download. `URLSessionTask.taskIdentifier` is
    ///   documented as unique only *within its session* — a relaunch creates a
    ///   new session and numbering restarts from 1. A leftover record for task 1
    ///   would then match a DIFFERENT book's live task 1, and the adoption routed
    ///   that download's progress and its finished file to the wrong title. It
    ///   failed silently: no error, no alert, no log line, and the patron simply
    ///   received a book they did not ask for.
    ///
    ///   The URL is the discriminator and the record already carried it; it was
    ///   just never read. The identifier is only a hint: a record is adopted
    ///   when some live task is fetching its URL, and the adoption carries THAT
    ///   task's identifier. So this is correct whether or not identifiers happen
    ///   to survive a relaunch — a question this code no longer has to answer.
    ///
    ///   LOAD-BEARING INVARIANT: within one reconcile pass, a download URL
    ///   identifies at most one book. The URL is only a safe discriminator
    ///   because of that. Two books CAN legitimately share one — the same
    ///   open-access title surfaced by two catalogs — so the invariant is
    ///   enforced here rather than assumed: records whose URL is claimed by
    ///   more than one book are refused adoption. Adopting them would route the
    ///   finished file to whichever book wrote `taskIdentifierToBook` last,
    ///   which is PP-4997's own failure mode re-entered through its fix.
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
            // INV-4: a still-running background task is adopted, never restarted
            // (no double-start) and never spuriously failed.
            //
            // PP-4997: match on url, adopt the LIVE identifier. A colliding
            // identifier fetching a different url is NOT this record's task;
            // fall through and let the registry decide, exactly as it would for
            // a task that had died.
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

    /// PURE orchestrator for the launch reconciliation sequence. Encapsulates
    /// the ORDER contract (registry-loaded gate → load persisted → live tasks →
    /// read registry state → reconcile → apply) behind injected closures so the
    /// production wiring in `MyBooksDownloadCenter` and the launch-order
    /// contract-snapshot test drive the same code. INV-4: the registry-loaded
    /// gate is FIRST — reconciliation never runs before the registry has loaded.
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

/// Crash-durable mirror of the in-flight download records. Persists to its OWN
/// JSON file in Application Support — deliberately NOT the registry file (WS-B
/// owns that). The in-memory `SafeDictionary`s in `DownloadStateManager` remain
/// the hot cache. This store was originally consulted only at launch
/// reconciliation; as of PP-4978 it is ALSO read on the download path, to
/// recover which account a download was started under when re-issuing its
/// request (`BackgroundDownloadHandler.startedForAccount(for:delegate:)`).
/// That read is once per re-issue, not per progress callback, but it is no
/// longer launch-only — a change to this file's read cost now has a runtime
/// consumer.
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
/// Lives here rather than in MyBooksDownloadCenter because it is reconciliation
/// infrastructure, not download-center state — and the hub is frozen under the
/// decomposition ratchet, which asks for extraction rather than growth.
final class LiveDownloadTaskBox: @unchecked Sendable {
    var map: [Int: URLSessionDownloadTask] = [:]
    /// URL each live task is fetching, captured INSIDE the `getAllTasks`
    /// completion so no non-Sendable task is touched afterwards.
    var urls: [Int: URL] = [:]

    /// Record a live task and the URL it is fetching.
    ///
    /// Falls back to `currentRequest`: a redirected task can report a nil
    /// `originalRequest`, and dropping it would silently decline to adopt a
    /// download that is still running. Returns false when the task has no URL
    /// at all — it can never be adopted, and the caller logs rather than
    /// dropping it in silence.
    @discardableResult
    func capture(_ task: URLSessionDownloadTask) -> Bool {
        let id = task.taskIdentifier
        map[id] = task
        guard let url = task.originalRequest?.url ?? task.currentRequest?.url else {
            return false
        }
        urls[id] = url
        return true
    }
}

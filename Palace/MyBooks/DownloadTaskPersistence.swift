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
    static func reconcile(
        persisted: [PersistedDownloadRecord],
        liveTaskIdentifiers: Set<Int>,
        registryStates: [String: TPPBookState]
    ) -> [ReconcileDecision] {
        persisted.map { record in
            // INV-4: a still-running background task is adopted, never restarted
            // (no double-start) and never spuriously failed.
            if liveTaskIdentifiers.contains(record.taskIdentifier) {
                return .adopt(bookID: record.bookID, taskIdentifier: record.taskIdentifier)
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
        liveTaskIdentifiers: () async -> Set<Int>,
        registryState: (String) -> TPPBookState,
        apply: (ReconcileDecision) async -> Void
    ) async {
        guard isRegistryLoaded() else {
            Log.info(#file, "Launch reconciliation skipped — registry not loaded yet")
            return
        }
        let persisted = loadPersisted()
        guard !persisted.isEmpty else { return }

        let live = await liveTaskIdentifiers()

        var states: [String: TPPBookState] = [:]
        for record in persisted {
            states[record.bookID] = registryState(record.bookID)
        }

        let decisions = reconcile(
            persisted: persisted,
            liveTaskIdentifiers: live,
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
/// the hot cache; this cold store is consulted only at launch reconciliation.
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

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
    /// still running and falls through to `.restart`.
    ///
    /// That is NOT the double-start INV-4 forbids, and an earlier version of this
    /// comment wrongly said it was. `startDownload` returns early on
    /// `.downloading` (DownloadStartCoordinator), which is the state a book
    /// killed mid-download is in, so the restart is inert there. The cost is
    /// quieter: nothing maps the live task's identifier to a book, so its
    /// callbacks are dropped, the book sits in `.downloading` with no task, and
    /// registry sync later heals it to `.downloadFailed`. A download that was
    /// running fine becomes a failure the patron has to retry.
    ///
    /// Ambiguity is declined rather than guessed: two live tasks on the same URL
    /// cannot be told apart, so unless one of them carries this record's exact
    /// identifier, neither is adopted. The same inertness applies — `.restart`
    /// will not re-drive a `.downloading` book, so the practical outcome is the
    /// heal to `.downloadFailed` above, not a fresh download.
    ///
    /// The exact discriminator would be `URLSessionTask.taskDescription` carrying
    /// the book id — it survives relaunch and needs no inference, and it makes
    /// this helper collapse to one lookup.
    ///
    /// CAUTION: that field is no longer free. PP-4986 stores the dispatching
    /// account there via `TaskProvenance` (`TPPNetworkExecutor.swift`), encoded as
    /// `key=value;` pairs precisely so a book id can join it. Add a `book=` key
    /// through `TaskProvenance` — do NOT assign `task.taskDescription` directly,
    /// which would silently erase the account and reopen a credential leak.
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
    ///   DO NOT "OPTIMIZE" THIS BY CANCELLING THE UNADOPTABLE TASK. It reads as
    ///   an obvious improvement — the task is orphaned, so why leave it running?
    ///   Because a live task here can be a REAL in-flight download. PP-5023 made
    ///   `followAcquisitionLink` and the bearer-token hop persist, which removes
    ///   the commonest case, but it does NOT make cancelling safe: a task is also
    ///   unadoptable when its URL is contested, when `persistStartedTaskRecord`
    ///   found no URL to record, and on any path added after this comment was
    ///   written. An orphan costs bandwidth; cancelling costs the patron a book.
    ///   Leave it: `MyBooksDownloadCenter` early-returns on an unmapped
    ///   identifier, so the orphan's bytes are discarded rather than misrouted.
    ///
    ///   LOAD-BEARING INVARIANT: within one reconcile pass, a download URL
    ///   identifies at most one book. The URL is only a safe discriminator
    ///   because of that. Two books CAN legitimately share one — the same
    ///   open-access title surfaced by two catalogs — so the invariant is
    ///   enforced here for records, and NOT enforced for live tasks — a limit
    ///   worth stating precisely, because an earlier version of this comment
    ///   overclaimed. Records whose URL is claimed by more than one book are
    ///   refused adoption; adopting them would route the finished file to
    ///   whichever book wrote `taskIdentifierToBook` last, which is PP-4997's
    ///   own failure mode re-entered through its fix.
    ///
    ///   WHAT IT RESTS ON: `contestedURLs` is computed from `persisted` alone,
    ///   because that is all this function is given, so the guard can only see a
    ///   live task that has a record. Two paths used to create tasks without one
    ///   — `followAcquisitionLink` and the bearer-token hop in
    ///   `RightsManagementDispatcher` — and a book whose record named such a
    ///   task's URL adopted that download outright: a wrong adoption, not a
    ///   decline. Both persist as of PP-5023, which closes the two known holes.
    ///   It does NOT make the guard complete: `persistStartedTaskRecord` writes
    ///   nothing when it can resolve no URL, so that arm still produces a live
    ///   unrecorded task, and any future start path reopens the same gap.
    ///
    ///   That completeness is a property of the CALLERS, not of this function,
    ///   and nothing here can enforce it. Any future path that starts a download
    ///   in this session must persist a record, or it reopens the same hole.
    ///   `DownloadReissuePersistenceTests` pins the two known re-issue paths and
    ///   carries the control that demonstrates the failure they used to cause.
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

    /// Read-modify-write one book's record under a SINGLE lock acquisition.
    ///
    /// `all()` followed by `record(_:)` takes the lock twice, so a concurrent
    /// `remove`/`removeAll` landing between them resurrects a record that was
    /// meant to be gone, and two re-issues for one book can interleave. Callers
    /// that derive a new record FROM the existing one (the mid-flight re-issue
    /// paths) must use this instead.
    ///
    /// `transform` receives the current record for `bookID`, or nil, and returns
    /// the record to store. It is NON-optional deliberately: an earlier draft let
    /// it return nil to mean "leave the store alone", but no caller used that and
    /// no test or mutant could reach the branch — the third instance in this
    /// changeset of a guard nothing can falsify. A caller that wants to leave the
    /// store alone should not call `upsert`.
    ///
    /// `transform` runs WHILE THE LOCK IS HELD and `lock` is not recursive, so it
    /// must not call back into this store — no `all()`, `record`, `remove`, or a
    /// nested `upsert`. Keep it a pure function of the record it is handed.
    ///
    /// CONTRACT, stated rather than enforced: `transform` must return a record for
    /// `bookID`. Its one caller (`DownloadStateManager.persistReissuedTask`) does,
    /// unconditionally — two call PATHS reach it, the acquisition-link follow-up
    /// and the bearer hop, but there is one call site. An earlier version
    /// enforced it by also deleting the requested key — but since the two keys are
    /// identical for every reachable input, that clause could not be killed by any
    /// test or mutant, which is a worse thing to carry on a critical path than a
    /// documented precondition. A transform returning a foreign id would leave a
    /// STALE record under `bookID` (not a duplicate); no caller can produce it.
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
/// Lives here rather than in MyBooksDownloadCenter because it is reconciliation
/// infrastructure, not download-center state — and the hub is frozen under the
/// decomposition ratchet, which asks for extraction rather than growth.
/// `@unchecked Sendable` with a lock over BOTH writes and reads.
///
/// The original argument was that every write happens inside the single
/// `getAllTasks` completion and every read after it resumes — sound, and
/// auditable while the type was file-`private`. Extraction made it
/// module-visible, at which point "every write" became a claim about the whole
/// app target that nothing enforced. `private(set)` closes the dictionaries to
/// outside writers but `capture` is still an unlocked internal mutator, so two
/// reviewers independently flagged the same gap.
///
/// The first attempt at that added an `NSLock` around `capture` and left the
/// dictionaries `private(set)`, so every READ was still unlocked — and the
/// comment claimed "an actual lock, not a convention" while shipping half of
/// one. Review caught it. The storage is `private` now and the only way in or
/// out is through the accessors below, all of which take the lock.
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
    /// `originalRequest`, and dropping it would silently decline to adopt a
    /// download that is still running. Returns false when the task has no URL
    /// at all — it can never be adopted, and the caller logs rather than
    /// dropping it in silence.
    /// THE BINDING BELOW IS THE ONE THING NO TEST HERE DRIVES, and that is a
    /// property of `URLSessionDownloadTask`, not of the tests. A task built from
    /// a URL reports the SAME value for `originalRequest` and `currentRequest`,
    /// so swapping the two arguments changes nothing any test can observe; a
    /// task reporting neither cannot be constructed at all. The decision itself
    /// is driven exhaustively in `downloadURL(original:current:)`, and what
    /// remains here is a two-line adapter with no branch of its own. Naming the
    /// gap is the honest form — a reviewer proved it by swapping the labels and
    /// watching all nine tests stay green.
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
    /// Split out because the branches are NOT reachable through
    /// `URLSessionDownloadTask`: a task built from a URL reports the same value
    /// for `originalRequest` and `currentRequest`, and one with neither cannot
    /// be constructed at all. Mutating the fallback or the nil arm inside
    /// `capture` therefore left every test green. Whether a branch can be
    /// exercised is a property of the seam, not of the diligence of the test —
    /// so the decision moved somewhere it can be driven exhaustively.
    ///
    /// `originalRequest` wins because it survives a redirect: `currentRequest`
    /// holds the redirected URL, and the persisted record carries the URL the
    /// download STARTED from. Preferring `currentRequest` would stop a
    /// redirected download from ever matching its own record.
    static func downloadURL(original: URL?, current: URL?) -> URL? {
        original ?? current
    }
}

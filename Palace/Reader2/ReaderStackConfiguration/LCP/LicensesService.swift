//
//  LicensesService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 25.03.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared
import ReadiumLCP
import ReadiumZIPFoundation
import CryptoSwift
import PalaceLogging
import PalaceCatalog

enum TPPLicensesServiceError: Error {
    case licenseError(message: String)

    public var description: String {
        switch self {
        case .licenseError(let message): return message
        }
    }
}

/// The parts of `URLSession` a publication transfer uses.
///
/// A seam, so a test can drive a transfer without registering a background
/// session with the system: a background session a test leaves behind outlives
/// the test process, and the daemon would hand the next run its tasks.
protocol LCPPublicationSessionHandle: AnyObject {
    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask
    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask
    func finishTasksAndInvalidate()
    /// The tasks the system still holds for this session, including any a
    /// previous process left outstanding and the daemon restored. The only way
    /// to see those, and asynchronous, which is why `dropDuplicateTasks`
    /// resolves a duplicate rather than preventing one.
    func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void)
}

extension URLSession: LCPPublicationSessionHandle {}
/// What de-duplication needs to know about one outstanding task.
///
/// A seam: `URLSessionDownloadTask` has no accessible initializer, so a test
/// cannot build one, and the half of de-duplication worth testing is the half
/// that decides which task to cancel.
protocol OutstandingArchiveTask: AnyObject {
    var taskIdentifier: Int { get }
    var archiveURL: URL? { get }
    var isFinished: Bool { get }
    var bytesTransferred: Int64 { get }
    func cancelTransfer()
    /// Whether the transfer is moving bytes right now, so a hold suspends only
    /// what is actually competing and a release resumes only what it held.
    var isRunning: Bool { get }
    /// Stops the transfer without ending it. The archive keeps its progress and
    /// its resume data; only the link is given up.
    func suspendTransfer()
    func resumeTransfer()
}

extension URLSessionDownloadTask: OutstandingArchiveTask {
    var archiveURL: URL? { originalRequest?.url }
    var isFinished: Bool { state == .completed }
    var bytesTransferred: Int64 { countOfBytesReceived }
    func cancelTransfer() { cancel() }
    var isRunning: Bool { state == .running }
    func suspendTransfer() { suspend() }
    func resumeTransfer() { resume() }
}


/// The publication transfers in flight, at most one per background identifier.
///
/// Apple permits exactly one `URLSession` per background identifier and leaves
/// the behaviour of a second one undefined; Foundation logs "A background
/// URLSession with identifier ... already exists!" and stops delivering
/// callbacks reliably to the newer session's delegate, which the patron sees as
/// progress frozen at 0% while bytes may still be moving. A second task on one
/// identifier instead fetches the same 0.7-1.2 GB archive twice.
///
/// `acquirePublication` is reachable more than once for one book — a reclaimed
/// content claim, the registry self-heal plus the patron opening the book — so
/// the uniqueness is enforced here rather than assumed. Process-wide, because
/// the identifier names a system-wide resource: the background transfer daemon,
/// not this object, decides what one identifier means.
final class LCPPublicationSessionRegistry: @unchecked Sendable {

    static let shared = LCPPublicationSessionRegistry()

    /// One archive transfer.
    final class Transfer {
        let identifier: String
        let session: LCPPublicationSessionHandle
        /// The instance the session was created with. `URLSession` fixes its
        /// delegate when it is constructed, so this object receives every
        /// callback for this identifier whoever asked for the transfer.
        let delegate: TPPLicensesService
        /// The task carrying the archive, so a repeat request can be handed the
        /// transfer already running instead of starting a second one.
        fileprivate(set) var task: URLSessionDownloadTask?

        /// Whether this transfer is suspended to give a chapter load the link.
        ///
        /// Recorded per transfer, not once for the registry: the earlier attempt
        /// kept a single process-wide slot, and registering a second transfer,
        /// finishing one, or resuming one from partial data each replaced that
        /// slot and left the suspended task with nothing holding a reference
        /// that could resume it. The patron saw a download stop at the byte it
        /// had reached. Keeping the flag on the transfer means a transfer that
        /// ends while held takes its hold with it.
        fileprivate(set) var isHeld = false

        fileprivate init(identifier: String,
                         session: LCPPublicationSessionHandle,
                         delegate: TPPLicensesService) {
            self.identifier = identifier
            self.session = session
            self.delegate = delegate
        }
    }

    // INVARIANT — every read and write of `transfers`, and of any
    // `Transfer.task`, happens inside `lock`. `acquirePublication` runs on
    // whichever queue the download centre is on, while the callbacks that end a
    // transfer run on the main queue.
    private let lock = NSLock()
    private var transfers: [String: Transfer] = [:]

    /// The transfer for `identifier`, started with `startSession` only if there
    /// is none already.
    /// - Returns: the transfer, and whether this call is the one that started it.
    func transfer(
        for identifier: String,
        delegate: TPPLicensesService,
        startingWith startSession: (String) -> LCPPublicationSessionHandle
    ) -> (transfer: Transfer, isNew: Bool) {
        healExpiredHoldForChapterLoad()
        lock.lock(); defer { lock.unlock() }
        if let running = transfers[identifier] {
            return (running, false)
        }
        // Inside the lock: two callers arriving together must not both open a
        // session on the one identifier, which is the case being fixed.
        let started = Transfer(identifier: identifier,
                               session: startSession(identifier),
                               delegate: delegate)
        transfers[identifier] = started
        return (started, true)
    }

    /// The session carrying `identifier`, if a transfer is in flight.
    func session(for identifier: String) -> LCPPublicationSessionHandle? {
        lock.lock(); defer { lock.unlock() }
        return transfers[identifier]?.session
    }

    /// The task carrying `identifier`, if a transfer is in flight.
    func task(for identifier: String) -> URLSessionDownloadTask? {
        lock.lock(); defer { lock.unlock() }
        return transfers[identifier]?.task
    }

    func setTask(_ task: URLSessionDownloadTask?, for identifier: String) {
        lock.lock()
        transfers[identifier]?.task = task
        // A transfer registered or resumed from partial data while a chapter is
        // waiting must start held, or the hold leaks the link to the transfer
        // that arrived during it. `holdExpiry` is consulted so a stale hold
        // cannot suspend a new transfer indefinitely.
        let holdApplies = isHolding && task != nil && !holdHasExpired
        if holdApplies { transfers[identifier]?.isHeld = true }
        lock.unlock()
        if holdApplies { task?.suspendTransfer() }
    }

    // MARK: - Giving a waiting chapter the link

    /// Whether a chapter load is currently holding the archive transfers, and
    /// when that hold stops applying.
    ///
    /// A hold must expire on a clock, not only on a callback: the toolkit's
    /// `streamingLoadDidEnd()` is the paired signal, and a load that is torn
    /// down in an unusual way can fail to send it. An expired hold is released
    /// by the next registry operation, so the worst case is a transfer that
    /// resumes late rather than one that never resumes.
    private var holdExpiry: Date?
    private var isHolding: Bool { holdExpiry != nil }
    private var holdHasExpired: Bool {
        guard let holdExpiry else { return false }
        return Date() >= holdExpiry
    }

    /// How long a single chapter load may hold the archive transfers.
    ///
    /// Longer than the player's load progress window (30 s) would outlive the
    /// load it was taken for; much shorter would release the link back while
    /// the patron is still waiting. The load timeout re-arms while bytes
    /// arrive, so a healthy slow chapter re-takes the hold on its next load.
    static let maxChapterLoadHold: TimeInterval = 30

    /// Suspends every running archive transfer so the chapter the patron is
    /// waiting on has the link to itself.
    ///
    /// The background package fetch and a streamed chapter are separate
    /// URLSessions over one link, so the fetch competes with the chapter the
    /// patron is waiting for (PP-5367). Measured on device: a chapter start
    /// moves ~6 MB, and a whole-archive transfer is 0.7-1.2 GB.
    ///
    /// - Returns: how many transfers this call suspended.
    @discardableResult
    func holdTransfersForChapterLoad(
        until deadline: Date = Date().addingTimeInterval(LCPPublicationSessionRegistry.maxChapterLoadHold)
    ) -> Int {
        lock.lock()
        holdExpiry = deadline
        // Only what is actually moving bytes: suspending a task that has not
        // started would make `resumeTransfer()` start it, which is a transfer
        // the hold invented rather than one it paused.
        let toHold = transfers.values.filter { !$0.isHeld && ($0.task?.isRunning ?? false) }
        for transfer in toHold { transfer.isHeld = true }
        let tasks = toHold.compactMap(\.task)
        lock.unlock()
        for task in tasks { task.suspendTransfer() }
        return tasks.count
    }

    /// Resumes whatever `holdTransfersForChapterLoad` suspended.
    ///
    /// Idempotent, and safe to call when nothing is held: only a transfer this
    /// registry recorded as held is resumed, so a second call cannot start a
    /// transfer that was suspended for some other reason.
    ///
    /// - Returns: how many transfers this call resumed.
    @discardableResult
    func releaseTransfersHeldForChapterLoad() -> Int {
        lock.lock()
        holdExpiry = nil
        let held = transfers.values.filter(\.isHeld)
        for transfer in held { transfer.isHeld = false }
        let tasks = held.compactMap(\.task)
        lock.unlock()
        for task in tasks { task.resumeTransfer() }
        return tasks.count
    }

    /// Whether `identifier`'s transfer is held, for the tests and the log line.
    func isHeldForChapterLoad(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transfers[identifier]?.isHeld ?? false
    }

    /// Releases a hold whose deadline has passed.
    ///
    /// Called from the registry's entry points so a lost
    /// `streamingLoadDidEnd()` cannot strand a transfer until the app is
    /// relaunched. The timer that normally ends a hold is the primary release;
    /// this is the backstop that does not depend on a callback arriving.
    func healExpiredHoldForChapterLoad() {
        lock.lock()
        let expired = holdHasExpired
        lock.unlock()
        if expired { releaseTransfersHeldForChapterLoad() }
    }

    /// Ends the transfer: the session is invalidated so it and its delegate are
    /// released, and the identifier is free for a later attempt at the book.
    func finish(_ identifier: String) {
        healExpiredHoldForChapterLoad()
        lock.lock()
        let finished = transfers.removeValue(forKey: identifier)
        lock.unlock()
        // Outside the lock: invalidation is a `URLSession` call, and nothing it
        // does should be able to re-enter the registry while the lock is held.
        finished?.session.finishTasksAndInvalidate()
    }
}

// Swift 6 `complete`: `@unchecked Sendable`. The instance is passed as
// `delegate:` to `URLSession(configuration:delegate:delegateQueue:)`, which
// requires a `Sendable` delegate under strict concurrency.
// INVARIANT — the mutable state is reached only under a lock:
//   • `progressHandler`, `completionHandler`, `lcpl`, `link` and the transfer's
//     identifier are one record, guarded by `callerLock`. They are written when
//     a caller asks for the archive — which happens again, on this same
//     instance, when a later caller joins a transfer already running — and read
//     from the `URLSessionDownloadDelegate` callbacks, which this class always
//     registers with `delegateQueue: .main`. Each read copies the value out and
//     uses it after the lock is released.
//   • `resumeAttempts` is written from those main-queue callbacks, and in
//     `acquirePublication` only on the call that starts the transfer, before
//     there is a task to call back.
// A `@MainActor` isolation would instead ripple onto every (test) caller of the
// synchronous `acquirePublication` entry point.
class TPPLicensesService: NSObject, @unchecked Sendable {

    // MARK: - Transfer policy

    /// How long the whole publication transfer may take.
    ///
    /// A streamed LCP audiobook archive is one to two gigabytes. Measured on a
    /// patron's device at ~4.3 MB/s, a 1,896,374,144-byte archive needs about
    /// 441 s at full rate, and that link was observed collapsing mid-transfer.
    /// The previous 600 s cap therefore killed the transfer rather than the
    /// transfer finishing, and with no resume data each attempt restarted from
    /// byte zero and re-saturated the same link: 22 failures over six weeks on
    /// one device, the archive never completing.
    static let publicationResourceTimeout: TimeInterval = 4 * 60 * 60

    /// How long a socket may deliver nothing before the transfer fails.
    ///
    /// Unchanged in spirit from the 60 s this replaced: the budget above is for a
    /// slow transfer, not for a dead one.
    static let publicationRequestTimeout: TimeInterval = 60

    /// Whether a transfer to this host must carry no cookies or credentials.
    ///
    /// Unknown hosts are treated as requiring isolation: sending nothing is the
    /// cautious direction.
    static func requiresCredentialIsolation(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return true }
        return host.contains("googleapis.com")
    }

    /// The configuration the publication transfer runs on.
    ///
    /// Always a background configuration. The ephemeral session this replaced
    /// was chosen only to keep credentials off googleapis.com, but ephemeral
    /// sessions are in-memory and die with the process: a 1.9 GB archive that
    /// needs ~441 s on a patron's link restarted at byte zero on every app
    /// launch and never finished. A background session with no cookie or
    /// credential storage isolates just as well and survives.
    static func publicationSessionConfiguration(
        identifier: String,
        isolateCredentials: Bool
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.timeoutIntervalForRequest = publicationRequestTimeout
        config.timeoutIntervalForResource = publicationResourceTimeout
        // The patron is waiting on this content; it must not be deferred to a
        // system-chosen moment.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        if isolateCredentials {
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.httpShouldSetCookies = false
        }
        return config
    }

    /// How many times a failed transfer may be resumed from its partial data.
    ///
    /// Bounded because a link that never recovers would otherwise be retried for
    /// the life of the process, spending the patron's battery and data.
    static let maxResumeAttempts = 3

    /// What to do with a transfer that failed.
    enum ResumeAction: Equatable {
        /// Continue from the bytes already on disk.
        case resume(Data)
        /// Report the failure; there is nothing cheaper to try.
        case giveUp
    }

    /// Whether a failed transfer can be continued rather than restarted.
    ///
    /// Pure so the policy is testable and a flipped comparison is caught: the
    /// expensive mistake here is silently restarting a 1.9 GB download.
    static func resumeAction(for error: Error, attemptsSoFar: Int) -> ResumeAction {
        let nsError = error as NSError
        // A cancelled transfer was cancelled deliberately; resuming it fights the
        // caller that asked for it to stop.
        guard nsError.code != NSURLErrorCancelled else { return .giveUp }
        guard attemptsSoFar < maxResumeAttempts else { return .giveUp }
        guard let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              !data.isEmpty
        else { return .giveUp }
        return .resume(data)
    }

    // MARK: - Where the transfer runs

    /// How the transfer's session is built.
    typealias SessionFactory = (
        _ identifier: String,
        _ isolateCredentials: Bool,
        _ delegate: URLSessionDelegate
    ) -> LCPPublicationSessionHandle

    /// The production factory: a background session the system keeps running
    /// while the app is away.
    static func backgroundSession(
        identifier: String,
        isolateCredentials: Bool,
        delegate: URLSessionDelegate
    ) -> LCPPublicationSessionHandle {
        URLSession(
            configuration: publicationSessionConfiguration(
                identifier: identifier,
                isolateCredentials: isolateCredentials
            ),
            delegate: delegate,
            delegateQueue: .main
        )
    }

    private let makeSession: SessionFactory
    private let sessions: LCPPublicationSessionRegistry

    init(sessions: LCPPublicationSessionRegistry = .shared,
         makeSession: @escaping SessionFactory = TPPLicensesService.backgroundSession) {
        self.sessions = sessions
        self.makeSession = makeSession
        super.init()
    }

    /// Resume attempts spent on the transfer in flight.
    private var resumeAttempts = 0

    // MARK: - The caller waiting on the transfer

    /// What the caller waiting on the transfer asked to be told, and which
    /// transfer it is waiting on.
    private struct WaitingCaller {
        var progress: ((Double) -> Void)?
        var completion: ((URL?, Error?) -> Void)?
        var lcpl: URL?
        var link: TPPLCPLicenseLink?
        var identifier: String?
    }

    private let callerLock = NSLock()
    private var waiting = WaitingCaller()

    var progressHandler: ((_ progress: Double) -> Void)? {
        get { callerLock.lock(); defer { callerLock.unlock() }; return waiting.progress }
        set { callerLock.lock(); defer { callerLock.unlock() }; waiting.progress = newValue }
    }

    var completionHandler: ((_ localUrl: URL?, _ error: Error?) -> Void)? {
        get { callerLock.lock(); defer { callerLock.unlock() }; return waiting.completion }
        set { callerLock.lock(); defer { callerLock.unlock() }; waiting.completion = newValue }
    }

    var lcpl: URL? {
        get { callerLock.lock(); defer { callerLock.unlock() }; return waiting.lcpl }
        set { callerLock.lock(); defer { callerLock.unlock() }; waiting.lcpl = newValue }
    }

    var link: TPPLCPLicenseLink? {
        get { callerLock.lock(); defer { callerLock.unlock() }; return waiting.link }
        set { callerLock.lock(); defer { callerLock.unlock() }; waiting.link = newValue }
    }

    /// Points this instance — the session's delegate — at the caller that is
    /// waiting now.
    ///
    /// A repeat request for the same book arrives on a freshly constructed
    /// `TPPLicensesService` carrying its own handlers (`LCPLibraryService`
    /// builds one per call), and a session's delegate cannot be changed after
    /// construction. So the handlers move to the delegate rather than the
    /// delegate to the handlers: keeping the first caller's handlers would
    /// leave the patron who is actually waiting with no progress at all, which
    /// is the symptom being fixed.
    ///
    /// `lcpl` and `link` describe the same archive either way — the identifier
    /// is derived from the licence URL, so an equal identifier means an equal
    /// licence.
    private func serve(
        progress: @escaping (_ progress: Double) -> Void,
        completion: @escaping (_ localUrl: URL?, _ error: Error?) -> Void,
        lcpl: URL,
        link: TPPLCPLicenseLink,
        identifier: String
    ) {
        callerLock.lock(); defer { callerLock.unlock() }
        waiting = WaitingCaller(progress: progress, completion: completion,
                                lcpl: lcpl, link: link, identifier: identifier)
    }

    /// The transfer this instance's session is carrying, while it is in flight.
    private var transferIdentifier: String? {
        callerLock.lock(); defer { callerLock.unlock() }
        return waiting.identifier
    }

    /// Ends the transfer this instance's session is carrying, however it ended.
    ///
    /// Without this the session stays live for the life of the process: it
    /// holds its delegate, and it holds the one background identifier this
    /// archive can use, so a later attempt at the same book would have to open
    /// the second session Apple leaves undefined. Clearing the identifier makes
    /// a second call a no-op, which matters because a finished download reports
    /// both `didFinishDownloadingTo` and `didCompleteWithError`.
    /// Task identifiers this service cancelled on purpose, so their completions
    /// can be told apart from the transfer ending.
    ///
    /// Without this, de-duplicating is worse than the duplicate it removes:
    /// `didCompleteWithError` does not look at which task completed, a
    /// cancellation maps to `.giveUp`, and `.giveUp` runs `finishTransfer()` —
    /// which removes the registry entry and invalidates the session the
    /// SURVIVING task is still downloading in. `NSURLErrorCancelled` also
    /// suppresses the completion callback, so the patron would be left at N%
    /// with no error and nothing to retry.
    ///
    /// Guarded by its own lock rather than `callerLock`, whose invariant covers
    /// the waiting caller's record and nothing else.
    private let droppedTaskLock = NSLock()
    private var droppedTaskIdentifiers: Set<Int> = []

    /// Marks a task as deliberately cancelled. Internal so a test can drive the
    /// suppression without constructing a `URLSessionTask`.
    func recordDroppedTask(_ taskIdentifier: Int) {
        droppedTaskLock.lock()
        droppedTaskIdentifiers.insert(taskIdentifier)
        droppedTaskLock.unlock()
    }

    /// Whether this completion belongs to a task we cancelled, consuming the
    /// record. Consuming, not peeking: a task reports completion once, and a
    /// identifier left behind would suppress a real failure of a later task
    /// that the system happened to give the same number.
    func consumeDroppedTask(_ taskIdentifier: Int) -> Bool {
        droppedTaskLock.lock()
        defer { droppedTaskLock.unlock() }
        return droppedTaskIdentifiers.remove(taskIdentifier) != nil
    }

    /// Cancels every outstanding task for `url` on this session but the one
    /// that has moved the most bytes.
    ///
    /// Two tasks for one archive cost the patron the transfer twice, and
    /// `didFinishDownloadingTo` does not check which task finished, so the
    /// second completion moves onto a destination the first already wrote.
    ///
    /// The furthest along wins rather than the one just created: a task the
    /// system restored may be most of the way through a gigabyte, and
    /// cancelling that to keep a fresh one would restart from zero — the
    /// behavior this is here to prevent.
    /// Internal, not private, so a test can drive the de-duplication itself
    /// rather than only the arithmetic it delegates to.
    func dropDuplicateTasks(
        on session: LCPPublicationSessionHandle,
        for url: URL,
        identifier: String
    ) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let keep = self.dropDuplicates(
                among: tasks.compactMap { $0 as? URLSessionDownloadTask },
                for: url
            )
            if let keep = keep as? URLSessionDownloadTask {
                self.sessions.setTask(keep, for: identifier)
            }
        }
    }

    /// Cancels every outstanding task for `url` but the one furthest along, and
    /// returns the one kept, or nil when there was no duplicate.
    ///
    /// Every cancelled identifier is recorded first, because a cancellation's
    /// completion is otherwise indistinguishable from the transfer ending and
    /// would tear down the session the kept task is still using.
    @discardableResult
    func dropDuplicates(among tasks: [OutstandingArchiveTask], for url: URL) -> OutstandingArchiveTask? {
        let outstanding = tasks.filter { $0.archiveURL == url && !$0.isFinished }
        guard let keepIndex = Self.indexOfTaskToKeep(
            bytesReceived: outstanding.map(\.bytesTransferred)
        ) else { return nil }
        let keep = outstanding[keepIndex]
        for (index, duplicate) in outstanding.enumerated() where index != keepIndex {
            // Recorded BEFORE the cancel: the completion can arrive before
            // `cancelTransfer()` returns.
            recordDroppedTask(duplicate.taskIdentifier)
            duplicate.cancelTransfer()
        }
        Log.info(#file, "  Dropped \(outstanding.count - 1) duplicate task(s) for this archive; kept the one \(keep.bytesTransferred) bytes in")
        return keep
    }

    /// Which of several outstanding tasks for one archive keeps the transfer:
    /// the one that has moved the most bytes. Nil when there is nothing to
    /// de-duplicate, so a single task is never cancelled and never re-recorded.
    static func indexOfTaskToKeep(bytesReceived: [Int64]) -> Int? {
        guard bytesReceived.count > 1 else { return nil }
        var best = 0
        for index in bytesReceived.indices where bytesReceived[index] > bytesReceived[best] {
            best = index
        }
        return best
    }

    private func finishTransfer() {
        callerLock.lock()
        let identifier = waiting.identifier
        waiting.identifier = nil
        callerLock.unlock()
        guard let identifier else { return }
        sessions.finish(identifier)
    }

    func acquirePublication(from lcpl: URL, progress: @escaping (_ progress: Double) -> Void, completion: @escaping (_ localUrl: URL?, _ error: Error?) -> Void) -> URLSessionDownloadTask? {
        // Parse LCP license file
        guard let license = TPPLCPLicense(url: lcpl) else {
            completion(nil, TPPLicensesServiceError.licenseError(message: "Reading license file failed"))
            return nil
        }
        // Get publication download link
        guard let link = license.firstLink(withRel: .publication), let href = link.href, let url = URL(string: href) else {
            completion(nil, TPPLicensesServiceError.licenseError(message: "Error parsing license file, publication href was not found"))
            return nil
        }

        Log.info(#file, "📥 [LCP DOWNLOAD] Starting publication download")
        Log.info(#file, "  Host: \(url.host ?? "unknown")")
        Log.info(#file, "  Full URL: \(url.absoluteString)")

        let request = URLRequest(url: url, applyingCustomUserAgent: true)

        // Use sha256 for a stable session identifier across app launches (PP-3704).
        // Swift's URL.hashValue is randomized per process (SE-0206), so using it caused
        // background download sessions to be orphaned on every app restart.
        let stableHash = lcpl.absoluteString.sha256()
        let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".lcpBackgroundIdentifier.\(stableHash)")
        let isolate = Self.requiresCredentialIsolation(host: url.host)
        Log.info(#file, "  Background session ID: \(backgroundIdentifier) (credential-isolated: \(isolate))")

        let (transfer, isNew) = sessions.transfer(for: backgroundIdentifier, delegate: self) { identifier in
            makeSession(identifier, isolate, self)
        }
        // The handlers that fire must be this caller's, not those of whoever
        // opened the session: this caller is the one waiting on the archive.
        transfer.delegate.serve(progress: progress, completion: completion,
                                lcpl: lcpl, link: link, identifier: backgroundIdentifier)

        guard isNew else {
            // The archive is already on its way. A second task on this
            // identifier would fetch the same gigabytes again.
            Log.info(#file, "  Joining the transfer already running for this archive")
            return sessions.task(for: backgroundIdentifier)
        }

        // The first call of this PROCESS for this archive — which is not the
        // same as the first call for the archive. The registry is in-memory and
        // empty at launch, while the system restores a previous process's
        // outstanding task to this recreated session, so a relaunch during a
        // transfer lands here with the daemon already moving the same
        // gigabytes. Only `getAllTasks` reports that task, and only
        // asynchronously — after this function has had to return a handle — so
        // the duplicate is resolved immediately afterwards rather than avoided.
        self.resumeAttempts = 0
        let task = transfer.session.downloadTask(with: request)
        sessions.setTask(task, for: backgroundIdentifier)
        task.resume()
        dropDuplicateTasks(on: transfer.session, for: url, identifier: backgroundIdentifier)
        return task
    }

    /// Injects licens file into LCP-protected file
    /// - Parameters:
    ///   - lcpl: license URL
    ///   - file: LCP-protected file URL
    func injectLicense(lcpl: URL, to file: URL, at path: String) async throws {
        let archive = try await Archive(url: file, accessMode: .update)

        do {
            // Removes the old License if it already exists in the archive, otherwise we get duplicated entries
            if let oldLicense = try await archive.get(path) {
                try await archive.remove(oldLicense)
            }

            // Stores the License into the ZIP file
            let data = try Data(contentsOf: lcpl)
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: {
                    (position, size) -> Data in
                    let start = Int(position)
                    let end = min(start + Int(size), data.count)
                    return data[start..<end]
                }
            )
        } catch {
            throw TPPLicensesServiceError.licenseError(message: "Error injecting license file: \(error.localizedDescription)")
        }
    }

    /// Defines path inside .zip file to write license file to.
    /// - Parameter link: LCP license `link` object.
    /// - Returns: Path inside .zip file, `nil` if license should not be injected.
    func pathInZip(for link: TPPLCPLicenseLink) -> String? {
        guard let linkType = link.type else {
            return nil
        }
        switch linkType {
        case ContentTypeEpubZip: return "META-INF/license.lcpl"
        case ContentTypeReadiumLCP, ContentTypeReadiumLCPPDF, ContentTypePDFLCP, ContentTypeAudiobookLCP: return "license.lcpl"
        default: return nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension TPPLicensesService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The archive is on disk, so the session has no work left. Deferred to
        // the end of the callback because `location` is only valid for its
        // duration, and the copy below has to happen first.
        defer { finishTransfer() }

        guard let lcpl = self.lcpl, let link = self.link else {
            completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Missing license or link"))
            return
        }

        let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent("download_\(UUID().uuidString).zip")

        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)

            if let licensePathInZip = self.pathInZip(for: link) {

                Task {
                    do {
                        if (try? await Archive(url: safeCopy, accessMode: .read)) != nil {
                            try await self.injectLicense(lcpl: lcpl, to: safeCopy, at: licensePathInZip)

                            completionHandler?(safeCopy, nil)
                        } else {
                            completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Failed to open archive"))
                        }
                    } catch {
                        completionHandler?(nil, error)
                    }
                }
            } else {
                completionHandler?(safeCopy, nil)
            }
        } catch {
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Consumed BEFORE the error guard. A cancelled task normally reports
        // `NSURLErrorCancelled`, but one that finishes in the instant it is
        // cancelled reports no error at all — and leaving its identifier behind
        // would suppress the next completion the system gives that number,
        // which is a real failure swallowed.
        let wasDropped = consumeDroppedTask(task.taskIdentifier)
        guard let error else { return }
        // A task this service cancelled to de-duplicate is not the transfer
        // ending. Checked before `resumeAction`, which cannot tell the two
        // apart: both arrive as `NSURLErrorCancelled`.
        guard !wasDropped else {
            Log.info(#file, "  Ignoring the completion of a duplicate task this transfer dropped")
            return
        }
        switch Self.resumeAction(for: error, attemptsSoFar: resumeAttempts) {
        case let .resume(data):
            // Continue from the bytes already on disk. Restarting a 1.9 GB
            // archive from zero re-saturates the very link that just failed,
            // which is how a transfer can fail repeatedly and never advance.
            resumeAttempts += 1
            Log.info(#file, String(
                format: "📥 [LCP DOWNLOAD] resuming after %@ (attempt %d of %d, %d bytes already fetched)",
                (error as NSError).localizedDescription,
                resumeAttempts, Self.maxResumeAttempts, data.count
            ))
            let identifier = transferIdentifier
            let handle: LCPPublicationSessionHandle = identifier.flatMap { sessions.session(for: $0) } ?? session
            let resumed = handle.downloadTask(withResumeData: data)
            // Recorded so the resumed transfer is the one a repeat request is
            // handed: a task nothing records is a transfer nothing afterwards
            // can observe or manage.
            if let identifier {
                sessions.setTask(resumed, for: identifier)
            }
            resumed.resume()
        case .giveUp:
            finishTransfer()
            // A deliberate cancellation is not a failure to report.
            if (error as NSError).code != NSURLErrorCancelled {
                completionHandler?(nil, error)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

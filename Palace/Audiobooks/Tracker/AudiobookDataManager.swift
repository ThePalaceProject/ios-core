import Foundation
import Combine
import UIKit

struct LibraryBook: Codable, Hashable {
    var bookId: String
    var libraryId: String

    init(bookId: String, libraryId: String) {
        self.bookId = bookId
        self.libraryId = libraryId
    }

    init(time: AudiobookTimeEntry) {
        self.init(bookId: time.bookId, libraryId: time.libraryId)
    }
}

struct RequestData: Codable {
    struct TimeEntry: Codable {
        let id: String
        let duringMinute: String
        let secondsPlayed: Int

        init(id: String, duringMinute: String, secondsPlayed: Int) {
            self.id = id
            self.duringMinute = duringMinute
            self.secondsPlayed = secondsPlayed
        }

        init(time: AudiobookTimeEntry) {
            self.id = time.id
            self.duringMinute = time.duringMinute
            self.secondsPlayed = Int(time.duration)
        }

        var description: String {
            return "TimeEntry(id: \(id), duringMinute: \(duringMinute), secondsPlayed: \(secondsPlayed))"
        }
    }

    let libraryId: String
    let bookId: String
    let timeEntries: [TimeEntry]

    init(libraryId: String, bookId: String, timeEntries: [TimeEntry]) {
        self.libraryId = libraryId
        self.bookId = bookId
        self.timeEntries = timeEntries
    }

    init(libraryBook: LibraryBook, timeEntries: [AudiobookTimeEntry]) {
        self.libraryId = libraryBook.libraryId
        self.bookId = libraryBook.bookId
        self.timeEntries = timeEntries.map { TimeEntry(time: $0) }
    }

    var jsonRepresentation: Data? {
        return try? JSONEncoder().encode(self)
    }
}

struct ResponseData: Codable {
    struct ResponseEntry: Codable {
        let status: Int
        let message: String
        let id: String
    }

    let responses: [ResponseEntry]

    init(responses: [ResponseEntry]) {
        self.responses = responses
    }

    init?(data: Data) {
        guard let value = try? JSONDecoder().decode(ResponseData.self, from: data) else {
            return nil
        }
        self.init(responses: value.responses)
    }
}

struct AudiobookDataManagerStore: Codable {
    var urls: [LibraryBook: URL] = [:]
    var queue: [AudiobookTimeEntry] = []

    init() { }

    init?(data: Data) {
        guard let value = try? JSONDecoder().decode(AudiobookDataManagerStore.self, from: data) else {
            return nil
        }
        self = value
    }

    var jsonRepresentation: Data? {
        try? JSONEncoder().encode(self)
    }
}

class AudiobookDataManager {
    private let syncTimeInterval: TimeInterval
    private var subscriptions: Set<AnyCancellable> = []
    /// Serial dispatch queue that owns all writes to `store`. Exposed at
    /// internal access so `@testable import` tests can `syncQueue.sync {}`
    /// to deterministically wait for pending barrier writes to drain
    /// before asserting against `store` — that race used to be papered
    /// over with `DispatchQueue.main.asyncAfter` sleeps, which flaked
    /// under load and were banned by CLAUDE.md.
    let syncQueue = DispatchQueue(label: "com.audiobook.syncQueue")
    var store = AudiobookDataManagerStore()
    private let audiobookLogger = AudiobookFileLogger.shared
    private let networkService: TPPNetworkExecutor
    /// Cross-account scope guard for playtimes uploads (Bug B, swarm_162a3219).
    ///
    /// Returns the UUID of the currently-selected library. The `syncValues()`
    /// loop compares each queued `LibraryBook.libraryId` against this value
    /// and SKIPS uploads whose library is not the active one — the entries
    /// stay in the queue and flush on the next sync after the user switches
    /// back. Default closure reads `AppContainer.production().accountsManager
    /// .currentAccountId`; tests inject a captured closure so they can flip
    /// the "current library" mid-test without instantiating the full app
    /// container or the real `AccountsManager` state machine.
    ///
    /// See `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md`
    /// §2 Bug B for the regression that motivated this guard.
    private let currentAccountIdProvider: () -> String?
    /// Observer token for `.TPPCurrentAccountDidChange` posted by
    /// `AccountsManager.currentAccount.didSet`. Held so the observer is
    /// removed at dealloc; the notification only logs (no queue mutation)
    /// because the scope guard above is the actual enforcement mechanism.
    private var accountChangeObserver: NSObjectProtocol?
    init(syncTimeInterval: TimeInterval = 60,
         networkService: TPPNetworkExecutor = AppContainer.production().networkExecutor,
         currentAccountIdProvider: @escaping () -> String? = { AppContainer.production().accountsManager.currentAccountId }) {
        self.syncTimeInterval = syncTimeInterval
        self.networkService = networkService
        self.currentAccountIdProvider = currentAccountIdProvider

        // Use .common RunLoop mode for reliable timer firing during UI interactions
        Timer.publish(every: syncTimeInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.syncValues() }
            .store(in: &subscriptions)

        AppContainer.production().reachability.connectivityPublisher
            .filter { $0 } // Only sync when connected
            .sink { [weak self] _ in self?.syncValues() }
            .store(in: &subscriptions)

        loadStore()
        subscribeToAccountChanges()
    }

    deinit {
        if let observer = accountChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Observes `.TPPCurrentAccountDidChange` for diagnostic logging only.
    /// The actual cross-account scope decision lives in `syncValues()`'s
    /// per-`libraryBook` guard, so on account change there is NOTHING to
    /// mutate here — entries queued for the prior library MUST be preserved
    /// so they flush when the user switches back. Destructive queue clear
    /// on switch would lose playtimes for any book the user toggles between.
    private func subscribeToAccountChanges() {
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.audiobookLogger.logEvent(
                forBookId: "",
                event: "Account changed — cross-account playtimes uploads will be deferred to next foreground sync"
            )
        }
    }

    func save(time: AudiobookTimeEntry) {
        syncQueue.async(flags: .barrier) {
            self.store.urls[LibraryBook(time: time)] = time.timeTrackingUrl
            self.store.queue.append(time)
            self.saveStore()
        }
    }

    private func reachabilityStatusChanged(_ notification: Notification) {
        if let isConnected = notification.object as? Bool, isConnected {
            syncValues()
        }
    }

    func syncValues(_: Date? = nil) {
        // Request background task to ensure sync completes even if app is backgrounded
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudiobookTimeSync") {
            // Cleanup handler if time expires
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }

        syncQueue.async { [weak self] in
            guard let self = self else {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                return
            }

            let queuedLibraryBooks: Set<LibraryBook> = Set(self.store.queue.map { LibraryBook(time: $0) })

            // Cross-account scope guard (Bug B, swarm_162a3219). A book whose
            // libraryId does not match the currently-selected library MUST
            // NOT have its playtimes POSTed — the receiving circulation-
            // manager host is scoped to that library's credentials and would
            // 401, mis-attributing the failure to the active account (the
            // PR #1018 regression that surfaced as a per-minute Icarus
            // sign-in modal). Skipped entries stay in the queue and flush
            // when the user switches back. `nil` from the provider (no
            // active library at all) skips every upload defensively.
            let activeAccountId = self.currentAccountIdProvider()
            let postableLibraryBooks = queuedLibraryBooks.filter { $0.libraryId == activeAccountId }
            let skippedLibraryBooks = queuedLibraryBooks.subtracting(postableLibraryBooks)

            for skipped in skippedLibraryBooks {
                self.audiobookLogger.logEvent(
                    forBookId: skipped.bookId,
                    event: """
                        Skipping cross-account playtimes upload:
                        Book Library ID: \(skipped.libraryId)
                        Active Library ID: \(activeAccountId ?? "nil")
                        Entries retained in queue for flush on switch-back.
                        """
                )
                TPPErrorLogger.logError(nil, summary: "Skipping cross-account playtimes upload", metadata: [
                    "bookLibraryId": skipped.libraryId,
                    "activeLibraryId": activeAccountId ?? "nil",
                    "bookId": skipped.bookId
                ])
            }

            // Track pending requests to end background task when all complete.
            // Skipped (cross-account) entries do NOT count toward pendingCount —
            // they produce no completion callback, so counting them would leak
            // the background task until iOS reclaims it.
            let pendingCount = postableLibraryBooks.count
            var completedCount = 0
            let countLock = NSLock()

            // If no postable entries (queue empty OR every entry is cross-
            // account), end background task immediately so iOS doesn't bill
            // the app for an open background slot that will never close.
            if pendingCount == 0 {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                return
            }

            for libraryBook in postableLibraryBooks {
                let requestData = RequestData(
                    libraryBook: libraryBook,
                    timeEntries: self.store.queue.filter { libraryBook == LibraryBook(time: $0) }
                )

                self.audiobookLogger.logEvent(
                    forBookId: libraryBook.bookId,
                    event: """
                        Preparing to upload time entries:
                        Book ID: \(libraryBook.bookId)
                        Library ID: \(libraryBook.libraryId)
                        Time Entries: \(requestData.timeEntries.map { "\($0)" }.joined(separator: ", "))
                        """
                )

                if let requestUrl = self.store.urls[libraryBook], let requestBody = requestData.jsonRepresentation {
                    var request = self.networkService.request(for: requestUrl)
                    request.httpMethod = "POST"
                    request.httpBody = requestBody
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.applyCustomUserAgent()

                    self.networkService.POST(request, useTokenIfAvailable: true) { [weak self] result, response, error in
                        defer {
                            // Track request completion for background task management
                            countLock.lock()
                            completedCount += 1
                            let allComplete = completedCount >= pendingCount
                            countLock.unlock()

                            if allComplete {
                                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                            }
                        }

                        guard let self = self else { return }

                        if let response = response as? HTTPURLResponse {
                            if response.statusCode == 404 {
                                TPPErrorLogger.logError(nil, summary: "Audiobook tracker data no longer valid", metadata: [
                                    "libraryId": libraryBook.libraryId,
                                    "bookId": libraryBook.bookId,
                                    "requestUrl": requestUrl,
                                    "requestBody": String(data: requestBody, encoding: .utf8) ?? ""
                                ])

                                self.audiobookLogger.logEvent(forBookId: libraryBook.bookId, event: """
                                    Removing time entries due to 404:
                                    Book ID: \(libraryBook.bookId)
                                    Library ID: \(libraryBook.libraryId)
                                    """)

                                self.store.queue.removeAll { $0.bookId == libraryBook.bookId && $0.libraryId == libraryBook.libraryId }
                                self.store.urls.removeValue(forKey: libraryBook)
                                self.saveStore()
                                return
                            } else if !response.isSuccess() {
                                TPPErrorLogger.logError(error, summary: "Error uploading audiobook tracker data", metadata: [
                                    "libraryId": libraryBook.libraryId,
                                    "bookId": libraryBook.bookId,
                                    "requestUrl": requestUrl,
                                    "requestBody": String(data: requestBody, encoding: .utf8) ?? "",
                                    "responseCode": response.statusCode,
                                    "responseBody": String(data: (result ?? Data()), encoding: .utf8) ?? ""
                                ])

                                self.audiobookLogger.logEvent(forBookId: libraryBook.bookId, event: """
                                    Failed to upload time entries:
                                    Book ID: \(libraryBook.bookId)
                                    Error: \(error?.localizedDescription ?? "Unknown error")
                                    Response Code: \(response.statusCode)
                                    """)
                            }
                        }

                        if let data = result, let responseData = ResponseData(data: data) {
                            for responseEntry in responseData.responses {
                                if responseEntry.status >= 400 {
                                    TPPErrorLogger.logError(error, summary: "Error entry in audiobook tracker response", metadata: [
                                        "libraryId": libraryBook.libraryId,
                                        "bookId": libraryBook.bookId,
                                        "requestUrl": requestUrl,
                                        "requestBody": String(data: requestBody, encoding: .utf8) ?? "",
                                        "entryId": responseEntry.id,
                                        "entryStatus": responseEntry.status,
                                        "entryMessage": responseEntry.message
                                    ])
                                } else {
                                    self.audiobookLogger.logEvent(forBookId: libraryBook.bookId, event: """
                                        Successfully uploaded time entry: \(responseEntry.id)
                                        """)
                                }
                            }

                            self.removeSynchronizedEntries(ids: responseData.responses.map { $0.id })
                            self.cleanUpUrls()
                        }
                    }
                } else {
                    // No request made for this book, count as complete
                    countLock.lock()
                    completedCount += 1
                    let allComplete = completedCount >= pendingCount
                    countLock.unlock()

                    if allComplete {
                        UIApplication.shared.endBackgroundTask(backgroundTaskId)
                    }
                }
            }
        }
    }

    private func loadStore() {
        guard let storeUrl, FileManager.default.fileExists(atPath: storeUrl.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: storeUrl)
            if let store = AudiobookDataManagerStore(data: data) {
                self.store = store
            }
        } catch {
            TPPErrorLogger.logError(error, summary: "AudiobookDataManager error opening time tracker store")
        }
    }

    private func saveStore() {
        guard let storeDirectoryUrl, let storeUrl else {
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: storeDirectoryUrl.path) {
                try FileManager.default.createDirectory(at: storeDirectoryUrl, withIntermediateDirectories: true)
            }
            storeDirectoryUrl.excludeFromBackup()
            try store.jsonRepresentation?.write(to: storeUrl)
        } catch {
            TPPErrorLogger.logError(error, summary: "AudiobookDataManager error saving time tracker store")
        }
    }

    private var storeDirectoryUrl: URL? {
        return TPPBookContentMetadataFilesHelper.directory(for: "timetracker")
    }

    private var storeUrl: URL? {
        return storeDirectoryUrl?.appendingPathComponent("store.json")
    }

    private func cleanUpUrls() {
        let remainingLibraryBooks: Set<LibraryBook> = Set(store.queue.map { LibraryBook(time: $0) })
        store.urls = store.urls.filter { remainingLibraryBooks.contains($0.key) }
        saveStore()
    }

    private func removeSynchronizedEntries(ids: [String]) {
        store.queue = store.queue.filter { !ids.contains($0.id) }
        saveStore()
    }
}

extension AudiobookDataManager: DataManager {
    func save(time: TimeEntry) {
        guard let timeEntry = time as? AudiobookTimeEntry else {
            return
        }
        save(time: timeEntry)
    }
}

//
//  TPPBookRegistrySyncEventTests.swift
//  PalaceTests
//
//  The registry's sync-event and registry-changed publishers (PP-5470): when
//  each fires, what a failure carries, and that both deliver on main.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class TPPBookRegistrySyncEventTests: XCTestCase {

    private static let loansURL = URL(string: "https://sync-event-test.example.com/loans")!

    private var tempDirectory: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncEventTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeRegistry(
        scope: SyncEventAccountScope,
        feedFetcher: OPDSFeedFetching = FailingLoansFeedFetcher(userInfo: [:])
    ) -> TPPBookRegistry {
        let directory = tempDirectory!
        return TPPBookRegistry(
            accountScope: scope,
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { AbsentContentDownloadService() },
                loansFeedFetcher: { feedFetcher },
                sideloadedIdentifiers: { [] },
                registryDirectory: { directory.appendingPathComponent($0) },
                onAvailabilityChange: { _, _ in }
            )
        )
    }

    private func load(_ registry: TPPBookRegistry) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: nil) { continuation.resume() }
        }
    }

    private func collectSyncEvents(from registry: TPPBookRegistry) -> LockIsolated<[RegistrySyncEvent]> {
        let events = LockIsolated<[RegistrySyncEvent]>([])
        registry.syncEventPublisher
            .sink { event in events.withValue { $0.append(event) } }
            .store(in: &cancellables)
        return events
    }

    private func countRegistryChanges(from registry: TPPBookRegistry) -> LockIsolated<Int> {
        let count = LockIsolated(0)
        registry.registryDidChangePublisher
            .sink { count.withValue { $0 += 1 } }
            .store(in: &cancellables)
        return count
    }

    private func makeBook(_ identifier: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: identifier, distributorType: .EpubZip)
    }

    // MARK: - Sync lifecycle

    /// A failed loans sync reports, in order: the sync began, it ended, and why
    /// it failed. Holds relies on that order to drop its placeholder and then
    /// decide on the error banner.
    func testSync_WhenLoansFetchFails_PublishesBeganEndedThenFailedWithDetail() async {
        let fetcher = FailingLoansFeedFetcher(userInfo: ["detail": "Your card has expired."])
        let registry = makeRegistry(
            scope: SyncEventAccountScope(accountID: "sync-event-lib", loansURL: Self.loansURL),
            feedFetcher: fetcher
        )
        await load(registry)
        let events = collectSyncEvents(from: registry)

        // The completion runs after the failure is reported; the drain then
        // lands the publisher's main-queue delivery.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.sync { _, _ in continuation.resume() }
        }
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.began, .ended, .failed(detail: "Your card has expired.")])
    }

    // MARK: - reportSyncFailure

    func testReportSyncFailure_WithDetail_PublishesDetail() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let events = collectSyncEvents(from: registry)

        registry.reportSyncFailure(errorDocument: ["title": "Title", "detail": "Detail text"])
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.failed(detail: "Detail text")])
    }

    func testReportSyncFailure_WithTitleOnly_PublishesTitle() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let events = collectSyncEvents(from: registry)

        registry.reportSyncFailure(errorDocument: ["title": "Authentication Required"])
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.failed(detail: "Authentication Required")])
    }

    /// An empty `detail` is not replaced by the title; Holds then shows its
    /// generic message, as it did when it read the error document itself.
    func testReportSyncFailure_WithEmptyDetail_PublishesNilDetail() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let events = collectSyncEvents(from: registry)

        registry.reportSyncFailure(errorDocument: ["detail": "", "title": "Ignored"])
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.failed(detail: nil)])
    }

    func testReportSyncFailure_WithoutErrorDocument_PublishesNilDetail() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let events = collectSyncEvents(from: registry)

        registry.reportSyncFailure(errorDocument: nil)
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.failed(detail: nil)])
    }

    /// The post-return sync reports from a background task; listeners are
    /// main-actor view models, so delivery must be on main.
    func testReportSyncFailure_FromBackgroundThread_DeliversOnMain() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let deliveredOnMain = LockIsolated<Bool?>(nil)
        registry.syncEventPublisher
            .sink { _ in deliveredOnMain.withValue { $0 = Thread.isMainThread } }
            .store(in: &cancellables)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                registry.reportSyncFailure(errorDocument: nil)
                continuation.resume()
            }
        }
        // The delivery was queued on main during the send, ahead of this drain.
        await drainMainQueueAsync()

        XCTAssertEqual(deliveredOnMain.value, true)
    }

    // MARK: - reportSyncEnded

    func testReportSyncEnded_PublishesEnded() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let events = collectSyncEvents(from: registry)

        registry.reportSyncEnded()
        await drainMainQueueAsync()

        XCTAssertEqual(events.value, [.ended])
    }

    // MARK: - registryDidChangePublisher

    func testAddBook_PublishesRegistryDidChange() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let changes = countRegistryChanges(from: registry)

        registry.addBook(makeBook("change-book"), state: .downloadNeeded)
        await registry._awaitPendingWritesForTesting()
        await drainMainQueueAsync()

        XCTAssertEqual(changes.value, 1)
    }

    func testNotifyRegistryChanged_PublishesRegistryDidChange() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: nil))
        let changes = countRegistryChanges(from: registry)

        registry.notifyRegistryChanged()
        await drainMainQueueAsync()

        XCTAssertEqual(changes.value, 1)
    }

    /// Each announcement below is one main-queue send; the count pins every
    /// source, so dropping any one of them fails the test.
    private func settleAnnouncements(of registry: TPPBookRegistry) async {
        await registry._awaitPendingPersistenceForTesting()
        await drainMainQueueAsync()
        await drainMainQueueAsync()
    }

    /// Loading a saved shelf announces a change, so screens opened before the
    /// load finished show its books. Two sends: the store write and the end of
    /// the load.
    func testLoad_OfSavedShelf_PublishesRegistryDidChangeTwice() async {
        let scope = SyncEventAccountScope(accountID: "load-lib")
        let writer = makeRegistry(scope: scope)
        writer.addBook(makeBook("saved-book"), state: .downloadNeeded)
        await settleAnnouncements(of: writer)
        let reader = makeRegistry(scope: scope)
        let changes = countRegistryChanges(from: reader)

        await load(reader)
        await settleAnnouncements(of: reader)

        XCTAssertEqual(reader.allBooks.map(\.identifier), ["saved-book"], "precondition: the saved shelf loaded")
        XCTAssertEqual(changes.value, 2)
    }

    /// Marking a downloaded book whose file is gone announces the change, so
    /// its button turns back to Download. Three sends: the store write, the
    /// shelf save, and the validation itself.
    func testValidateDownloadedContent_WhenFileMissing_PublishesRegistryDidChange() async {
        let registry = makeRegistry(scope: SyncEventAccountScope(accountID: "validate-lib"))
        registry.addBook(makeBook("missing-file-book"), state: .downloadSuccessful)
        await settleAnnouncements(of: registry)
        let changes = countRegistryChanges(from: registry)

        registry.validateDownloadedContent()
        await settleAnnouncements(of: registry)

        XCTAssertEqual(registry.state(for: "missing-file-book"), .downloadNeeded)
        XCTAssertEqual(changes.value, 3)
    }

    /// Clearing the shelf on a library switch is not a registry change: Holds
    /// reads a change as an answered sync, and the new library's first sync
    /// must still show the placeholder (PP-5468).
    func testAccountChange_ClearsRecordsWithoutPublishingRegistryDidChange() async {
        // No current account: the reload that follows the switch has nothing to
        // load, so only the clearing step runs.
        let scope = SyncEventAccountScope(accountID: nil)
        let registry = makeRegistry(scope: scope)
        registry.addBook(makeBook("previous-library-book"), state: .downloadNeeded)
        await registry._awaitPendingWritesForTesting()
        await drainMainQueueAsync()
        let changes = countRegistryChanges(from: registry)
        let cleared = registry.registryPublisher.dropFirst()

        scope.sendAccountDidChange()

        await awaitPublishedAsync(cleared) { $0.isEmpty }
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        XCTAssertEqual(changes.value, 0)
    }
}

// MARK: - Test doubles

/// Account scope whose account-change signal the test fires by hand.
private final class SyncEventAccountScope: AccountScopeProviding, @unchecked Sendable {
    private let accountID: String?
    private let loansURL: URL?
    private let accountDidChange = PassthroughSubject<Void, Never>()

    init(accountID: String?, loansURL: URL? = nil) {
        self.accountID = accountID
        self.loansURL = loansURL
    }

    var currentAccountID: String? { accountID }
    var accountDidChangePublisher: AnyPublisher<Void, Never> { accountDidChange.eraseToAnyPublisher() }
    func hasCredentials(forAccount accountID: String) -> Bool { true }
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? { loansURL }

    func sendAccountDidChange() { accountDidChange.send(()) }
}

/// Reports every content file as absent and no download in flight.
private final class AbsentContentDownloadService: RegistryDownloadServicing, @unchecked Sendable {
    func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
    func startDownload(for book: TPPBook) {}
    func deleteLocalContent(forBook book: TPPBook, account: String?) {}
    func redownloadLCPContentFile(for book: TPPBook) {}
    func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
    func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
    func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence { .absent }
    func isDownloadInFlight(for book: TPPBook) -> Bool { false }
}

/// Fails every fetch with an `NSError` whose `userInfo` is the error document.
private final class FailingLoansFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let userInfo: [String: Any]
    init(userInfo: [String: Any]) { self.userInfo = userInfo }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        throw NSError(domain: "SyncEventTests", code: 401, userInfo: userInfo)
    }

    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url)
    }
}

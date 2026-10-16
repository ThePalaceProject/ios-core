//
//  OfflineQueueLibraryScopeTests.swift
//  PalaceTests
//
//  A queued offline action belongs to the library it was made under. Draining
//  it while another library is current reads that library's registry, so the
//  queue must hold it until its own library is current again.
//

import XCTest
import UIKit
import PalaceAuth
import PalaceCatalog
@testable import Palace
@testable import PalaceBookRegistry
import PalaceBookModel

@MainActor
final class OfflineQueueLibraryScopeTests: XCTestCase {

    private static let suiteName = "OfflineQueueLibraryScopeTests"
    private static let libraryA = "library-A"
    private static let libraryB = "library-B"
    private static let storageKey = "Palace.Platform.offlineQueue"

    private var registry: TPPBookRegistryMock!
    private var circulation: FakeCirculation!
    private var currentLibrary: LockIsolated<String?>!
    private var queue: OfflineQueueService!
    /// Retained: the executor it installs holds it weakly.
    private var coordinator: OfflineQueueCoordinator!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: Self.suiteName)!.removePersistentDomain(forName: Self.suiteName)
        registry = TPPBookRegistryMock()
        registry.loadedAccountID = Self.libraryA
        circulation = FakeCirculation()
        let current = LockIsolated<String?>(Self.libraryA)
        currentLibrary = current
        queue = OfflineQueueService(
            userDefaults: UserDefaults(suiteName: Self.suiteName)!,
            backoffSleep: { _ in },
            currentLibraryID: { current.value },
            monitorsNetwork: false
        )
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)!.removePersistentDomain(forName: Self.suiteName)
        coordinator = nil
        queue = nil
        currentLibrary = nil
        circulation = nil
        registry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueue() -> OfflineQueueService {
        let current = currentLibrary!
        return OfflineQueueService(
            userDefaults: UserDefaults(suiteName: Self.suiteName)!,
            backoffSleep: { _ in },
            currentLibraryID: { current.value },
            monitorsNetwork: false
        )
    }

    private func makeCoordinator() -> OfflineQueueCoordinator {
        let current = currentLibrary!
        coordinator = OfflineQueueCoordinator.production(
            queue: queue,
            downloadCenter: circulation,
            bookRegistry: registry,
            currentLibraryID: { current.value }
        )
        return coordinator
    }

    private func makeReturnService(
        userAccountProvider: @escaping () -> TPPUserAccount = { TPPUserAccountMock() },
        feedFetcher: OPDSFeedFetching = OfflineFeedFetcher(),
        enqueuer: (@Sendable (OfflineAction) async -> Void)? = nil,
        authCoordinator: AuthCoordinator? = nil,
        reauthenticator: Reauthenticator = TPPReauthenticatorMock(),
        alerts: AlertSpy = AlertSpy()
    ) -> BookReturnService {
        BookReturnService(
            bookRegistry: registry,
            localContentService: LocalBookContentService(
                bookRegistry: registry,
                accountsManager: makeTestAppContainer().accountsManager,
                bookFileManager: BookFileManager(bookRegistry: registry)),
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: DownloadAnnouncementService(),
            bookmarkDeletionLog: .shared,
            reauthenticator: reauthenticator,
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: userAccountProvider,
            authCoordinator: authCoordinator,
            offlineReturnEnqueuer: enqueuer,
            alertPresenter: { alerts.record($0) }
        )
    }

    private func action(_ type: OfflineActionType, _ bookID: String, in library: String) -> OfflineAction {
        OfflineAction(type: type, bookID: bookID, bookTitle: bookID, libraryID: library)
    }

    /// Changes the current library only; the registry keeps its old records
    /// until `finishRegistryLoad()`, as the real registry does while it reloads.
    private func switchLibrary(to library: String) {
        currentLibrary.value = library
    }

    /// The registry finishes loading the current library and announces it.
    private func finishRegistryLoad() {
        registry.loadedAccountID = currentLibrary.value
        registry.state = .loaded
    }

    // MARK: - Cross-library drain

    /// A return queued under library A and drained after switching to B must
    /// stay pending; the real return flow would find no such book in B's
    /// registry and the executor would read that as a confirmed return.
    func testQueuedReturn_drainedAfterSwitchingLibrary_staysPendingAndIsNotConfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        let queued = action(.return, book.identifier, in: Self.libraryA)
        await queue.enqueue(queued)   // no executor yet, so nothing drains

        switchLibrary(to: Self.libraryB)
        registry.removeBook(forIdentifier: book.identifier)   // B's shelf
        circulation.returnService = makeReturnService()
        await makeCoordinator().registerExecutor()
        await queue.processQueue()

        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id],
                       "a return from another library must stay queued, not be confirmed")
        XCTAssertEqual(pending.first?.retryCount, 0)
        XCTAssertEqual(circulation.returnCalls, [],
                       "the return flow must not run against another library's registry")
    }

    /// A borrow queued under A must not run while B is current: it neither
    /// spends its retries nor ends in `.failed`.
    func testQueuedBorrow_drainedAfterSwitchingLibrary_staysPendingWithRetriesIntact() async {
        let queued = action(.borrow, "borrow-book", in: Self.libraryA)
        await queue.enqueue(queued)

        switchLibrary(to: Self.libraryB)
        await makeCoordinator().registerExecutor()
        await queue.processQueue()

        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id])
        XCTAssertEqual(pending.first?.retryCount, 0, "no retry is spent while the library is not current")
        let failed = await queue.actions(withState: .failed)
        XCTAssertTrue(failed.isEmpty)
    }

    /// When library B holds a book with the same identifier, a borrow queued
    /// under A must not borrow B's copy.
    func testQueuedBorrow_whenOtherLibraryHasSameBookID_doesNotBorrowThere() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let queued = action(.borrow, book.identifier, in: Self.libraryA)
        await queue.enqueue(queued)
        switchLibrary(to: Self.libraryB)
        registry.addBook(book, state: .unregistered)   // B's catalog entry, same ID

        await makeCoordinator().registerExecutor()
        await queue.processQueue()

        XCTAssertEqual(circulation.borrowCalls, [], "B's copy must not be borrowed")
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id])
    }

    /// A hold queued under A must not be placed at B, and stays queued.
    func testQueuedHold_drainedAfterSwitchingLibrary_isNotPlacedAndStaysPending() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let queued = action(.hold, book.identifier, in: Self.libraryA)
        await queue.enqueue(queued)
        switchLibrary(to: Self.libraryB)
        registry.addBook(book, state: .unregistered)

        await makeCoordinator().registerExecutor()
        await queue.processQueue()

        XCTAssertEqual(circulation.borrowCalls, [])
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id])
        XCTAssertEqual(pending.first?.retryCount, 0)
    }

    /// With A current, the queue drains A's actions in order and leaves B's
    /// action in place between them.
    func testDrain_runsOnlyCurrentLibraryActions_inFIFOOrder() async {
        let executed = LockIsolated<[String]>([])
        await queue.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        await queue.networkStatusChanged(isAvailable: false)
        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))
        let other = action(.borrow, "b1", in: Self.libraryB)
        await queue.enqueue(other)
        await queue.enqueue(action(.borrow, "a2", in: Self.libraryA))

        await queue.networkStatusChanged(isAvailable: true)

        XCTAssertEqual(executed.value, ["a1", "a2"])
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [other.id])
    }

    /// With no current library, nothing drains.
    func testDrain_withNoCurrentLibrary_runsNothing() async {
        let executed = LockIsolated<[String]>([])
        await queue.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        currentLibrary.value = nil

        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))

        XCTAssertEqual(executed.value, [])
    }

    // MARK: - Draining when the library is current again

    /// Once A's registry has loaded after switching back, its load starts the
    /// drain and the same-library confirmation completes A's return.
    func testLibraryChange_backToOriginLibrary_drainsAndCompletesReturn() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let queued = action(.return, book.identifier, in: Self.libraryA)
        switchLibrary(to: Self.libraryB)
        await queue.enqueue(queued)
        circulation.removesBookOnReturn = registry
        registry.addBook(book, state: .downloadSuccessful)
        await makeCoordinator().registerExecutor()
        await queue.processQueue()
        XCTAssertEqual(circulation.returnCalls, [], "precondition: held while B is current")

        switchLibrary(to: Self.libraryA)
        finishRegistryLoad()   // A's shelf, holding the book, has loaded
        await coordinator._awaitTriggeredDrainsForTesting()

        XCTAssertEqual(circulation.returnCalls, [book.identifier])
        let remaining = await queue.currentStatus()
        XCTAssertEqual(remaining.pendingCount, 0)
    }

    /// While offline, the drain entry point does nothing.
    func testDrainIfOnline_whileOffline_doesNotDrain() async {
        let executed = LockIsolated<[String]>([])
        await queue.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        await queue.networkStatusChanged(isAvailable: false)
        switchLibrary(to: Self.libraryB)
        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))

        switchLibrary(to: Self.libraryA)
        await queue.drainIfOnline()

        XCTAssertEqual(executed.value, [])
    }

    /// Online, the drain entry point runs the now-runnable library's actions.
    func testDrainIfOnline_whileOnline_drainsNewlyCurrentLibrary() async {
        let executed = LockIsolated<[String]>([])
        switchLibrary(to: Self.libraryB)
        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))
        await queue.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        await queue.networkStatusChanged(isAvailable: true)
        XCTAssertEqual(executed.value, [], "precondition: held while B is current")

        switchLibrary(to: Self.libraryA)
        await queue.drainIfOnline()

        XCTAssertEqual(executed.value, ["a1"])
    }

    // MARK: - Registry not yet loaded for the current library

    /// Switching back to A before the registry has reloaded A's shelf: the
    /// store still holds B's records, so A's queued return must not run.
    func testSwitchBack_beforeRegistryReloads_returnStaysPendingAndUnconfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let queued = action(.return, book.identifier, in: Self.libraryA)
        switchLibrary(to: Self.libraryB)
        finishRegistryLoad()
        await queue.enqueue(queued)
        circulation.returnService = makeReturnService()
        await makeCoordinator().registerExecutor()

        switchLibrary(to: Self.libraryA)   // registry still holds B's shelf
        await queue.drainIfOnline()

        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id], "the return must wait for A's registry")
        XCTAssertEqual(pending.first?.retryCount, 0)
        XCTAssertEqual(circulation.returnCalls, [])
    }

    /// The same window when B's stale shelf holds a book with the same ID:
    /// B's record must not be returned under A's credentials.
    func testSwitchBack_beforeRegistryReloads_doesNotReturnOtherLibrarysSameIDBook() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let queued = action(.return, book.identifier, in: Self.libraryA)
        switchLibrary(to: Self.libraryB)
        finishRegistryLoad()
        await queue.enqueue(queued)
        registry.addBook(book, state: .downloadSuccessful)   // B's copy
        await makeCoordinator().registerExecutor()

        switchLibrary(to: Self.libraryA)
        await queue.drainIfOnline()

        XCTAssertEqual(circulation.returnCalls, [])
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id])
    }

    /// At launch the queue can drain before the registry's first load: an
    /// empty store must not confirm a persisted return.
    func testLaunchDrain_beforeFirstRegistryLoad_returnStaysPending() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let persisted = action(.return, book.identifier, in: Self.libraryA)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([persisted]), forKey: Self.storageKey)
        queue = makeQueue()
        registry.loadedAccountID = nil   // first load still pending
        circulation.returnService = makeReturnService()
        await makeCoordinator().registerExecutor()

        await queue.networkStatusChanged(isAvailable: true)

        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [persisted.id])
        XCTAssertEqual(pending.first?.retryCount, 0)
        XCTAssertEqual(circulation.returnCalls, [])
    }

    /// When the first load finishes with the book on A's shelf, the load
    /// starts the drain and the return runs.
    func testLaunchDrain_afterFirstRegistryLoad_runsTheReturn() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let persisted = action(.return, book.identifier, in: Self.libraryA)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([persisted]), forKey: Self.storageKey)
        queue = makeQueue()
        registry.loadedAccountID = nil
        circulation.removesBookOnReturn = registry
        await makeCoordinator().registerExecutor()
        registry.addBook(book, state: .downloadSuccessful)

        finishRegistryLoad()
        await coordinator._awaitTriggeredDrainsForTesting()

        XCTAssertEqual(circulation.returnCalls, [book.identifier])
        let remaining = await queue.currentStatus()
        XCTAssertEqual(remaining.pendingCount, 0)
    }

    // MARK: - Mixed libraries

    /// Two libraries interleaved, with A's first action failing twice: A's
    /// retries stay with A, and B's action waits untouched until B is current.
    func testInterleavedLibraries_withRetries_retriesStayWithTheirLibrary() async {
        let attempts = LockIsolated<[String]>([])
        await queue.setExecutor { action in
            let count = attempts.withValue { list -> Int in
                list.append(action.bookID)
                return list.filter { $0 == action.bookID }.count
            }
            return action.bookID != "a1" || count >= 3
        }
        await queue.networkStatusChanged(isAvailable: false)
        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))
        let b1 = action(.borrow, "b1", in: Self.libraryB)
        await queue.enqueue(b1)
        await queue.enqueue(action(.borrow, "a2", in: Self.libraryA))

        await queue.networkStatusChanged(isAvailable: true)

        XCTAssertEqual(attempts.value, ["a1", "a1", "a1", "a2"])
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [b1.id])
        XCTAssertEqual(pending.first?.retryCount, 0)

        switchLibrary(to: Self.libraryB)
        await queue.drainIfOnline()

        XCTAssertEqual(attempts.value, ["a1", "a1", "a1", "a2", "b1"])
        let status = await queue.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
    }

    /// A library switch during a drain stops A's remaining actions and runs
    /// B's, because each pick reads the current library afresh.
    func testLibrarySwitchDuringDrain_stopsRemainingActionsAndRunsNewLibrarys() async {
        let executed = LockIsolated<[String]>([])
        let current = currentLibrary!
        let libraryB = Self.libraryB
        await queue.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            if action.bookID == "a1" { current.value = libraryB }
            return true
        }
        await queue.networkStatusChanged(isAvailable: false)
        await queue.enqueue(action(.borrow, "a1", in: Self.libraryA))
        let a2 = action(.borrow, "a2", in: Self.libraryA)
        await queue.enqueue(a2)
        await queue.enqueue(action(.borrow, "b1", in: Self.libraryB))

        await queue.networkStatusChanged(isAvailable: true)

        XCTAssertEqual(executed.value, ["a1", "b1"])
        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [a2.id])
    }

    /// Relaunch with persisted actions from two libraries, one left in
    /// `.processing` by the previous run: all come back pending, in order, and
    /// only the current library's run.
    func testRelaunch_withMixedLibrariesAndStaleProcessing_resumesCurrentLibraryOnly() async throws {
        var stale = action(.return, "a-stale", in: Self.libraryA)
        stale.state = .processing
        let b1 = action(.borrow, "b1", in: Self.libraryB)
        let a2 = action(.borrow, "a2", in: Self.libraryA)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([stale, b1, a2]), forKey: Self.storageKey)

        let relaunched = makeQueue()
        let pendingAtLoad = await relaunched.actions(withState: .pending)
        let executed = LockIsolated<[String]>([])
        await relaunched.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        await relaunched.processQueue()

        XCTAssertEqual(pendingAtLoad.map(\.id), [stale.id, b1.id, a2.id])
        XCTAssertEqual(executed.value, ["a-stale", "a2"])
        let pending = await relaunched.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [b1.id])
    }

    /// Dropping legacy actions rewrites storage once; the next launch, with
    /// nothing left to drop, writes nothing.
    func testLegacyDrop_rewritesStorageOnce_secondLaunchWritesNothing() async throws {
        let scoped = action(.return, "scoped", in: Self.libraryA)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(scoped)) as? [String: Any])
        legacyJSON.removeValue(forKey: "libraryID")
        legacyJSON["id"] = UUID().uuidString
        let scopedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scoped))
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONSerialization.data(withJSONObject: [legacyJSON, scopedJSON]), forKey: Self.storageKey)
        let writes = LockIsolated(0)

        _ = OfflineQueueService(
            userDefaults: CountingDefaults(suiteName: Self.suiteName, key: Self.storageKey, writes: writes)!,
            currentLibraryID: { nil }, monitorsNetwork: false)
        let afterFirstLaunch = writes.value
        _ = OfflineQueueService(
            userDefaults: CountingDefaults(suiteName: Self.suiteName, key: Self.storageKey, writes: writes)!,
            currentLibraryID: { nil }, monitorsNetwork: false)

        XCTAssertEqual(afterFirstLaunch, 1)
        XCTAssertEqual(writes.value, 1, "a second launch has nothing to drop and writes nothing")
    }

    // MARK: - Legacy persisted actions

    /// Actions persisted before `libraryID` existed are dropped at load and
    /// never executed, and the stored queue is rewritten without them.
    func testLoad_dropsActionsPersistedWithoutLibrary_andKeepsScopedOnes() async throws {
        let scoped = action(.return, "scoped", in: Self.libraryA)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(scoped)) as? [String: Any])
        legacyJSON.removeValue(forKey: "libraryID")
        legacyJSON["id"] = UUID().uuidString
        legacyJSON["bookID"] = "legacy"
        let scopedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scoped))
        let stored = try JSONSerialization.data(withJSONObject: [legacyJSON, scopedJSON])
        UserDefaults(suiteName: Self.suiteName)!.set(stored, forKey: Self.storageKey)

        let reloaded = makeQueue()
        let rewritten = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName)!.data(forKey: Self.storageKey))
        let persistedAtLoad = try JSONDecoder().decode([OfflineAction].self, from: rewritten)
        let executed = LockIsolated<[String]>([])
        await reloaded.setExecutor { action in
            executed.withValue { $0.append(action.bookID) }
            return true
        }
        let pendingBeforeDrain = await reloaded.actions(withState: .pending)
        await reloaded.processQueue()

        XCTAssertEqual(persistedAtLoad.map(\.bookID), ["scoped"], "the load itself rewrites storage")
        XCTAssertEqual(pendingBeforeDrain.map(\.bookID), ["scoped"])
        XCTAssertEqual(executed.value, ["scoped"], "the legacy action must never run")
    }

    /// One action this build cannot decode, such as a type added by a newer
    /// build before a downgrade, must not cost the patron every other queued action.
    func testLoad_withAnUndecodableAction_keepsTheDecodableOnes() async throws {
        let first = action(.return, "one", in: Self.libraryA)
        let second = action(.borrow, "two", in: Self.libraryB)
        var unknownJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        unknownJSON["type"] = "typeFromANewerBuild"
        unknownJSON["id"] = UUID().uuidString
        let stored = try JSONSerialization.data(withJSONObject: [
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)),
            unknownJSON,
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(second)),
        ])
        UserDefaults(suiteName: Self.suiteName)!.set(stored, forKey: Self.storageKey)

        let reloaded = makeQueue()
        let pending = await reloaded.actions(withState: .pending)

        XCTAssertEqual(pending.map(\.id), [first.id, second.id])
    }

    /// A stored queue made only of current actions is loaded unchanged.
    func testLoad_withOnlyScopedActions_keepsAll() async throws {
        let first = action(.return, "one", in: Self.libraryA)
        let second = action(.borrow, "two", in: Self.libraryB)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([first, second]), forKey: Self.storageKey)

        let reloaded = makeQueue()
        let pending = await reloaded.actions(withState: .pending)

        XCTAssertEqual(pending.map(\.id), [first.id, second.id])
        XCTAssertEqual(pending.map(\.libraryID), [Self.libraryA, Self.libraryB])
    }

    // MARK: - Sign-out

    /// Signing out of A removes A's queued actions in every state and leaves
    /// B's in place.
    func testRemoveActionsForLibrary_removesOnlyThatLibrary() async throws {
        let aPending = action(.return, "a-pending", in: Self.libraryA)
        var aFailed = action(.borrow, "a-failed", in: Self.libraryA)
        aFailed.state = .failed
        let bPending = action(.return, "b-pending", in: Self.libraryB)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([aPending, aFailed, bPending]), forKey: Self.storageKey)
        let seeded = makeQueue()

        await seeded.removeActions(forLibrary: Self.libraryA)

        let pending = await seeded.actions(withState: .pending)
        let failed = await seeded.actions(withState: .failed)
        XCTAssertEqual(pending.map(\.id), [bPending.id])
        XCTAssertTrue(failed.isEmpty, "failed actions of the signed-out library go too")
        let reloaded = makeQueue()
        let persisted = await reloaded.actions(withState: .pending)
        XCTAssertEqual(persisted.map(\.id), [bPending.id], "the removal is persisted")
    }

    /// Removing a library with no queued actions leaves the queue as it was.
    func testRemoveActionsForLibrary_withNoMatches_keepsQueue() async throws {
        let bPending = action(.return, "b-pending", in: Self.libraryB)
        UserDefaults(suiteName: Self.suiteName)!.set(
            try JSONEncoder().encode([bPending]), forKey: Self.storageKey)
        let seeded = makeQueue()

        await seeded.removeActions(forLibrary: Self.libraryA)

        let pending = await seeded.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [bPending.id])
    }

    // MARK: - Coordinator re-checks

    /// Handed an action from another library directly, each handler declines
    /// without touching circulation.
    func testExecute_actionFromAnotherLibrary_declinesEveryType() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .unregistered)
        switchLibrary(to: Self.libraryB)
        let coordinator = makeCoordinator()

        for type in [OfflineActionType.return, .borrow, .hold, .cancelHold] {
            let result = await coordinator.execute(action(type, book.identifier, in: Self.libraryA))
            XCTAssertEqual(result, .failed, "\(type) from another library must not be confirmed")
        }
        XCTAssertEqual(circulation.returnCalls, [])
        XCTAssertEqual(circulation.borrowCalls, [])
    }

    /// Same-library control: a return whose flow removes the book is confirmed.
    func testExecute_sameLibraryReturn_isConfirmedWhenBookIsGone() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        circulation.removesBookOnReturn = registry

        let result = await makeCoordinator().execute(action(.return, book.identifier, in: Self.libraryA))

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(circulation.returnCalls, [book.identifier])
    }

    /// Same-library control: a return that leaves the book on the shelf in an
    /// active state is not confirmed.
    func testExecute_sameLibraryReturn_withBookStillActive_isNotConfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let result = await makeCoordinator().execute(action(.return, book.identifier, in: Self.libraryA))

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(circulation.returnCalls, [book.identifier])
    }

    /// A library switch while the return is in flight leaves the registry
    /// describing the other library, so the return is not confirmed.
    func testExecute_returnWhenLibrarySwitchesMidFlight_isNotConfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        circulation.removesBookOnReturn = registry
        let current = currentLibrary!
        circulation.onCall = { current.value = Self.libraryB }

        let result = await makeCoordinator().execute(action(.return, book.identifier, in: Self.libraryA))

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(circulation.returnCalls, [book.identifier])
    }

    /// A registry reload starting while the return is in flight leaves no
    /// loaded shelf to confirm against, so the return is not confirmed.
    func testExecute_returnWhenRegistryReloadsMidFlight_isNotConfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        circulation.removesBookOnReturn = registry
        let registry = self.registry!
        circulation.onCall = { registry.loadedAccountID = nil }

        let result = await makeCoordinator().execute(action(.return, book.identifier, in: Self.libraryA))

        XCTAssertEqual(result, .failed)
    }

    /// Handed an action before the current library's registry has loaded,
    /// each handler declines without touching circulation.
    func testExecute_beforeRegistryLoadsCurrentLibrary_declinesEveryType() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .unregistered)
        registry.loadedAccountID = Self.libraryB
        let coordinator = makeCoordinator()

        for type in [OfflineActionType.return, .borrow, .hold, .cancelHold] {
            let result = await coordinator.execute(action(type, book.identifier, in: Self.libraryA))
            XCTAssertEqual(result, .failed, "\(type) must wait for the library's registry")
        }
        XCTAssertEqual(circulation.returnCalls, [])
        XCTAssertEqual(circulation.borrowCalls, [])
    }

    func testRunnableLibraryID_isCurrentOnlyOnceLoaded() {
        XCTAssertEqual(OfflineQueueCoordinator.runnableLibraryID(current: "A", loaded: "A"), "A")
        XCTAssertNil(OfflineQueueCoordinator.runnableLibraryID(current: "A", loaded: "B"))
        XCTAssertNil(OfflineQueueCoordinator.runnableLibraryID(current: "A", loaded: nil))
        XCTAssertNil(OfflineQueueCoordinator.runnableLibraryID(current: nil, loaded: nil))
    }

    /// Same-library control for borrow and hold: the expected end state confirms.
    func testExecute_sameLibraryBorrowAndHold_areConfirmed() async {
        let borrowBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(borrowBook, state: .unregistered)
        circulation.borrowEndState = (registry, .downloadNeeded)
        let coordinator = makeCoordinator()

        let borrowed = await coordinator.execute(action(.borrow, borrowBook.identifier, in: Self.libraryA))
        circulation.borrowEndState = (registry, .holding)
        let held = await coordinator.execute(action(.hold, borrowBook.identifier, in: Self.libraryA))

        XCTAssertEqual(borrowed, .confirmed)
        XCTAssertEqual(held, .confirmed)
        XCTAssertEqual(circulation.borrowCalls, [borrowBook.identifier, borrowBook.identifier])
    }

    /// A library switch during a borrow or hold leaves no confirmation, even
    /// when the registry shows the expected state.
    func testExecute_borrowAndHoldWhenLibrarySwitchesMidFlight_areNotConfirmed() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .unregistered)
        let current = currentLibrary!
        circulation.onCall = { current.value = Self.libraryB }
        let coordinator = makeCoordinator()

        circulation.borrowEndState = (registry, .downloadNeeded)
        let borrowed = await coordinator.execute(action(.borrow, book.identifier, in: Self.libraryA))
        switchLibrary(to: Self.libraryA)
        circulation.borrowEndState = (registry, .holding)
        let held = await coordinator.execute(action(.hold, book.identifier, in: Self.libraryA))

        XCTAssertEqual(borrowed, .failed)
        XCTAssertEqual(held, .failed)
        XCTAssertEqual(circulation.borrowCalls.count, 2)
    }

    // MARK: - Completion called more than once

    /// The return flow's failure alert completes once when shown and again if
    /// the patron picks Remove from Device; the first report decides, and the
    /// second does not resume the drain a second time.
    func testExecute_returnWhoseCompletionFiresTwice_reportsFirstOutcomeOnly() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        let registry = self.registry!
        circulation.completionCalls = 2
        circulation.betweenCompletions = { registry.removeBook(forIdentifier: book.identifier) }

        let result = await makeCoordinator().execute(action(.return, book.identifier, in: Self.libraryA))

        XCTAssertEqual(result, .failed, "the return was not confirmed when it first completed")
        XCTAssertEqual(circulation.returnCalls, [book.identifier])
    }

    /// Borrow and hold tolerate a repeated completion the same way.
    func testExecute_borrowAndHoldWhoseCompletionFiresTwice_reportFirstOutcomeOnly() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .unregistered)
        let registry = self.registry!
        circulation.completionCalls = 2
        let coordinator = makeCoordinator()

        circulation.betweenCompletions = { registry.setState(.downloadNeeded, for: book.identifier) }
        let borrowed = await coordinator.execute(action(.borrow, book.identifier, in: Self.libraryA))
        registry.setState(.unregistered, for: book.identifier)
        circulation.betweenCompletions = { registry.setState(.holding, for: book.identifier) }
        let held = await coordinator.execute(action(.hold, book.identifier, in: Self.libraryA))

        XCTAssertEqual(borrowed, .failed)
        XCTAssertEqual(held, .failed)
        XCTAssertEqual(circulation.borrowCalls.count, 2)
    }

    // MARK: - Unreachable server during a drain

    /// A drained return that finds the server unreachable stays pending with
    /// its retries intact, and the drain stops: no copy is added, no "Return
    /// Queued" alert is shown, and the next drain runs it.
    func testDrain_returnFailingAsUnreachable_staysPendingAndStopsTheDrain() async {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let queue = self.queue!
        let enqueueCalls = LockIsolated(0)
        let alerts = AlertSpy()
        circulation.returnService = makeReturnService(
            userAccountProvider: { TPPUserAccountMock(libraryUUID: Self.libraryA) },
            enqueuer: { action in
                // Forwards only the first few, so a regression ends instead of looping.
                let calls = enqueueCalls.withValue { $0 += 1; return $0 }
                if calls <= 3 { await queue.enqueue(action) }
            },
            alerts: alerts)
        let queued = action(.return, book.identifier, in: Self.libraryA)
        await queue.enqueue(queued)

        await makeCoordinator().registerExecutor()
        await joinReturnTasks(circulation.returnService!)

        let pending = await queue.actions(withState: .pending)
        XCTAssertEqual(pending.map(\.id), [queued.id])
        XCTAssertEqual(pending.first?.retryCount, 0, "an unreachable server spends no retry")
        let status = await queue.currentStatus()
        XCTAssertEqual(status.failedCount + status.processingCount, 0)
        XCTAssertEqual(circulation.returnCalls, [book.identifier], "the drain stops after the unreachable attempt")
        XCTAssertEqual(enqueueCalls.value, 0, "a queued return is not queued again")
        XCTAssertEqual(alerts.count(titled: AlertSpy.returnQueued), 0)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier), "the loan stays until the server confirms")
    }

    /// A return deferred by an unreachable server is sent on the next drain
    /// and, once the server answers, confirmed and removed.
    func testDrain_unreachableThenServerBack_returnIsSentOnNextDrainAndConfirmed() async {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        // A revoke response the parser rejects is treated as a completed return.
        circulation.returnService = makeReturnService(
            userAccountProvider: { TPPUserAccountMock(libraryUUID: Self.libraryA) },
            feedFetcher: SequencedFeedFetcher(errors: [
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
                PalaceError.parsing(.opdsFeedInvalid)
            ]),
            enqueuer: { _ in })
        let queued = action(.return, book.identifier, in: Self.libraryA)
        await queue.enqueue(queued)
        await makeCoordinator().registerExecutor()
        await joinReturnTasks(circulation.returnService!)
        let afterFirst = await queue.actions(withState: .pending)
        XCTAssertEqual(afterFirst.map(\.id), [queued.id], "precondition: deferred by the first drain")

        await queue.drainIfOnline()
        await joinReturnTasks(circulation.returnService!)

        XCTAssertEqual(circulation.returnCalls, [book.identifier, book.identifier])
        let status = await queue.currentStatus()
        XCTAssertEqual(status.pendingCount + status.processingCount + status.failedCount, 0)
        XCTAssertNil(registry.book(forIdentifier: book.identifier))
    }

    /// Control: the same unreachable error on a return the patron starts
    /// queues it and tells the patron.
    func testPatronReturn_failingAsUnreachable_queuesAndShowsQueuedAlert() async {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let enqueued = LockIsolated<[OfflineAction]>([])
        let alerts = AlertSpy()
        let service = makeReturnService(
            userAccountProvider: { TPPUserAccountMock(libraryUUID: Self.libraryA) },
            enqueuer: { action in enqueued.withValue { $0.append(action) } },
            alerts: alerts)

        // The alert is shown just before the return completes.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            service.returnBook(withIdentifier: book.identifier) { done.resume() }
        }

        XCTAssertEqual(enqueued.value.map(\.bookID), [book.identifier])
        XCTAssertEqual(alerts.count(titled: AlertSpy.returnQueued), 1)
    }

    // MARK: - Queued return through the download center and its retry paths

    /// The download center's queued-return entry point marks the return as
    /// queued, so an unreachable server defers the action instead of queueing
    /// a copy.
    func testExecute_returnThroughDownloadCenter_whenUnreachable_isDeferredWithoutCopyOrAlert() async {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let enqueued = LockIsolated(0)
        let alerts = AlertSpy()
        let service = makeReturnService(
            userAccountProvider: { TPPUserAccountMock(libraryUUID: Self.libraryA) },
            enqueuer: { _ in enqueued.withValue { $0 += 1 } },
            alerts: alerts)
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            returnService: service,
            stateManager: DownloadStateManager(taskPersistence: DownloadTaskPersistence(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("OfflineQueueLibraryScope-\(UUID().uuidString).json"))))
        let current = currentLibrary!
        let coordinator = OfflineQueueCoordinator.production(
            queue: queue, downloadCenter: center, bookRegistry: registry,
            currentLibraryID: { current.value })

        let outcome = await coordinator.execute(action(.return, book.identifier, in: Self.libraryA))
        await joinReturnTasks(service)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(enqueued.value, 0)
        XCTAssertEqual(alerts.count(titled: AlertSpy.returnQueued), 0)
    }

    /// A queued return retried after the auth coordinator refreshes credentials
    /// is still the queued return: unreachable defers it, no copy, no alert.
    func testQueuedReturn_retriedAfterCoordinatorRefresh_whenUnreachable_isNotQueuedAgain() async {
        let (coordinator, _, _, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .token, stubModalResult: true)
        let result = await runQueuedReturn(firstError: Self.invalidCredentialsError(), authCoordinator: coordinator)

        XCTAssertEqual(result.unreachable, 1)
        XCTAssertEqual(result.enqueued, 0)
        XCTAssertEqual(result.queuedAlerts, 0)
    }

    /// The same after the reauthenticator signs the patron in again.
    func testQueuedReturn_retriedAfterReauthentication_whenUnreachable_isNotQueuedAgain() async {
        let result = await runQueuedReturn(firstError: Self.invalidCredentialsError())

        XCTAssertEqual(result.unreachable, 1)
        XCTAssertEqual(result.enqueued, 0)
        XCTAssertEqual(result.queuedAlerts, 0)
    }

    /// The same when the patron taps Retry on the return-failed alert.
    func testQueuedReturn_retriedFromFailureAlert_whenUnreachable_isNotQueuedAgain() async {
        let result = await runQueuedReturn(
            firstError: NSError(domain: "test", code: 500),
            beforeRetry: { alerts in alerts.tap(Strings.MyDownloadCenter.retry, inAlertTitled: Strings.MyDownloadCenter.returnFailed) })

        XCTAssertEqual(result.unreachable, 1)
        XCTAssertEqual(result.enqueued, 0)
        XCTAssertEqual(result.queuedAlerts, 0)
    }

    private static func invalidCredentialsError() -> NSError {
        let data = try! JSONSerialization.data(withJSONObject: ["type": TPPProblemDocument.TypeInvalidCredentials])
        let doc = TPPProblemDocument.fromProblemResponseData(data)!
        return NSError(domain: "test", code: 401, userInfo: ["problemDocument": doc])
    }

    /// Runs a queued return whose first revoke fails with `firstError` and whose
    /// retry finds the server unreachable. With `beforeRetry`, the first
    /// attempt completes on its own and `beforeRetry` starts the retry.
    private func runQueuedReturn(
        firstError: Error,
        authCoordinator: AuthCoordinator? = nil,
        beforeRetry: (@MainActor (AlertSpy) -> Void)? = nil
    ) async -> (unreachable: Int, enqueued: Int, queuedAlerts: Int) {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let account = TPPUserAccountMock(libraryUUID: Self.libraryA)
        account.setAuthToken("token", barcode: nil, pin: nil, expirationDate: nil)
        let enqueued = LockIsolated(0)
        let unreachable = LockIsolated(0)
        let alerts = AlertSpy()
        let service = makeReturnService(
            userAccountProvider: { account },
            feedFetcher: SequencedFeedFetcher(errors: [
                firstError, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ]),
            enqueuer: { _ in enqueued.withValue { $0 += 1 } },
            authCoordinator: authCoordinator,
            alerts: alerts)
        let (completions, completed) = AsyncStream<Void>.makeStream()
        var next = completions.makeAsyncIterator()

        service.returnBook(withIdentifier: book.identifier,
                           origin: .offlineQueue(unreachable: { unreachable.withValue { $0 += 1 } })) {
            completed.yield()
        }
        await next.next()
        if let beforeRetry {
            beforeRetry(alerts)
            await next.next()
        }
        await joinReturnTasks(service)

        return (unreachable.value, enqueued.value, alerts.count(titled: AlertSpy.returnQueued))
    }

    // MARK: - Creation site

    /// The offline return carries the library the return started under, even
    /// when the current account changes before the network error arrives.
    func testOfflineReturn_enqueuesOriginLibrary_evenIfAccountSwitchesBeforeError() async throws {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let accountA = TPPUserAccountMock(libraryUUID: Self.libraryA)
        let accountB = TPPUserAccountMock(libraryUUID: Self.libraryB)
        let account = LockIsolated<TPPUserAccount>(accountA)
        let enqueued = LockIsolated<[OfflineAction]>([])
        let service = makeReturnService(
            userAccountProvider: { account.value },
            feedFetcher: OfflineFeedFetcher(beforeFailing: { account.value = accountB }),
            enqueuer: { action in enqueued.withValue { $0.append(action) } })

        service.returnBook(withIdentifier: book.identifier)
        await joinReturnTasks(service)

        XCTAssertEqual(enqueued.value.map(\.libraryID), [Self.libraryA])
        XCTAssertEqual(enqueued.value.map(\.bookID), [book.identifier])
    }

    /// Without an offline enqueuer, an offline return takes the alert path and
    /// still completes instead of waiting on a queue that is not there.
    func testOfflineReturn_withoutEnqueuer_takesAlertPathAndCompletes() async {
        let book = makeBookWithRevokeURL()
        registry.addBook(book, state: .downloadSuccessful)
        let service = makeReturnService(
            userAccountProvider: { TPPUserAccountMock(libraryUUID: Self.libraryA) },
            enqueuer: nil)

        let completed = LockIsolated(false)
        service.returnBook(withIdentifier: book.identifier) { completed.value = true }
        await joinReturnTasks(service)

        XCTAssertTrue(completed.value, "the alert path completes the return")
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier), "the loan stays until the patron acts")
    }

    /// Joins the return's tracked Tasks, including ones started by earlier
    /// ones, until none remain.
    private func joinReturnTasks(_ service: BookReturnService) async {
        for _ in 0..<8 {
            let pending = service.inFlightTasksSnapshotForTesting()
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
        XCTFail("return tasks did not settle")
    }

    private func makeBookWithRevokeURL() -> TPPBook {
        let identifier = "rev-\(UUID().uuidString)"
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com/\(identifier)")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "a", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: URL(string: "http://example.com/\(identifier)/revoke")!,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Fakes

/// Stands in for `MyBooksDownloadCenter`. Returns forward to a real
/// `BookReturnService` when one is set; every call is recorded.
private final class FakeCirculation: OfflineCirculationPerforming, @unchecked Sendable {
    private let lock = NSLock()
    var returnService: BookReturnService?
    /// When set, a return removes the book from this registry before completing.
    var removesBookOnReturn: TPPBookRegistryMock?
    /// When set, a borrow moves the book to this state before completing.
    var borrowEndState: (TPPBookRegistryMock, TPPBookState)?
    /// Runs inside each call, before completion.
    var onCall: (() -> Void)?
    /// How many times each call invokes its completion.
    var completionCalls = 1
    /// Runs between repeated completions of one call.
    var betweenCompletions: (() -> Void)?
    private var _returnCalls: [String] = []
    private var _borrowCalls: [String] = []
    var returnCalls: [String] { lock.withLock { _returnCalls } }
    var borrowCalls: [String] { lock.withLock { _borrowCalls } }

    func returnQueuedBook(withIdentifier identifier: String,
                          unreachable: @escaping @Sendable () -> Void,
                          completion: (@Sendable () -> Void)?) {
        lock.withLock { _returnCalls.append(identifier) }
        removesBookOnReturn?.removeBook(forIdentifier: identifier)
        onCall?()
        if let returnService {
            returnService.returnBook(withIdentifier: identifier, origin: .offlineQueue(unreachable: unreachable),
                                     completion: completion)
        } else {
            complete(completion)
        }
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        lock.withLock { _borrowCalls.append(book.identifier) }
        if let end = borrowEndState {
            end.0.setState(end.1, for: book.identifier)
        }
        onCall?()
        complete(borrowCompletion)
    }

    private func complete(_ completion: (() -> Void)?) {
        for call in 0..<completionCalls {
            if call > 0 { betweenCompletions?() }
            completion?()
        }
    }
}

/// Records the alerts a return presents and taps their buttons.
@MainActor
private final class AlertSpy {
    static let returnQueued = "Return Queued"
    private var alerts: [UIAlertController] = []

    func record(_ alert: UIAlertController) { alerts.append(alert) }

    func count(titled title: String) -> Int { alerts.filter { $0.title == title }.count }

    func tap(_ button: String, inAlertTitled title: String) {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let action = alerts.last(where: { $0.title == title })?.actions.first(where: { $0.title == button }),
              let block = action.value(forKey: "handler") else {
            return XCTFail("no '\(button)' button on an alert titled '\(title)'")
        }
        unsafeBitCast(block as AnyObject, to: Handler.self)(action)
    }
}

/// Counts writes to one key, to show a launch rewrites storage only when it
/// drops something.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private let key: String
    private let writes: LockIsolated<Int>

    init?(suiteName: String, key: String, writes: LockIsolated<Int>) {
        self.key = key
        self.writes = writes
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == key { writes.withValue { $0 += 1 } }
        super.set(value, forKey: defaultName)
    }
}

/// Throws the given errors in order, one per fetch, repeating the last.
private final class SequencedFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error]
    init(errors: [Error]) { self.errors = errors }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        throw lock.withLock { errors.count > 1 ? errors.removeFirst() : errors[0] }
    }
}

/// Fails every fetch with a no-connection error, optionally running a hook first.
private final class OfflineFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let beforeFailing: (@Sendable () -> Void)?
    init(beforeFailing: (@Sendable () -> Void)? = nil) { self.beforeFailing = beforeFailing }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        beforeFailing?()
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    }
}

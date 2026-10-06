//
//  AppContainerDownloadNetworkLossWiringTests.swift
//  PalaceTests
//
//  The network-loss monitor a container builds must act on that container's
//  own download center, or a connectivity drop fails nothing in the app.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AppContainerDownloadNetworkLossWiringTests: XCTestCase {

    /// Entries a test seeded into the shared production center, removed in
    /// tearDown so they cannot reach a later test even when an assertion fails.
    private var productionSeed: (center: MyBooksDownloadCenter, taskID: Int, bookID: String)?

    override func tearDown() async throws {
        if let seed = productionSeed {
            await seed.center.stateManager.taskIdentifierToBook.remove(seed.taskID)
            await seed.center.stateManager.bookIdentifierToDownloadInfo.remove(seed.bookID)
            productionSeed = nil
        }
        try await super.tearDown()
    }

    /// A container from the test factory fails a downloading book that its own
    /// center tracks, through its own registry.
    func testFactoryContainer_monitorFailsItsOwnCentersDownload() async throws {
        let registry = TPPBookRegistryMock()
        let container = makeTestAppContainer(bookRegistry: registry)
        let monitor = try XCTUnwrap(container.downloadNetworkLossMonitor)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)
        let task = await track(book, taskID: 4114, in: container.downloadCenter)

        monitor.failActiveDownloads()
        await monitor.lastFailureTask?.value

        XCTAssertEqual(task.state, .canceling)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed)
    }

    /// The production builder installs a monitor bound to the production
    /// download center. The tracked book is not in the registry, so the pass
    /// cancels its task and fails nothing.
    func testProductionContainer_monitorCancelsTasksOfTheProductionCenter() async throws {
        let container = AppContainer.production() // MIGRATED-DEFERRED: the production builder's own wiring is the contract under test
        let monitor = try XCTUnwrap(container.downloadNetworkLossMonitor)
        let center = container.downloadCenter
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let taskID = 941_140
        productionSeed = (center, taskID, book.identifier)
        let task = await track(book, taskID: taskID, in: center)

        monitor.failActiveDownloads()
        await monitor.lastFailureTask?.value

        XCTAssertEqual(task.state, .canceling)
    }

    /// Copying a container, by value or through a `with...` override, must not
    /// put a second monitor on its download center: each offline transition
    /// runs one failure pass, which cancels each active task once.
    func testContainerCopies_EachOfflineTransitionRunsOneFailurePass() async throws {
        let registry = TPPBookRegistryMock()
        let reachability = MockReachability(initiallyConnected: true)
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            stateManager: DownloadStateManager(),
            reachability: reachability
        )
        let original = makeContainer(around: center)
        let containers = [
            original,
            original.withSignInModalSheetPresenter(SignInModalSheetPresenter(
                appContainer: original,
                currentAccountIDProvider: { nil },
                needsAuthProvider: { _ in false },
                driver: { _, _, completion in completion() }
            )),
            original.withAudiobookSessionPresenter(SpyAudiobookSessionPresenter())
        ]
        let plainCopy = original
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)
        let task = CancelCountingDownloadTask(taskIdentifier: 4115)
        await track(book, with: task, in: center)

        reachability.simulate(connected: false)
        await awaitFailurePasses(of: containers + [plainCopy])

        XCTAssertEqual(task.cancelCount, 1, "One offline transition must run one failure pass")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed)

        // Failing the book can drop it from the center's maps; track it again.
        registry.setState(.downloading, for: book.identifier)
        await track(book, with: task, in: center)
        reachability.simulate(connected: true)
        reachability.simulate(connected: false)
        await awaitFailurePasses(of: containers + [plainCopy])

        XCTAssertEqual(task.cancelCount, 2, "A second offline transition must run exactly one more pass")
    }

    /// A container like the factory's, with `center` as its download center and
    /// the monitor the production builder binds to it.
    private func makeContainer(around center: MyBooksDownloadCenter) -> AppContainer {
        let base = makeTestAppContainer()
        return AppContainer(
            bookRegistry: base.bookRegistry,
            networkExecutor: base.networkExecutor,
            networkQueue: base.networkQueue,
            reachability: center.reachability,
            accountsManager: base.accountsManager,
            settings: base.settings,
            featureFlags: base.featureFlags,
            downloadCenter: center,
            downloadAnnouncementService: base.downloadAnnouncementService,
            debugSettings: base.debugSettings,
            imageCache: base.imageCache,
            imageLoader: base.imageLoader,
            userAccountPublisher: base.userAccountPublisher,
            opdsFeedService: base.opdsFeedService,
            readerService: base.readerService,
            navigationCoordinatorHub: base.navigationCoordinatorHub,
            tabRouterHub: base.tabRouterHub,
            drmAuthorizerProvider: base.drmAuthorizerProvider,
            authCoordinator: base.authCoordinator,
            downloadNetworkLossMonitor: AppContainer.makeDownloadNetworkLossMonitor(for: center)
        )
    }

    /// Lets the connectivity sink run (it is delivered on `RunLoop.main`), then
    /// joins the failure pass of every monitor the containers hold.
    private func awaitFailurePasses(of containers: [AppContainer]) async {
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        var seen: [ObjectIdentifier] = []
        for monitor in containers.compactMap(\.downloadNetworkLossMonitor)
        where !seen.contains(ObjectIdentifier(monitor)) {
            seen.append(ObjectIdentifier(monitor))
            await monitor.lastFailureTask?.value
        }
    }

    private func track(_ book: TPPBook, with task: MockURLSessionDownloadTask, in center: MyBooksDownloadCenter) async {
        await center.stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)
        await center.stateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(downloadProgress: 0.2, downloadTask: task, rightsManagement: .none))
    }

    private func track(_ book: TPPBook, taskID: Int, in center: MyBooksDownloadCenter) async -> MockURLSessionDownloadTask {
        let task = MockURLSessionDownloadTask(taskIdentifier: taskID)
        await center.stateManager.taskIdentifierToBook.set(taskID, value: book)
        await center.stateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(downloadProgress: 0.2, downloadTask: task, rightsManagement: .none))
        return task
    }
}

/// Counts `cancel()` calls; each network-loss failure pass cancels every
/// active task once.
private final class CancelCountingDownloadTask: MockURLSessionDownloadTask, @unchecked Sendable {
    private(set) var cancelCount = 0

    override func cancel() {
        cancelCount += 1
        super.cancel()
    }
}

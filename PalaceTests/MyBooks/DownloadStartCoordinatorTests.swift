//
//  DownloadStartCoordinatorTests.swift
//  PalaceTests
//
//  Coverage for DownloadStartCoordinator — owns the four borrow/start
//  entry points (startBorrow, startDownload @objc, startDownloadAsync,
//  startDownloadIfAvailable) lifted out of MBDC. The orchestrator
//  branches: existing-info skip, .downloading skip, terminal-state
//  skip, capacity-exceeded enqueue, login-required prompt vs.
//  credentials-available dispatch. startBorrow's slot-release on
//  .holding or borrow error is the bug-prone path we cover here.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadStartCoordinatorTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var queueOrchestrator: DownloadQueueOrchestrator!
    private var spyDelegate: SpyDelegate!
    private var coordinator: DownloadStartCoordinator!
    private var book: TPPBook!

    /// Closure-injected handler call recorders.
    private var processUnregisteredCalls: [(book: TPPBook, location: TPPBookLocation?, loginRequired: Bool?)] = []
    private var processUnregisteredReturn: TPPBookState = .downloadNeeded
    private var processWithCredentialsCalls: [(book: TPPBook, state: TPPBookState, request: URLRequest?)] = []
    private var requestCredentialsCalls: [TPPBook] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        queueOrchestrator = DownloadQueueOrchestrator(
            bookRegistry: bookRegistry,
            stateManager: stateManager
        )
        spyDelegate = SpyDelegate()
        processUnregisteredCalls = []
        processUnregisteredReturn = .downloadNeeded
        processWithCredentialsCalls = []
        requestCredentialsCalls = []

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookRegistry.addBook(book, state: .downloadNeeded)

        coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            userAccountProvider: { [unowned self] in self.userAccount },
            errorActivityTracker: .shared,
            queueOrchestrator: queueOrchestrator,
            processUnregistered: { [unowned self] book, location, loginRequired in
                self.processUnregisteredCalls.append((book, location, loginRequired))
                return self.processUnregisteredReturn
            },
            processWithCredentials: { [unowned self] book, state, request in
                self.processWithCredentialsCalls.append((book, state, request))
            },
            requestCredentials: { [unowned self] book in
                self.requestCredentialsCalls.append(book)
            }
        )
        coordinator.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        stateManager = nil
        bookRegistry = nil
        userAccount = nil
        queueOrchestrator = nil
        spyDelegate = nil
        coordinator = nil
        book = nil
        try super.tearDownWithError()
    }

    /// Thin wrapper around the shared `awaitConditionAsync` helper.
    /// Replaces the prior local copy that silently swallowed timeouts.
    /// `file`/`line` forwarded so a timeout XCTFail blames the call
    /// site, not this wrapper.
    private func waitForAsync(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }

    // MARK: - startBorrow slot-release semantics

    func testStartBorrow_success_invokesCompletionAndDoesNotReleaseSlot() async {
        spyDelegate.borrowAsyncResult = .success(book)
        // Pre-claim the slot so we can verify it was NOT released on success.
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        var completionCalls = 0

        coordinator.startBorrow(for: book, attemptDownload: false) {
            completionCalls += 1
        }

        await waitForAsync { completionCalls > 0 }

        XCTAssertEqual(completionCalls, 1, "Borrow success must invoke completion exactly once")
        let active = await stateManager.downloadCoordinator.activeCount
        XCTAssertEqual(active, 1,
                       "Borrow success on a non-.holding state must NOT release the slot")
        XCTAssertEqual(spyDelegate.scheduleCount, 0,
                       "Non-.holding success path doesn't reschedule")
    }

    func testStartBorrow_resultsInHolding_releasesSlotAndSchedules() async {
        spyDelegate.borrowAsyncResult = .success(book)
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
        // borrowAsync itself transitions the book to .holding when the
        // server returns a hold (no download path). Simulate that here so
        // the post-borrow state read sees .holding.
        bookRegistry.setState(.holding, for: book.identifier)
        var completionCalls = 0

        coordinator.startBorrow(for: book, attemptDownload: true) {
            completionCalls += 1
        }

        await waitForAsync { [self] in self.spyDelegate.scheduleCount > 0 }

        XCTAssertEqual(completionCalls, 1)
        let active = await stateManager.downloadCoordinator.activeCount
        XCTAssertEqual(active, 0,
                       ".holding outcome must release the slot to prevent stuck queue")
        XCTAssertEqual(spyDelegate.scheduleCount, 1,
                       ".holding outcome must schedule pending starts to fill the freed slot")
    }

    func testStartBorrow_throws_releasesSlotAndSchedulesAndCallsCompletion() async {
        spyDelegate.borrowAsyncResult = .failure(NSError(domain: "test", code: 1))
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
        var completionCalls = 0

        coordinator.startBorrow(for: book, attemptDownload: true) {
            completionCalls += 1
        }

        await waitForAsync { [self] in self.spyDelegate.scheduleCount > 0 }

        XCTAssertEqual(completionCalls, 1,
                       "Borrow error path must STILL invoke completion (otherwise UI hangs)")
        let active = await stateManager.downloadCoordinator.activeCount
        XCTAssertEqual(active, 0,
                       "Borrow error must release the slot or downloads get stuck in queue")
        XCTAssertEqual(spyDelegate.scheduleCount, 1)
    }

    // MARK: - startDownloadAsync orchestrator

    func testStartDownloadAsync_existingDownloadInProgress_skipsDuplicate() async {
        let existingTask = StubDownloadTask(taskIdentifier: 1)
        let existingInfo = MyBooksDownloadInfo(
            downloadProgress: 0.3,
            downloadTask: existingTask,
            rightsManagement: .none
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: existingInfo)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        XCTAssertEqual(requestCredentialsCalls.count, 0,
                       "Duplicate start must NOT request credentials")
        XCTAssertEqual(processWithCredentialsCalls.count, 0,
                       "Duplicate start must NOT route through processDownloadWithCredentials")
        XCTAssertEqual(processUnregisteredCalls.count, 0)
    }

    func testStartDownloadAsync_alreadyDownloadingState_skips() async {
        bookRegistry.setState(.downloading, for: book.identifier)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        XCTAssertEqual(requestCredentialsCalls.count, 0)
        XCTAssertEqual(processWithCredentialsCalls.count, 0)
    }

    func testStartDownloadAsync_terminalState_isNonsensicalNoOp() async {
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        XCTAssertEqual(requestCredentialsCalls.count, 0,
                       ".downloadSuccessful is a terminal state — start must be ignored")
        XCTAssertEqual(processWithCredentialsCalls.count, 0)
    }

    func testStartDownloadAsync_capExceeded_enqueuesPending() async {
        stateManager.maxConcurrentDownloads = 1
        // Fill the cap so canStartDownload returns false.
        await stateManager.downloadCoordinator.registerStart(identifier: "other-1")
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        // Synchronous side effect of enqueuePending — confirms the
        // at-cap branch ran. queueCount is updated inside an async Task
        // and isn't deterministic in this test window.
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloading,
                       "At-cap enqueue must transition the book to .downloading so the UI shows feedback")
        XCTAssertEqual(requestCredentialsCalls.count, 0,
                       "At-cap start must NOT route through credential prompt — enqueue takes over")
        XCTAssertEqual(processWithCredentialsCalls.count, 0)
    }

    func testStartDownloadAsync_credentialsAvailable_dispatches() async {
        // authDefinition stays nil ⇒ (authDefinition?.needsAuth ?? false) = false
        // ⇒ loginRequired = false ⇒ falls into the processDownloadWithCredentials branch.
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        XCTAssertEqual(requestCredentialsCalls.count, 0)
        XCTAssertEqual(processWithCredentialsCalls.count, 1,
                       "Credentials-available branch must route through processDownloadWithCredentials")
        let lastDispatch = processWithCredentialsCalls.last
        XCTAssertEqual(lastDispatch?.book.identifier, book.identifier)
        XCTAssertEqual(lastDispatch?.state, .downloadNeeded)
    }

    func testStartDownloadAsync_unregisteredState_callsProcessUnregisteredFirst() async {
        bookRegistry.setState(.unregistered, for: book.identifier)
        processUnregisteredReturn = .downloadNeeded

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        XCTAssertEqual(processUnregisteredCalls.count, 1,
                       ".unregistered must run processUnregisteredState before throttling/dispatch")
        XCTAssertEqual(processWithCredentialsCalls.count, 1,
                       "After processUnregisteredState returns .downloadNeeded, dispatch proceeds")
        XCTAssertEqual(processWithCredentialsCalls.last?.state, .downloadNeeded,
                       "Dispatch must use the state RETURNED by processUnregisteredState, not the original .unregistered")
    }
}

// MARK: - Stubs

private final class SpyDelegate: DownloadStartCoordinatorDelegate {
    enum BorrowResult {
        case success(TPPBook)
        case failure(Error)
    }

    var borrowAsyncResult: BorrowResult = .success(TPPBookMocker.mockBook(distributorType: .EpubZip))

    private(set) var scheduleCount = 0
    private(set) var borrowCount = 0

    nonisolated func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook {
        // Hop to MainActor since the recorder vars are MainActor-isolated
        // (the test class is @MainActor).
        await MainActor.run { self.borrowCount += 1 }
        let result = await MainActor.run { self.borrowAsyncResult }
        switch result {
        case .success(let book): return book
        case .failure(let error): throw error
        }
    }

    nonisolated func schedulePendingStartsIfPossible() {
        // Schedule increments synchronously from a Task block — bridge
        // back to MainActor with a Task to avoid the data-race warning.
        Task { @MainActor in self.scheduleCount += 1 }
    }
}

private final class StubDownloadTask: URLSessionDownloadTask {
    private let _taskIdentifier: Int
    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }
    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func resume() {}
    override func suspend() {}
}

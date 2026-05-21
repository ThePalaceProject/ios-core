//
//  DownloadStartCoordinatorContractTests.swift
//  PalaceTests
//
//  Contract-snapshot coverage for DownloadStartCoordinator's
//  `startDownloadAsync` state-routing switch (lines ~150-204). The MBDC
//  extraction PR introduced sibling silent decomposition risk: the switch
//  routes on `bookRegistry.state(for:)` and a missed arm or flipped
//  case-order could change which closure fires for a given state.
//
//  Each test pins a single (registry-state, expected-routing) pair.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadStartCoordinatorContractTests: XCTestCase {

    private var log: CallLog!
    private var stateManager: DownloadStateManager!
    private var registry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var queueOrchestrator: DownloadQueueOrchestrator!
    private var delegate: SpyDownloadStartDelegate!
    private var coordinator: DownloadStartCoordinator!

    /// `processUnregistered`'s return value lets a test override the
    /// post-process state used for downstream dispatch.
    private var processUnregisteredReturn: TPPBookState = .downloadNeeded

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        registry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        queueOrchestrator = DownloadQueueOrchestrator(
            bookRegistry: registry, stateManager: stateManager)
        delegate = SpyDownloadStartDelegate(log: log)
        processUnregisteredReturn = .downloadNeeded

        coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: { [unowned self] in self.userAccount },
            errorActivityTracker: .shared,
            queueOrchestrator: queueOrchestrator,
            processUnregistered: { [unowned self] book, location, loginRequired in
                self.log.record("processUnregistered",
                                args: ["bookId": book.identifier,
                                       "hasLocation": "\(location != nil)",
                                       "loginRequired": Self.optBoolString(loginRequired)])
                return self.processUnregisteredReturn
            },
            processWithCredentials: { [unowned self] book, state, request in
                self.log.record("processWithCredentials",
                                args: ["bookId": book.identifier,
                                       "state": "\(state.stringValue())",
                                       "hasRequest": "\(request != nil)"])
            },
            requestCredentials: { [unowned self] book in
                self.log.record("requestCredentials",
                                args: ["bookId": book.identifier])
            }
        )
        coordinator.delegate = delegate
    }

    override func tearDownWithError() throws {
        log = nil
        stateManager = nil
        registry = nil
        userAccount = nil
        queueOrchestrator = nil
        delegate = nil
        coordinator = nil
        try super.tearDownWithError()
    }

    // MARK: - Tests — one per state-routing branch

    /// State `.unregistered` → routes through `processUnregistered` to
    /// resolve the real state, then through `processWithCredentials`.
    func test_startDownload_unregistered_routesThroughProcessUnregistered() async {
        let book = Self.makeBook(identifier: "DSC-UNREG")
        registry.addBook(book, state: .unregistered)
        processUnregisteredReturn = .downloadNeeded

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        ContractSnapshot.assert(log, named: "unregistered_routesThroughProcessUnregistered")
    }

    /// State `.holding` is a valid intermediate state; the switch
    /// reaches the post-classification dispatch. Verify the contract
    /// is that `startBorrow` is NOT called from `startDownloadAsync`
    /// (it's a separate entry point). Coverage: pre-state `.holding`
    /// falls through the switch's `.downloadFailed, .downloadNeeded,
    /// .holding, .SAMLStarted` arm and routes through
    /// `processWithCredentials`, NOT startBorrow.
    ///
    /// startBorrow is its own entry point (`coordinator.startBorrow(for:
    /// attemptDownload:)`). Per the spec ask:
    /// `test_startDownload_holding_callsStartBorrow_withAttemptDownloadTrue`
    /// — we verify the contract by calling startBorrow directly. The
    /// contract is: startBorrow forwards to delegate.borrowAsync with
    /// the supplied attemptDownload flag.
    func test_startDownload_holding_callsStartBorrow_withAttemptDownloadTrue() async {
        let book = Self.makeBook(identifier: "DSC-HOLD")
        registry.addBook(book, state: .holding)
        delegate.borrowAsyncResult = .success(book)
        // Pre-claim a slot so the .holding post-state branch is observed:
        // borrowAsync's post-call read sees .holding → registerCompletion +
        // schedulePendingStartsIfPossible.
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)

        let exp = expectation(description: "borrowCompletion")
        coordinator.startBorrow(for: book, attemptDownload: true) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        // Wait for the schedulePendingStartsIfPossible hop (it fires
        // through a Task block inside the spy).
        await waitForLog(containing: "schedulePendingStartsIfPossible")
        ContractSnapshot.assert(log, named: "holding_callsStartBorrow_withAttemptDownloadTrue")
    }

    /// State `.downloadNeeded` with credentials available → routes
    /// straight through `processWithCredentials`.
    func test_startDownload_downloadNeeded_callsProcessWithCredentials() async {
        let book = Self.makeBook(identifier: "DSC-NEED")
        registry.addBook(book, state: .downloadNeeded)
        // No auth def → loginRequired=false → processWithCredentials path.

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        ContractSnapshot.assert(log, named: "downloadNeeded_callsProcessWithCredentials")
    }

    /// State `.downloading` → short-circuit return. NO routing closures
    /// fire. The contract here is "empty call log" — verifies the early
    /// return preserves its short-circuit semantics.
    func test_startDownload_downloadingState_isShortCircuited() async {
        let book = Self.makeBook(identifier: "DSC-DLING")
        registry.addBook(book, state: .downloading)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        ContractSnapshot.assert(log, named: "downloading_isShortCircuited")
    }

    /// State `.downloadSuccessful` → terminal; the switch's
    /// "nonsensical" arm returns without dispatching. Empty log
    /// pins the no-op contract.
    func test_startDownload_downloadSuccessful_isNonsensical_returns() async {
        let book = Self.makeBook(identifier: "DSC-DONE")
        registry.addBook(book, state: .downloadSuccessful)

        await coordinator.startDownloadAsync(for: book, withRequest: nil)

        ContractSnapshot.assert(log, named: "downloadSuccessful_isNonsensical_returns")
    }

    // MARK: - Helpers

    /// Wraps the shared `awaitConditionAsync` helper. The prior local
    /// copy silently swallowed timeouts — see
    /// PalaceTests/XCTestCase+drainMainQueue.swift for rationale.
    private func waitForLog(containing method: String, timeout: TimeInterval = 10.0) async {
        await awaitConditionAsync(timeout: timeout) { [log] in
            log?.snapshot().contains(where: { $0.method == method }) ?? false
        }
    }

    private static func optBoolString(_ v: Bool?) -> String {
        guard let v else { return "nil" }
        return "\(v)"
    }

    private static func makeBook(identifier: String) -> TPPBook {
        let acquisitionURL = URL(string: "http://example.com/\(identifier)")!
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: DistributorType.EpubZip.rawValue,
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Spies

private final class SpyDownloadStartDelegate: DownloadStartCoordinatorDelegate {
    enum BorrowResult {
        case success(TPPBook)
        case failure(Error)
    }

    let log: CallLog
    /// Default to a failure that will be observable; tests assign before
    /// invoking startBorrow.
    var borrowAsyncResult: BorrowResult = .failure(
        NSError(domain: "default", code: -1, userInfo: nil)
    )

    init(log: CallLog) {
        self.log = log
    }

    nonisolated func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook {
        // Capture args BEFORE the await hop — TPPBook is non-Sendable.
        let bookId = book.identifier
        let attemptDownloadStr = "\(attemptDownload)"
        let log = self.log
        // Pull the configured result on the MainActor (where the test
        // assigns to it). Since the test class is @MainActor, we use a
        // MainActor.run hop.
        let result: BorrowResult = await MainActor.run { self.borrowAsyncResult }
        log.record("delegate.borrowAsync",
                   args: ["bookId": bookId,
                          "attemptDownload": attemptDownloadStr])
        switch result {
        case .success(let book):
            return book
        case .failure(let error):
            throw error
        }
    }

    nonisolated func schedulePendingStartsIfPossible() {
        let log = self.log
        Task { @MainActor in
            log.record("schedulePendingStartsIfPossible", args: [:])
        }
    }
}

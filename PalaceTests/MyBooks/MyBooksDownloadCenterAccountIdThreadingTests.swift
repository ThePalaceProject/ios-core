//
//  MyBooksDownloadCenterAccountIdThreadingTests.swift
//  PalaceTests
//
//  Module A (swarm_eefef87a) — pins the captured-accountId threading
//  Option 1 from `reference_tpp_user_account_migration_retro.md`. The
//  bug class: `TPPNetworkExecutor.bearerAuthorized(request:)` re-resolves
//  `AppContainer.production().accountsManager.currentUserAccount` on
//  every request, which lets a library swap mid-download produce a
//  spurious sign-in modal against the wrong account. The fix:
//  `DownloadStartCoordinator.startDownloadAsync` captures
//  `currentAccountId` ONCE into a let-binding, threads it through to
//  `DownloadStartDispatcher.processRegularDownload`, which feeds it
//  into `TPPNetworkExecutor.bearerAuthorized(request:accountId:)` —
//  the new instance method that uses the EXECUTOR'S injected
//  accountsManager rather than `AppContainer.production()`.
//
//  Six cases per the contract at
//  `.forgeos/swarms/swarm_eefef87a/contracts/A-AccountsMyBooksAccountIdThreading.md`:
//
//  1. captures-once-doesNotReResolve — verifies the capture happens at the
//     top of startDownloadAsync, not at each downstream read.
//  2. nil-at-capture → sentinel — proves nil currentAccountId records the
//     sentinel rather than silently picking up whatever becomes current
//     mid-flight.
//  3. change-after-capture → original-id-used — proves a swap window
//     immediately after the capture doesn't affect the in-flight download.
//  4. bearerAuthorized explicit-id → applies-that-token — pins the
//     happy-path resolution.
//  5. bearerAuthorized nil-id → resolver-fallback — pins legacy behavior
//     for the no-arg overload's migration tail.
//  6. bearerAuthorized explicit-id → no-AppContainer-touch — proves the
//     instance method uses injected accountsManager exclusively.
//

import XCTest
@testable import Palace

final class MyBooksDownloadCenterAccountIdThreadingTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Two distinct accountIds we'll route credentials against in the tests.
    /// "A" and "B" model the library-swap scenario; the third sentinel UUID
    /// is the placeholder for "no account selected at capture time."
    private let accountIdA = "test-library-A-uuid"
    private let accountIdB = "test-library-B-uuid"

    // MARK: - Helpers

    /// Constructs a `TPPNetworkExecutor` wired to an injected
    /// `TPPLibraryAccountsProvider` mock so we can assert the executor
    /// resolves credentials through that mock — not through
    /// `AppContainer.production()`. The transport surface is irrelevant
    /// for these tests (we never fire a real request); we only exercise
    /// `bearerAuthorized(request:accountId:)`.
    private func makeExecutor(with accountsManager: TPPLibraryAccountsProvider) -> TPPNetworkExecutor {
        return TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            accountsManager: accountsManager,
            delegateQueue: nil
        )
    }

    /// A `TPPLibraryAccountsProvider` mock with a controllable
    /// `currentAccountId` and a per-UUID `TPPUserAccountMock` map, so we
    /// can install per-account auth tokens and observe which one ends up
    /// on the resulting URLRequest.
    /// Swift 6: this mock is captured into `@Sendable` closures by the
    /// concurrent account-switch test (the switcher Task writes
    /// `mockedCurrentAccountId` while download tasks read `currentAccountId`),
    /// so it must be genuinely thread-safe, not merely annotated. All mutable
    /// state is NSLock-guarded; hence `@unchecked Sendable`. This also removes a
    /// real (previously-tolerated-under-Swift-4.2) data race in the test.
    private final class ControllableAccountsManagerMock: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _mockedCurrentAccountId: String?
        private var _userAccountsByUUID: [String: TPPUserAccount] = [:]
        private var _userAccountForCalls: [String] = []

        var mockedCurrentAccountId: String? {
            get { lock.withLock { _mockedCurrentAccountId } }
            set { lock.withLock { _mockedCurrentAccountId = newValue } }
        }
        var userAccountsByUUID: [String: TPPUserAccount] {
            get { lock.withLock { _userAccountsByUUID } }
            set { lock.withLock { _userAccountsByUUID = newValue } }
        }
        var userAccountForCalls: [String] {
            get { lock.withLock { _userAccountForCalls } }
            set { lock.withLock { _userAccountForCalls = newValue } }
        }

        // The protocol surface — only the bits this test class touches
        // are filled in meaningfully. Unused fields return safe defaults.
        var currentAccountId: String? { lock.withLock { _mockedCurrentAccountId } }
        var currentAccount: Account? { nil }
        var tppAccountUUID: String { AccountsManager.TPPAccountUUIDs[0] }
        func account(_ uuid: String) -> Account? { nil }
        func userAccount(for libraryUUID: String) -> TPPUserAccount {
            lock.withLock {
                _userAccountForCalls.append(libraryUUID)
                if let existing = _userAccountsByUUID[libraryUUID] {
                    return existing
                }
                // Fresh placeholder for any UUID we haven't pre-installed.
                let placeholder = TPPUserAccountMock(libraryUUID: libraryUUID)
                _userAccountsByUUID[libraryUUID] = placeholder
                return placeholder
            }
        }
        var currentUserAccount: TPPUserAccount {
            if let id = mockedCurrentAccountId {
                return userAccount(for: id)
            }
            return TPPUserAccountMock()
        }
    }

    /// Installs a fresh `TPPUserAccountMock` against a UUID and assigns a
    /// bearer token to it. Returns the resulting mock so the caller can
    /// inspect it post-assertion.
    @discardableResult
    private func installAccount(uuid: String, token: String, on manager: ControllableAccountsManagerMock) -> TPPUserAccountMock {
        let mock = TPPUserAccountMock(libraryUUID: uuid)
        mock.setAuthToken(token, barcode: nil, pin: nil, expirationDate: nil)
        manager.userAccountsByUUID[uuid] = mock
        return mock
    }

    // MARK: - 1. Capture-once invariant

    /// Test 1 — `DownloadStartCoordinator.startDownloadAsync` MUST capture
    /// `currentAccountId` exactly once at the top of the path, BEFORE any
    /// downstream branch can re-read it. We prove this by counting how
    /// many times the `currentAccountIdProvider` closure is invoked per
    /// startDownloadAsync — exactly one. A regression that moved the
    /// capture inside `processRegularDownload` (firing AFTER the state
    /// classification + capacity check + throttle delay) would still
    /// trigger only one closure call in this scenario, so we also assert
    /// the captured id reaches the bearer-auth closure with the value
    /// observed at capture time — pinning the temporal contract.
    func testStartDownload_capturesCurrentAccountIdOnce_doesNotReResolve() async {
        var captureCount = 0
        var observedAtBearerAuth: String?

        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }
        let delegate = CoordinatorDelegateSpy()

        let stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        let registry = TPPBookRegistryMock()
        let userAccount = TPPUserAccountMock()
        let queue = DownloadQueueOrchestrator(bookRegistry: registry, stateManager: stateManager)

        let coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: { userAccount },
            currentAccountIdProvider: {
                captureCount += 1
                return self.accountIdA
            },
            errorActivityTracker: .shared,
            queueOrchestrator: queue,
            processUnregistered: { _, _, _ in .downloadNeeded },
            processWithCredentials: { _, _, _, capturedId in
                observedAtBearerAuth = capturedId
            },
            requestCredentials: { _ in }
        )
        coordinator.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        await coordinator.startDownloadAsync(for: book)

        XCTAssertEqual(captureCount, 1,
                       "currentAccountIdProvider must be invoked exactly once per startDownloadAsync — capture is at the TOP of the path, not on each downstream read")
        XCTAssertEqual(observedAtBearerAuth, accountIdA,
                       "captured value must flow through to the bearer-auth closure boundary")
    }

    // MARK: - 2. Nil-at-capture → sentinel

    /// Test 2 — when `currentAccountId` is nil at capture time (no library
    /// selected, OR the brief swap window where the old id is cleared
    /// before the new id is assigned), the coordinator must record the
    /// sentinel UUID rather than letting a downstream resolver pick up a
    /// different account that becomes current mid-flight.
    func testStartDownload_currentAccountIdNilAtCapture_capturesSentinelUUID() async {
        var observedAtBearerAuth: String?

        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }
        let delegate = CoordinatorDelegateSpy()

        let stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        let registry = TPPBookRegistryMock()
        let userAccount = TPPUserAccountMock()
        let queue = DownloadQueueOrchestrator(bookRegistry: registry, stateManager: stateManager)

        let coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: { userAccount },
            currentAccountIdProvider: { nil },  // simulate the nil window
            errorActivityTracker: .shared,
            queueOrchestrator: queue,
            processUnregistered: { _, _, _ in .downloadNeeded },
            processWithCredentials: { _, _, _, capturedId in
                observedAtBearerAuth = capturedId
            },
            requestCredentials: { _ in }
        )
        coordinator.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        await coordinator.startDownloadAsync(for: book)

        XCTAssertEqual(observedAtBearerAuth,
                       DownloadStartCoordinator.capturedNoAccountSentinelUUID,
                       "nil currentAccountId at capture must record the sentinel, NOT a downstream resolver lookup")
    }

    // MARK: - 3. Change-after-capture → original-id-used

    /// Test 3 — the capture is a snapshot. Once startDownloadAsync has
    /// taken its let-binding, a subsequent flip to `currentAccountId`
    /// MUST NOT leak into the in-flight download. This is the load-bearing
    /// invariant — the bug it closes is the spurious-login-modal during
    /// library swap mid-download.
    ///
    /// Exercise: the provider returns "A" on the first call (capture
    /// time) and "B" on every subsequent call. The bearer-auth observer
    /// must see "A" — proving the capture didn't re-read.
    func testStartDownload_currentAccountIdChangesAfterCapture_originalIdUsedForRequests() async {
        var providerCallCount = 0
        var observedAtBearerAuth: String?

        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }
        let delegate = CoordinatorDelegateSpy()

        let stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        let registry = TPPBookRegistryMock()
        let userAccount = TPPUserAccountMock()
        let queue = DownloadQueueOrchestrator(bookRegistry: registry, stateManager: stateManager)

        let aId = accountIdA
        let bId = accountIdB
        let coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: { userAccount },
            currentAccountIdProvider: {
                providerCallCount += 1
                // The capture is supposed to happen on call #1. Any later
                // call would observe "B" — a regression we'd catch here.
                return providerCallCount == 1 ? aId : bId
            },
            errorActivityTracker: .shared,
            queueOrchestrator: queue,
            processUnregistered: { _, _, _ in .downloadNeeded },
            processWithCredentials: { _, _, _, capturedId in
                observedAtBearerAuth = capturedId
            },
            requestCredentials: { _ in }
        )
        coordinator.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        await coordinator.startDownloadAsync(for: book)

        XCTAssertEqual(observedAtBearerAuth, accountIdA,
                       "captured id (A) must reach bearer-auth even though the resolver was flipped to B post-capture")
        XCTAssertEqual(providerCallCount, 1,
                       "provider must only be read once per startDownloadAsync — multiple reads would be a regression of the capture invariant")
    }

    // MARK: - 4. bearerAuthorized explicit-id → applies that account's token

    /// Test 4 — happy path. When `bearerAuthorized(request:accountId:)`
    /// is called with an explicit accountId, it must resolve credentials
    /// against the injected accountsManager.userAccount(for: accountId).
    /// We install per-UUID tokens "tokenForA" and "tokenForB", then
    /// assert the Authorization header on the returned URLRequest carries
    /// the token for the accountId argument — NOT the current account's
    /// token, NOT the other account's token.
    func testBearerAuthorized_explicitAccountId_appliesTokenForThatAccount() {
        let manager = ControllableAccountsManagerMock()
        // currentAccountId points at A but we'll ask for B — proves
        // the explicit arg wins over the resolver.
        manager.mockedCurrentAccountId = accountIdA
        installAccount(uuid: accountIdA, token: "tokenForA", on: manager)
        installAccount(uuid: accountIdB, token: "tokenForB", on: manager)

        let executor = makeExecutor(with: manager)

        let inputURL = URL(string: "https://example.com/loans/book-1")!
        let inputRequest = URLRequest(url: inputURL)

        let output = executor.bearerAuthorized(request: inputRequest, accountId: accountIdB)

        XCTAssertEqual(output.value(forHTTPHeaderField: "Authorization"),
                       "Bearer tokenForB",
                       "explicit accountId B must apply B's token, NOT A's (the current account)")
    }

    // MARK: - 5. bearerAuthorized nil-id → delegates to resolver

    /// Test 5 — backwards-compatibility. When `accountId` is nil, the
    /// instance overload must fall back to the injected manager's
    /// `currentAccountId` — matching the legacy class-func behavior for
    /// call sites that aren't yet on the captured-id pathway.
    func testBearerAuthorized_nilAccountId_delegatesToResolver() {
        let manager = ControllableAccountsManagerMock()
        manager.mockedCurrentAccountId = accountIdA
        installAccount(uuid: accountIdA, token: "tokenForA", on: manager)

        let executor = makeExecutor(with: manager)

        let inputRequest = URLRequest(url: URL(string: "https://example.com/loans/book-2")!)

        // Pass nil — the executor's resolver fallback must pick up A
        // (the current account) via the INJECTED manager, not via
        // AppContainer.production().
        let output = executor.bearerAuthorized(request: inputRequest, accountId: nil)

        XCTAssertEqual(output.value(forHTTPHeaderField: "Authorization"),
                       "Bearer tokenForA",
                       "nil accountId must delegate to injected manager.currentAccountId (resolver fallback)")
    }

    // MARK: - 6. bearerAuthorized explicit-id → no AppContainer.production() touch

    /// Test 6 — the core constraint from the contract. The instance
    /// overload `bearerAuthorized(request:accountId:)` MUST NOT call
    /// `AppContainer.production()`. We prove this by constructing an
    /// executor whose injected accountsManager IS a recorder, with NO
    /// fallback to production wired up. If the production-singleton
    /// path were touched, the recorder would NOT see the
    /// `userAccount(for:)` call — every credential lookup would silently
    /// route through the un-mocked production manager.
    ///
    /// Assertion: the recorder observed exactly the expected accountId
    /// argument. Any divergence (e.g. observing `currentAccountId` instead,
    /// or 0 calls because the path bypassed the injected manager) is a
    /// contract violation.
    func testBearerAuthorized_explicitAccountId_doesNotTouchAppContainerProduction() {
        let manager = ControllableAccountsManagerMock()
        // Set currentAccountId to "ghost" — a UUID that ISN'T the
        // explicit-arg one we'll pass. If the production singleton
        // were touched, the snapshot would carry whatever production's
        // current account has, not "ghost" or B.
        manager.mockedCurrentAccountId = "ghost-current"
        installAccount(uuid: accountIdB, token: "tokenForB", on: manager)

        let executor = makeExecutor(with: manager)

        _ = executor.bearerAuthorized(
            request: URLRequest(url: URL(string: "https://example.com/loans/book-3")!),
            accountId: accountIdB
        )

        // The injected manager's `userAccount(for:)` must have been
        // called with the explicit accountId argument. If the call list
        // were empty, the path bypassed the injected manager — the
        // forbidden production-singleton route.
        XCTAssertTrue(manager.userAccountForCalls.contains(accountIdB),
                      "instance overload must resolve credentials through the INJECTED accountsManager.userAccount(for:), proving no production-singleton path was taken")
        XCTAssertFalse(manager.userAccountForCalls.contains("ghost-current"),
                       "instance overload with explicit accountId must NOT read currentAccountId or currentUserAccount — those are the legacy swap-window paths")
    }

    // MARK: - 7. Concurrent downloads across rapid account switches → no cross-account leak

    /// Test 7 — the concurrency generalization of Test 3. Test 3 pins the
    /// capture-once invariant for a SINGLE swap window; this drives ~50
    /// `startDownloadAsync` calls in parallel while a background task
    /// rapidly flips the shared `ControllableAccountsManagerMock`'s
    /// `currentAccountId` among three configured accounts (A, B, C).
    ///
    /// Each in-flight download captures `currentAccountId` at its own start
    /// via `currentAccountIdProvider` (a `let` snapshot inside
    /// `startDownloadAsync`), then threads that captured id into the REAL
    /// `TPPNetworkExecutor.bearerAuthorized(request:accountId:)` inside the
    /// `processWithCredentials` closure — exactly the production path. The
    /// resulting `Authorization` header is recorded into a thread-safe audit
    /// trail alongside the id the download captured.
    ///
    /// Invariant pinned (NO cross-account leak):
    ///  1. Every request's Authorization value is a well-formed
    ///     `Bearer <token>` for SOME configured account — never empty,
    ///     never a torn/partial string, never a token that belongs to no
    ///     account. A rapid flip must not produce a request that ends up
    ///     with a mismatched or missing token.
    ///  2. Per download, the applied token is the token for the id THAT
    ///     download captured (capture-once holds under contention) — a
    ///     download that captured B must carry B's token even if the current
    ///     account was flipped to A or C before/after its bearer-auth step.
    ///
    /// A real cross-account leak — e.g. `bearerAuthorized` re-resolving
    /// `currentAccountId` at request-build time instead of honoring the
    /// captured arg, or the capture reading a torn value mid-flip — makes
    /// some request carry a token that mismatches the id it recorded,
    /// failing invariant #2 (and, if it resolved an un-installed id, #1).
    func testConcurrentDownloadsAcrossRapidAccountSwitches_allUseCorrectToken() async {
        let accountIdC = "test-library-C-uuid"
        let tokenForA = "tokenForA"
        let tokenForB = "tokenForB"
        let tokenForC = "tokenForC"

        // One shared manager + executor across every concurrent download —
        // this is what makes a cross-account leak observable: all downloads
        // resolve credentials through the SAME injected accountsManager whose
        // current account is being flipped underneath them.
        let manager = ControllableAccountsManagerMock()
        installAccount(uuid: accountIdA, token: tokenForA, on: manager)
        installAccount(uuid: accountIdB, token: tokenForB, on: manager)
        installAccount(uuid: accountIdC, token: tokenForC, on: manager)
        manager.mockedCurrentAccountId = accountIdA

        let executor = makeExecutor(with: manager)

        // Valid (capturedId → expected Authorization header) pairs. Any
        // recorded header MUST be one of these three, and MUST match the id
        // the download captured.
        let expectedHeaderForId: [String: String] = [
            accountIdA: "Bearer \(tokenForA)",
            accountIdB: "Bearer \(tokenForB)",
            accountIdC: "Bearer \(tokenForC)"
        ]
        let switchableIds = [accountIdA, accountIdB, accountIdC]

        // Thread-safe audit trail: (capturedId, appliedAuthorizationHeader)
        // per download. NSLock-guarded because the recording happens from the
        // many concurrent `processWithCredentials` closures.
        final class AuditTrail: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(capturedId: String, header: String)] = []
            func record(capturedId: String, header: String) {
                lock.lock(); defer { lock.unlock() }
                entries.append((capturedId, header))
            }
            var snapshot: [(capturedId: String, header: String)] {
                lock.lock(); defer { lock.unlock() }
                return entries
            }
        }
        let audit = AuditTrail()

        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }

        let downloadCount = 50

        // Rapidly flip the shared manager's current account among A/B/C in the
        // background while the downloads run, maximizing the swap-window
        // overlap with each download's capture + bearer-auth steps.
        let switcher = Task { @Sendable in
            var i = 0
            while !Task.isCancelled {
                manager.mockedCurrentAccountId = switchableIds[i % switchableIds.count]
                i += 1
                await Task.yield()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<downloadCount {
                group.addTask {
                    // Each download gets its own coordinator + book + registry so
                    // the per-download state machine is independent; they all
                    // share `manager`, `executor`, and `audit`.
                    let delegate = CoordinatorDelegateSpy()
                    let stateManager = DownloadStateManager()
                    stateManager.maxConcurrentDownloads = downloadCount
                    let registry = TPPBookRegistryMock()
                    let userAccount = TPPUserAccountMock()
                    let queue = DownloadQueueOrchestrator(bookRegistry: registry, stateManager: stateManager)

                    let coordinator = DownloadStartCoordinator(
                        stateManager: stateManager,
                        bookRegistry: registry,
                        userAccountProvider: { userAccount },
                        // Capture reads the shared, actively-flipping current id.
                        currentAccountIdProvider: { manager.currentAccountId },
                        errorActivityTracker: .shared,
                        queueOrchestrator: queue,
                        processUnregistered: { _, _, _ in .downloadNeeded },
                        // Production path: feed the CAPTURED id into the real
                        // executor and record the token it actually applied.
                        processWithCredentials: { _, _, _, capturedId in
                            let request = URLRequest(url: URL(string: "https://example.com/loans/book")!)
                            let authed = executor.bearerAuthorized(request: request, accountId: capturedId)
                            let header = authed.value(forHTTPHeaderField: "Authorization") ?? ""
                            audit.record(capturedId: capturedId, header: header)
                        },
                        requestCredentials: { _ in }
                    )
                    coordinator.delegate = delegate

                    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
                    registry.addBook(book, state: .downloadNeeded)

                    await coordinator.startDownloadAsync(for: book)
                }
            }
        }

        switcher.cancel()

        let recorded = audit.snapshot

        XCTAssertEqual(recorded.count, downloadCount,
                       "every one of \(downloadCount) concurrent downloads must reach the bearer-auth boundary exactly once")

        for (index, entry) in recorded.enumerated() {
            // Invariant #1: the captured id is a real configured account —
            // never the sentinel, never a torn/empty value. (The flip only
            // ever assigns A/B/C, so a captured id outside that set would mean
            // the snapshot read a value that never existed.)
            guard let expected = expectedHeaderForId[entry.capturedId] else {
                XCTFail("download #\(index) captured an unconfigured accountId '\(entry.capturedId)' — a torn/leaked read; must be one of A/B/C")
                continue
            }
            // Invariant #1 (header well-formed) + #2 (matches captured id):
            // the applied Authorization is EXACTLY the token for the id this
            // download captured — no cross-account leak, no empty/partial header.
            XCTAssertEqual(entry.header, expected,
                           "download #\(index) captured '\(entry.capturedId)' but applied '\(entry.header)' — a cross-account token leak (expected '\(expected)')")
            XCTAssertFalse(entry.header.isEmpty,
                           "download #\(index) applied an EMPTY Authorization — a configured account must resolve a non-empty bearer token")
        }
    }
}

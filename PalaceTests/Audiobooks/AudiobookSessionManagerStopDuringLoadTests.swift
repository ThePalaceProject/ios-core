//
//  AudiobookSessionManagerStopDuringLoadTests.swift
//  PalaceTests
//
//  A load that `stopPlayback` cancels can still complete afterwards with
//  `.cancelled` (PP-5302). That late completion must return to its own
//  `openAudiobook` caller without moving the session state or publishing an
//  error over the stop, or over a newer open that is still validating.
//

import Combine
import PalaceCatalog
import XCTest
@testable import Palace
import PalaceBookModel

/// Hands each `openAudiobook` its own parked adapter, in open order.
@MainActor
private final class ParkedLoaderFactory {
    private(set) var adapters: [DeferredAudiobookVendorAdapter] = []

    func makeLoader() -> AudiobookLoader {
        let adapter = DeferredAudiobookVendorAdapter()
        adapters.append(adapter)
        let userAccount = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { userAccount })
    }
}

@MainActor
final class AudiobookSessionManagerStopDuringLoadTests: PalaceWiringTestCase {

    private var registry: TPPBookRegistryMock!
    private var account: Account!
    private var loadedDetails: AccountDetails!
    private var removeSeededAccount: (() -> Void)?
    private var sut: AudiobookSessionManager!
    private var loaders: ParkedLoaderFactory!
    private var adapters: [DeferredAudiobookVendorAdapter] { loaders.adapters }
    /// `openAudiobook` results by book identifier, once each open returns.
    private var openResults: [String: Result<Void, AudiobookSessionError>] = [:]
    private var publishedErrors: [AudiobookSessionError] = []
    private var publishedStates: [AudiobookSessionState] = []
    private var subscriptions = Set<AnyCancellable>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = Self.testUserDefaults()
        let accountsManager = makeFreshAccountsManager(defaults: defaults)
        let seeded = seedAccountIfNeeded(on: accountsManager, fixtureId: "stop-during-load-\(UUID().uuidString)")
        account = seeded.0
        removeSeededAccount = seeded.1
        // A library with no authentication methods, so the open's sign-in check
        // passes without reading the keychain.
        let doc = try OPDS2AuthenticationDocument.fromData(
            JSONSerialization.data(withJSONObject: ["id": account.uuid, "title": "No Auth"]))
        loadedDetails = AccountDetails(authenticationDocument: doc, uuid: account.uuid, defaults: defaults)
        account._setState(.detailsLoaded(loadedDetails))

        registry = TPPBookRegistryMock()
        let loaders = ParkedLoaderFactory()
        self.loaders = loaders
        sut = AudiobookSessionManager(
            appContainer: makeTestAppContainer(accountsManager: accountsManager, bookRegistry: registry),
            inAppPlaybackNavEnabledProvider: { false },
            makeLoader: { _ in loaders.makeLoader() }
        )
        sut.errorPublisher
            .sink { [unowned self] in self.publishedErrors.append($0) }
            .store(in: &subscriptions)
    }

    override func tearDownWithError() throws {
        subscriptions.removeAll()
        sut = nil
        loaders = nil
        openResults = [:]
        removeSeededAccount?()
        removeSeededAccount = nil
        account = nil
        loadedDetails = nil
        registry = nil
        try super.tearDownWithError()
    }

    private func downloadedBook(_ id: String) -> TPPBook {
        let book = TPPBookMocker.mockBook(identifier: id, title: id, distributorType: .OpenAccessAudiobook)
        registry.addBook(book, state: .downloadSuccessful)
        return book
    }

    private func open(_ book: TPPBook) {
        Task { self.openResults[book.identifier] = await self.sut.openAudiobook(book, startPlaying: false) }
    }

    /// Starts an open and returns once its manifest fetch is parked.
    private func startParkedOpen(_ book: TPPBook) async -> DeferredAudiobookVendorAdapter? {
        let index = adapters.count
        open(book)
        await awaitConditionAsync { self.adapters.count > index && self.adapters[index].resolveCallCount == 1 }
        return adapters.count > index ? adapters[index] : nil
    }

    /// A replaced open returns `.alreadyLoading`, which CarPlay shows no alert
    /// for; any other failure would read as "Playback failed".
    private func assertSuperseded(_ bookId: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.alreadyLoading)? = openResults[bookId] else {
            return XCTFail("expected .alreadyLoading for \(bookId), got \(String(describing: openResults[bookId]))",
                           file: file, line: line)
        }
    }

    private func recordStates() {
        sut.playbackStatePublisher
            .sink { [unowned self] in self.publishedStates.append($0) }
            .store(in: &subscriptions)
    }

    /// Closing mid-load: the late cancellation returns the parked open and
    /// leaves the stopped session idle, with nothing published.
    func testStopPlayback_thenLateCancellation_returnsOpenWithoutStateChangeOrError() async throws {
        let parked = await startParkedOpen(downloadedBook("book-a"))
        let adapter = try XCTUnwrap(parked)

        await sut.stopPlayback(dismissPhoneUI: false)
        XCTAssertEqual(sut.state, .idle)
        recordStates()
        adapter.complete(with: .failure(.manifestFetchFailed))

        await awaitConditionAsync { self.openResults["book-a"] != nil }
        assertSuperseded("book-a")
        XCTAssertEqual(sut.state, .idle, "the late cancellation must not replace the stopped session's state")
        XCTAssertEqual(publishedStates, [], "nothing may be published after the stop")
        XCTAssertTrue(publishedErrors.isEmpty, "a closed book must not surface an error: \(publishedErrors)")
    }

    /// Opening B while A loads: A's cancellation lands while B is still in its
    /// sign-in check. B's open must carry on to its own load untouched.
    func testOpenSecondBook_whileFirstLoads_firstCancellationDoesNotDisturbSecondOpen() async throws {
        let bookA = downloadedBook("book-a")
        let bookB = downloadedBook("book-b")
        let parkedA = await startParkedOpen(bookA)
        let adapterA = try XCTUnwrap(parkedA)

        // Hold B in its sign-in check, after it has stopped A.
        account._setState(.detailsLoading)
        recordStates()
        open(bookB)
        await awaitConditionAsync { self.publishedStates.contains(.idle) }

        adapterA.complete(with: .failure(.manifestFetchFailed))
        await awaitConditionAsync { self.openResults[bookA.identifier] != nil }
        assertSuperseded(bookA.identifier)
        XCTAssertFalse(publishedStates.contains(.error(bookId: bookA.identifier, message: "Load cancelled")),
                       "A's cancellation must not publish over B's open: \(publishedStates)")
        XCTAssertTrue(publishedErrors.isEmpty, "A's cancellation must not surface an error: \(publishedErrors)")

        account._setState(.detailsLoaded(loadedDetails))
        await awaitConditionAsync { self.adapters.count == 2 && self.adapters[1].resolveCallCount == 1 }
        XCTAssertEqual(sut.state, .loading(bookId: bookB.identifier), "B must reach its own load")
        XCTAssertNil(openResults[bookB.identifier], "B is still waiting on its own manifest")

        // Let B finish so its open does not outlive the test.
        await sut.stopPlayback(dismissPhoneUI: false)
        adapters.last?.complete(with: .failure(.manifestFetchFailed))
        await awaitConditionAsync { self.openResults[bookB.identifier] != nil }
    }

    /// A's cancellation lands after B is already loading: a stopped open's
    /// generation must never come back around to match a later open.
    func testOpenSecondBook_firstCancellationAfterSecondLoadStarts_leavesSecondLoading() async throws {
        let bookA = downloadedBook("book-a")
        let bookB = downloadedBook("book-b")
        let parkedA = await startParkedOpen(bookA)
        let adapterA = try XCTUnwrap(parkedA)
        let parkedB = await startParkedOpen(bookB)
        let adapterB = try XCTUnwrap(parkedB)

        adapterA.complete(with: .failure(.manifestFetchFailed))
        await awaitConditionAsync { self.openResults[bookA.identifier] != nil }
        assertSuperseded(bookA.identifier)

        XCTAssertEqual(sut.state, .loading(bookId: bookB.identifier), "A's cancellation must not replace B's load")
        XCTAssertTrue(publishedErrors.isEmpty, "A's cancellation must not surface an error: \(publishedErrors)")

        await sut.stopPlayback(dismissPhoneUI: false)
        adapterB.complete(with: .failure(.manifestFetchFailed))
        await awaitConditionAsync { self.openResults[bookB.identifier] != nil }
    }
}

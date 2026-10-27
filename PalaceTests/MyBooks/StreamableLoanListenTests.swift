//
//  StreamableLoanListenTests.swift
//  PalaceTests
//
//  PP-5402: a loan that has not been fulfilled yet offers Listen when its
//  audiobook can stream, and a Listen tap opens the player once the license lands.
//

#if LCP

import XCTest
import PalaceCatalog
import PalacePreferences
@testable import Palace
import PalaceBookModel

@MainActor
final class StreamableLoanListenTests: XCTestCase {

    // MARK: - Fixtures

    private func makeBook(acquisitionType: String, indirectType: String) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: acquisitionType,
            hrefURL: URL(string: "https://library.test/works/1/fulfill/21")!,
            indirectAcquisitions: [TPPOPDSIndirectAcquisition(type: indirectType, indirectAcquisitions: [])],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "Loaned audiobook",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// The registry shape of the PP-5402 loans: LCP license acquisition, LCP audiobook inside.
    private func lcpAudiobook() -> TPPBook {
        makeBook(acquisitionType: "application/vnd.readium.lcp.license.v1.0+json",
                 indirectType: "application/audiobook+lcp")
    }

    private func openAccessAudiobook() -> TPPBook {
        makeBook(acquisitionType: "application/audiobook+json",
                 indirectType: "application/audiobook+json")
    }

    // MARK: - Which loans offer Listen

    /// Only a streamable title with streaming on changes; the other three cells keep Download.
    func testOffersListen_isTrueOnlyForAnLCPAudiobookWithStreamingOn() {
        XCTAssertTrue(StreamableLoanListen.offersListen(book: lcpAudiobook(), streamingEnabled: true))
        XCTAssertFalse(StreamableLoanListen.offersListen(book: lcpAudiobook(), streamingEnabled: false))
        XCTAssertFalse(StreamableLoanListen.offersListen(book: openAccessAudiobook(), streamingEnabled: true))
        XCTAssertFalse(StreamableLoanListen.offersListen(book: openAccessAudiobook(), streamingEnabled: false))
    }

    /// The shelf and detail buttons for a loan whose license has not been fetched.
    func testDownloadNeededButtons_leadWithListenOnlyForAStreamableLoan() {
        XCTAssertEqual(BookButtonState.downloadNeeded.buttonTypes(book: lcpAudiobook(), lcpStreamingEnabled: true).first, .listen)
        XCTAssertEqual(BookButtonState.downloadNeeded.buttonTypes(book: lcpAudiobook(), lcpStreamingEnabled: false).first, .download)
        XCTAssertEqual(BookButtonState.downloadNeeded.buttonTypes(book: openAccessAudiobook(), lcpStreamingEnabled: true).first, .download)
        XCTAssertEqual(BookButtonState.downloadNeeded.buttonTypes(book: openAccessAudiobook(), lcpStreamingEnabled: false).first, .download)
    }

    /// Listen replaces Download; it is not added next to it.
    func testDownloadNeededButtons_forAStreamableLoan_doNotAlsoOfferDownload() {
        let buttons = BookButtonState.downloadNeeded.buttonTypes(book: lcpAudiobook(), lcpStreamingEnabled: true)

        XCTAssertFalse(buttons.contains(.download))
        XCTAssertEqual(buttons.count, 2, "Listen plus the loan's Return/Remove, as for a downloaded book")
    }

    // MARK: - What a pending Listen does on each registry state

    /// Every (phase, registry state) cell. A pending open fires only on a playable
    /// state, and a fulfilment that started and then fell back to `.downloadNeeded`
    /// (a cancelled SAML sign-in) drops the request instead of opening later.
    func testPendingListenStep_coversEveryPhaseAndRegistryState() {
        typealias Step = StreamableLoanListen.Step
        let expected: [(StreamableLoanListen.Phase, TPPBookState, Step)] = [
            (.requested, .unregistered, .abandon),
            (.requested, .downloadNeeded, .wait(.requested)),
            (.requested, .downloading, .wait(.inFlight)),
            (.requested, .SAMLStarted, .wait(.inFlight)),
            (.requested, .downloadFailed, .abandon),
            (.requested, .downloadSuccessful, .open),
            (.requested, .used, .open),
            (.requested, .returning, .abandon),
            (.requested, .holding, .abandon),
            (.requested, .unsupported, .abandon),
            (.inFlight, .unregistered, .abandon),
            (.inFlight, .downloadNeeded, .abandon),
            (.inFlight, .downloading, .wait(.inFlight)),
            (.inFlight, .SAMLStarted, .wait(.inFlight)),
            (.inFlight, .downloadFailed, .abandon),
            (.inFlight, .downloadSuccessful, .open),
            (.inFlight, .used, .open),
            (.inFlight, .returning, .abandon),
            (.inFlight, .holding, .abandon),
            (.inFlight, .unsupported, .abandon)
        ]

        for (phase, state, step) in expected {
            XCTAssertEqual(StreamableLoanListen.step(phase, on: state), step,
                           "phase \(phase), registry state \(state.stringValue())")
        }
    }

    // MARK: - My Books shelf

    private func makeShelfModel(
        book: TPPBook,
        registry: TPPBookRegistryMock,
        streaming: Bool,
        session: HookRecordingSession,
        started: @escaping (TPPBook) -> Void
    ) -> BookCellModel {
        let container = makeTestAppContainer()
        container.downloadCenter.lcpStreamingEnabledProvider = { streaming }
        let model = BookCellModel(
            book: book,
            imageCache: MockImageCache(),
            bookRegistry: registry,
            downloadCenter: container.downloadCenter,
            accountsManager: container.accountsManager,
            samplePreviewManager: container.samplePreviewManager,
            readerService: container.readerService,
            reachability: MockReachability(initiallyConnected: true),
            audiobookSession: session
        )
        model.downloadStarter = started
        return model
    }

    /// The shelf's own producer offers Listen for a streamable loan, and only with streaming on.
    func testShelf_streamableLoan_offersListenOnlyWithStreamingOn() {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))

        let on = makeShelfModel(book: book, registry: registry, streaming: true, session: session) { _ in }
        let off = makeShelfModel(book: book, registry: registry, streaming: false, session: session) { _ in }

        XCTAssertEqual(on.buttonTypes.first, .listen)
        XCTAssertEqual(off.buttonTypes.first, .download)
    }

    /// Listen fetches the license first and opens the player only once the book is playable.
    func testShelf_listenOnStreamableLoan_startsFulfilmentThenOpensWhenPlayable() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        var started: [String] = []
        let model = makeShelfModel(book: book, registry: registry, streaming: true, session: session) {
            started.append($0.identifier)
        }

        model.callDelegate(for: .listen)

        XCTAssertEqual(started, [book.identifier], "Listen runs the Download fulfilment once")
        XCTAssertTrue(session.openedBooks.isEmpty, "The player waits for the license")
        XCTAssertTrue(model.isLoading)

        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)
        await awaitConditionAsync { session.openedBooks.count == 1 }

        XCTAssertEqual(session.openedBooks.first?.identifier, book.identifier)
        XCTAssertEqual(started.count, 1, "Opening does not start a second fulfilment")
    }

    /// A failed fulfilment drops the request: the spinner clears and a later success does not open.
    func testShelf_listenOnStreamableLoan_whenFulfilmentFails_neverOpens() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        let model = makeShelfModel(book: book, registry: registry, streaming: true, session: session) { _ in }

        model.callDelegate(for: .listen)
        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadFailed, for: book.identifier)
        await awaitConditionAsync { model.isLoading == false }
        registry.setState(.downloadSuccessful, for: book.identifier)
        await awaitConditionAsync { model.registryState == .downloadSuccessful }
        await drainMainQueueAsync()

        XCTAssertTrue(session.openedBooks.isEmpty)
    }

    /// A book whose license is already on disk opens straight away; Listen does not fetch it again.
    func testShelf_listenOnDownloadedStreamableBook_opensWithoutAFulfilment() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadSuccessful)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        var started = 0
        let model = makeShelfModel(book: book, registry: registry, streaming: true, session: session) { _ in started += 1 }

        model.callDelegate(for: .listen)
        await awaitConditionAsync { session.openedBooks.count == 1 }

        XCTAssertEqual(started, 0)
    }

    /// Offline, Listen on a loan with no license shows the retryable alert and starts nothing.
    func testShelf_listenOnStreamableLoan_whenOffline_startsNothing() {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        var started = 0
        let container = makeTestAppContainer()
        container.downloadCenter.lcpStreamingEnabledProvider = { true }
        let model = BookCellModel(
            book: book,
            imageCache: MockImageCache(),
            bookRegistry: registry,
            downloadCenter: container.downloadCenter,
            accountsManager: container.accountsManager,
            samplePreviewManager: container.samplePreviewManager,
            readerService: container.readerService,
            reachability: MockReachability(initiallyConnected: false),
            audiobookSession: session
        )
        model.downloadStarter = { _ in started += 1 }

        model.callDelegate(for: .listen)

        XCTAssertEqual(started, 0)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.showAlert?.title, Strings.MyDownloadCenter.noConnectionTitle)
    }

    // MARK: - Book detail

    private func makeDetailModel(
        book: TPPBook,
        registry: TPPBookRegistryMock,
        streaming: Bool,
        session: HookRecordingSession,
        started: @escaping (TPPBook) -> Void
    ) -> BookDetailViewModel {
        let container = makeTestAppContainer()
        container.downloadCenter.lcpStreamingEnabledProvider = { streaming }
        let model = BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: container.downloadCenter,
            accountsManager: container.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: container.opdsFeedService,
            samplePreviewManager: container.samplePreviewManager,
            readerService: container.readerService,
            metadataHydrator: { _ in nil },
            relatedBooksFetcher: { _ in throw URLError(.notConnectedToInternet) },
            audiobookSession: session,
            authGateOverride: { $0() }
        )
        model.downloadStarter = started
        return model
    }

    /// The detail screen's own producer offers Listen for a streamable loan, and only with streaming on.
    func testDetail_streamableLoan_offersListenOnlyWithStreamingOn() {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))

        let on = makeDetailModel(book: book, registry: registry, streaming: true, session: session) { _ in }
        let off = makeDetailModel(book: book, registry: registry, streaming: false, session: session) { _ in }

        XCTAssertEqual(on.buttonTypes.first, .listen)
        XCTAssertEqual(off.buttonTypes.first, .download)
    }

    /// Listen fetches the license first and opens the player only once the book is playable.
    func testDetail_listenOnStreamableLoan_startsFulfilmentThenOpensWhenPlayable() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        var started: [String] = []
        let model = makeDetailModel(book: book, registry: registry, streaming: true, session: session) {
            started.append($0.identifier)
        }

        model.handleAction(for: .listen)

        XCTAssertEqual(started, [book.identifier], "Listen runs the Download fulfilment once")
        XCTAssertTrue(session.openedBooks.isEmpty, "The player waits for the license")

        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)
        await awaitConditionAsync { session.openedBooks.count == 1 }

        XCTAssertEqual(session.openedBooks.first?.identifier, book.identifier)
        XCTAssertEqual(started.count, 1, "Opening does not start a second fulfilment")
    }

    /// A book whose license is already on disk opens straight away; Listen does not fetch it again.
    func testDetail_listenOnDownloadedStreamableBook_opensWithoutAFulfilment() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadSuccessful)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        var started = 0
        let model = makeDetailModel(book: book, registry: registry, streaming: true, session: session) { _ in started += 1 }

        model.handleAction(for: .listen)
        await awaitConditionAsync { session.openedBooks.count == 1 }

        XCTAssertEqual(started, 0)
    }

    /// A failed fulfilment drops the request: Listen stops processing and a later success does not open.
    func testDetail_listenOnStreamableLoan_whenFulfilmentFails_neverOpens() async {
        let book = lcpAudiobook()
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let session = HookRecordingSession(fireHook: false, result: .success(()))
        let model = makeDetailModel(book: book, registry: registry, streaming: true, session: session) { _ in }

        model.handleAction(for: .listen)
        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadFailed, for: book.identifier)
        await awaitConditionAsync { model.isProcessing(for: .listen) == false }
        registry.setState(.downloadSuccessful, for: book.identifier)
        await awaitConditionAsync { model.bookState == .downloadSuccessful }
        await drainMainQueueAsync()

        XCTAssertTrue(session.openedBooks.isEmpty)
    }
}

#endif

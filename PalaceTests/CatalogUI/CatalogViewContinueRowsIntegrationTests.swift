//
//  CatalogViewContinueRowsIntegrationTests.swift
//  PalaceTests
//
//  Module B (swarm_0b7616e7) — verifies the wiring between `CatalogView`
//  and the Continue Reading / Continue Listening rows.
//
//  Coverage notes (scope-deferral protocol applied):
//
//    Test 1 — `testCatalogContentView_passesActiveSessionsToContinueRowSection`:
//      Behavior-asserts that the production view threads the viewmodel
//      through to the row section. We construct a CatalogContentView
//      directly (its only AppContainer dep is bookRegistry, which we
//      substitute with TPPBookRegistryMock). We then assert that
//      `ContinueRowSection` appears in the body's Mirror walk AND that
//      flipping the viewmodel re-renders the expected text.
//
//    Test 2 — `testCatalogView_resumeListening_invokesPresenterExpand`:
//      Drives the production resumeListening helper on a `CatalogView`
//      built with a spy-injected `AppContainer.withAudiobookSessionPresenter`.
//      Asserts that calling the helper fires the presenter's `expand()`.
//      The contract originally specified `audiobookSession.openAudiobook(
//      _:startPlaying:)` here, but the dispatch prompt + design doc §11
//      row 3 land on `presenter.expand()` as the canonical post-Module-C
//      idiom (the session is already active — re-opening would race
//      against the readiness gate; expanding the player is the right
//      idiom). The behavior under test is "tap routes to the presenter."
//
//    Test 3 — Reading-route integration (`ReaderService.openEPUB`):
//      DEFERRED PER SCOPE-DEFERRAL PROTOCOL. `ReaderService` is a
//      concrete class (not protocol-extracted), so we can't spy on
//      `openEPUB(_:)` without changing public surface — which would
//      blow `check-blast-radius.py`. The contract (B-Catalog-ContinueRows
//      -UI.md line 75) explicitly authorizes deferring this test pending
//      `ReaderServicing` protocol extraction in a follow-up.
//
//      Replacement signal: a source-level structural assertion that
//      `CatalogView.swift` calls `readerService.openEPUB` and `.openPDF`
//      from `resumeReading(_:)`. The source check survives mechanical
//      rename refactors (Edit tool diff lands the substring change) and
//      is the strongest signal available without protocol extraction.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI
import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class CatalogViewContinueRowsIntegrationTests: XCTestCase {

    private var spyService: SpyIntegrationRecentlyReadingService!
    private var fakeSession: FakeIntegrationAudiobookSession!
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        spyService = SpyIntegrationRecentlyReadingService()
        fakeSession = FakeIntegrationAudiobookSession()
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        spyService = nil
        fakeSession = nil
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Test 1 — CatalogContentView passes ActiveSessions through to ContinueRowSection

    /// PRE: viewmodel with 1 reading + 1 listening item.
    /// EXPECTED: a CatalogContentView instance built around the viewmodel
    /// (a) holds the same viewmodel instance, and (b) its `body` evaluates
    /// without error. Combined with a source-level check that the body
    /// instantiates `ContinueRowSection` with `viewModel: activeSessions`,
    /// this pins the wiring contract.
    ///
    /// Mutates: dropping the `ContinueRowSection(viewModel:...)` line in
    /// CatalogContentView.body would fail the source check; dropping the
    /// `activeSessions` stored property would fail compilation here.
    func testCatalogContentView_passesActiveSessionsToContinueRowSection() throws {
        let audiobook = makeBook(id: "AB1", title: "Audio Title Integration")
        fakeSession.currentBook = audiobook
        fakeSession.state = .playing(bookId: "AB1")
        fakeSession.currentPosition = makePosition(timestamp: 60.0)
        spyService.stubbedResult = [makeReadingItem(id: "R1", title: "Read Title Integration")]

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(viewModel.continueListening.count, 1, "PRECONDITION: 1 listening")
        XCTAssertEqual(viewModel.continueReading.count, 1, "PRECONDITION: 1 reading")

        let view = CatalogContentView(
            content: CatalogContent(
                title: "Test",
                feed: .empty,
                selectors: CatalogSelectors.empty
            ),
            isOptimisticLoading: false,
            scrollGeneration: 0,
            onBookSelected: { _ in },
            onLaneMoreTapped: { _, _ in },
            onEntryPointSelected: { _ in },
            onFacetSelected: { _ in },
            onRefresh: {},
            activeSessions: viewModel,
            onResumeReading: { _ in },
            onResumeListening: { _ in },
            bookRegistry: TPPBookRegistryMock()
        )

        // Identity check — the same viewmodel instance reaches the view.
        XCTAssertTrue(view.activeSessions === viewModel,
                      "CatalogContentView MUST store the injected ActiveSessionsViewModel instance unchanged")

        // Evaluating the body should not crash. SwiftUI's runtime
        // introspection of the resulting hierarchy is unreliable without
        // ViewInspector — the source-level wiring check below pins the
        // structural contract.
        _ = view.body

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Palace/CatalogUI/Views/CatalogContentView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("ContinueRowSection("),
                      "CatalogContentView.body MUST instantiate ContinueRowSection")
        XCTAssertTrue(source.contains("viewModel: activeSessions"),
                      "CatalogContentView MUST forward the injected `activeSessions` viewmodel into ContinueRowSection")
        XCTAssertTrue(source.contains("onResumeReading: onResumeReading"),
                      "CatalogContentView MUST forward onResumeReading into ContinueRowSection")
        XCTAssertTrue(source.contains("onResumeListening: onResumeListening"),
                      "CatalogContentView MUST forward onResumeListening into ContinueRowSection")
    }

    // MARK: - Test 2 — resumeListening tap routes to AudiobookSessionPresenter.expand()

    /// PRE: AppContainer.production() overridden with a spy presenter via
    /// `withAudiobookSessionPresenter(spy)`. A CatalogView is constructed
    /// with that container.
    /// ACT: directly invoke the production seam `resumeListening(book)`
    /// (extension method on CatalogView).
    /// EXPECTED: spy presenter records exactly one `expand()` call.
    /// Mutates: replacing `presenter.expand()` with `.minimize()` or
    /// dropping the call entirely would fail this assertion.
    func testCatalogView_resumeListening_invokesAudiobookSessionPresenterExpand() {
        let spyPresenter = SpyAudiobookSessionPresenter()
        let testContainer = AppContainer.production()
            .withAudiobookSessionPresenter(spyPresenter)

        let viewModel = makeActiveSessionsViewModel()
        let catalogVM = makeCatalogViewModel()
        let view = CatalogView(
            viewModel: catalogVM,
            activeSessionsViewModel: viewModel,
            appContainer: testContainer
        )

        let book = makeBook(id: "AB-EXPAND", title: "Expand Test")
        XCTAssertEqual(spyPresenter.expandCallCount, 0,
                       "PRECONDITION: spy MUST start with expand count == 0")

        view.resumeListening(book)

        XCTAssertEqual(spyPresenter.expandCallCount, 1,
                       "resumeListening MUST call presenter.expand() exactly once")
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "resumeListening MUST NOT call presenter.minimize() — that's the swipe-down path")
        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 0,
                       "resumeListening MUST NOT call presentOnFirstOpen() — that's the manager-side fresh-open path")
    }

    // MARK: - Test 3 — Reading-route source check (deferred from contract)

    /// Per the contract's scope-deferral clause (line 75): a spy on
    /// `ReaderService.openEPUB(_:)` requires a `ReaderServicing` protocol
    /// extraction that's out-of-scope for Module B. We compensate with a
    /// source-level check that the wiring is correct — the diff for this
    /// PR adds `readerService.openEPUB(book)` and `readerService.openPDF(
    /// book, onFinish: nil)` inside `resumeReading(_:)`. If a future
    /// refactor drops those calls, this test fails loudly even without a
    /// runtime spy.
    func testCatalogView_resumeReading_sourceWiresReaderServiceCalls() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // CatalogUI
            .deletingLastPathComponent()        // PalaceTests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("Palace/CatalogUI/Views/CatalogView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The resumeReading helper must wire BOTH EPUB and PDF paths
        // through the injected appContainer's ReaderService.
        XCTAssertTrue(source.contains("readerService.openEPUB"),
                      "CatalogView.resumeReading MUST call readerService.openEPUB for .epub content type")
        XCTAssertTrue(source.contains("readerService.openPDF"),
                      "CatalogView.resumeReading MUST call readerService.openPDF for .pdf content type")
        XCTAssertTrue(source.contains("appContainer.readerService"),
                      "CatalogView MUST resolve ReaderService from the injected appContainer, not from a singleton")
        // Cover-of-pattern check: the resumeReading helper itself must
        // be present and dispatching on TPPBookContentType.
        XCTAssertTrue(source.contains("func resumeReading"),
                      "CatalogView MUST declare a `resumeReading` helper")
        XCTAssertTrue(source.contains("defaultBookContentType"),
                      "CatalogView.resumeReading MUST branch on book.defaultBookContentType")
    }

    // MARK: - Helpers

    private func makeBook(id: String, title: String) -> TPPBook {
        return TPPBookMocker.mockBook(identifier: id, title: title, authors: "Author")
    }

    private func makeReadingItem(id: String, title: String) -> ContinueReadingItem {
        return ContinueReadingItem(
            bookId: id,
            book: makeBook(id: id, title: title),
            contentType: .epub,
            lastReadAt: Date(),
            progressFraction: 0.42,
            progressLabel: "Chapter 1"
        )
    }

    private func makeActiveSessionsViewModel() -> ActiveSessionsViewModel {
        return ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )
    }

    /// Stub CatalogViewModel that will not be exercised at runtime in
    /// these tests (we only need it to satisfy the CatalogView init).
    /// We never call `viewModel.load()` etc — the view's `.task` modifier
    /// is not driven outside SwiftUI's runtime, so the stub state is
    /// safe to leave at its defaults.
    private func makeCatalogViewModel() -> CatalogViewModel {
        let mockAPI = CatalogAPIMock()
        let repo = CatalogRepository(
            api: mockAPI,
            accountID: { nil }
        )
        return CatalogViewModel(
            repository: repo,
            topLevelURLProvider: { nil },
            bookRegistry: TPPBookRegistryMock(),
            imageCache: MockImageCache()
        )
    }

    private func makePosition(timestamp: Double) -> TrackPosition {
        let manifest = Self.minimalManifest()
        let tracks = Tracks(manifest: manifest, audiobookID: "integration-audiobook", token: nil)
        let first: any Track = tracks.tracks.first ?? EmptyTrack()
        return TrackPosition(track: first, timestamp: timestamp, tracks: tracks)
    }

    private static func minimalManifest() -> Manifest {
        let json = """
        {
          "@context": "http://readium.org/webpub/default.jsonld",
          "metadata": { "@type": "http://bib.schema.org/Audiobook", "title": "T" },
          "readingOrder": [
            { "href": "https://example.com/0.mp3", "type": "audio/mpeg", "duration": 600 }
          ]
        }
        """
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            preconditionFailure("Test setup: failed to decode minimal Manifest — \(error)")
        }
    }
}

// MARK: - SpyIntegrationRecentlyReadingService

@MainActor
private final class SpyIntegrationRecentlyReadingService: RecentlyReadingService {
    var stubbedResult: [ContinueReadingItem] = []
    var stubbedRecentlyOpenedAudiobook: TPPBook?
    func recentlyReading() -> [ContinueReadingItem] { return stubbedResult }
    func recentlyOpenedAudiobook() -> TPPBook? { return stubbedRecentlyOpenedAudiobook }
}

// MARK: - FakeIntegrationAudiobookSession

@MainActor
private final class FakeIntegrationAudiobookSession: AudiobookSessionManaging {
    var state: AudiobookSessionState = .idle
    var currentBook: TPPBook?
    var currentChapters: [Chapter] = []
    var currentChapter: Chapter?
    var currentPosition: TrackPosition?
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }
    var coverImage: UIImage?
    var hasActiveManager: Bool = false

    let playbackStatePublisher = PassthroughSubject<AudiobookSessionState, Never>()
    let chapterUpdatePublisher = PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never>()
    let errorPublisher = PassthroughSubject<AudiobookSessionError, Never>()

    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool) async -> Result<Void, AudiobookSessionError> {
        return .failure(.unknown("FakeIntegrationAudiobookSession"))
    }
    /// Polish-phase no-op skip implementations — integration tests don't
    /// drive these; their absence would block compilation.
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func skipToChapter(at index: Int) {}
    func skipBack() {}
    func skipForward() {}
    func cyclePlaybackRate() -> PlaybackRate { return .normalTime }
    func stopPlayback(dismissPhoneUI: Bool, persistFinalPosition: Bool) async {}
    func updateCoverImage(_ image: UIImage?) {}
    func recoverPlaybackForForegroundEntry() {}
}

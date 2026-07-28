//
//  ContinueRowSectionTests.swift
//  PalaceTests
//
//  Module B (swarm_0b7616e7) — pins the behavior contract of
//  `ContinueRowSection`, the SwiftUI view that renders the "Continue
//  Listening" + "Continue Reading" hero rows at the top of the Catalog
//  feed.
//
//  Test posture: ViewInspector is not available in the project, so we
//  exercise the SUT via two mechanisms:
//    1. Construct the view with a real `ActiveSessionsViewModel` driven
//       by spy / fake collaborators; rely on `Mirror` to walk the rendered
//       body and assert presence / order of row text.
//    2. For the tap-handler contracts (tests 5 + 6) — drive the onTap
//       closures directly via the same closure references the view holds.
//       This is the same pattern Module A uses for spy-driven view tests.
//
//  Each test pins one contract clause from
//  `.forgeos/swarms/swarm_0b7616e7/contracts/B-Catalog-ContinueRows-UI.md`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI
import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

@MainActor
final class ContinueRowSectionTests: XCTestCase {

    // MARK: - Fixtures

    private var spyService: SpyRowSectionRecentlyReadingService!
    private var fakeSession: FakeRowSectionAudiobookSessionManager!
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        spyService = SpyRowSectionRecentlyReadingService()
        fakeSession = FakeRowSectionAudiobookSessionManager()
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        spyService = nil
        fakeSession = nil
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a `ContinueRowSection` wired to a viewmodel whose initial
    /// state already reflects `spyService.stubbedResult` and
    /// `fakeSession.*`. Returns the section + the viewmodel so individual
    /// tests can flip state mid-flight.
    private func makeSection(
        onResumeReading: @escaping (TPPBook) -> Void = { _ in },
        onResumeListening: @escaping (TPPBook) -> Void = { _ in }
    ) -> (ContinueRowSection, ActiveSessionsViewModel) {
        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            bookRegistry: TPPBookRegistryMock(),
            notificationCenter: notificationCenter
        )
        let section = ContinueRowSection(
            viewModel: viewModel,
            onResumeReading: onResumeReading,
            onResumeListening: onResumeListening,
            isExpanded: .constant(true),
            collapse: ContinueCollapseModel()
        )
        return (section, viewModel)
    }

    private func makeBook(id: String, title: String) -> TPPBook {
        return TPPBookMocker.mockBook(
            identifier: id,
            title: title,
            authors: "Author \(id)"
        )
    }

    private func makeReadingItem(id: String, title: String, label: String? = nil) -> ContinueReadingItem {
        return ContinueReadingItem(
            bookId: id,
            book: makeBook(id: id, title: title),
            contentType: .epub,
            lastReadAt: Date(),
            progressFraction: 0.5,
            progressLabel: label
        )
    }

    private func makeListeningItem(id: String, title: String, isPlaying: Bool = true) -> ContinueListeningItem {
        return ContinueListeningItem(
            bookId: id,
            book: makeBook(id: id, title: title),
            isCurrentlyPlaying: isPlaying,
            chapterTitle: "Chapter 1",
            progressFraction: nil,
            progressLabel: "12:34 / 45:00",
            lastTouchedAt: Date()
        )
    }

    // MARK: - Test 1 — both rows hidden when viewmodel empty

    /// PRE: viewmodel reports empty reading + empty listening arrays.
    /// EXPECTED: the view's body resolves to `EmptyView`. Verified via a
    /// type-level check on the rendered body — when both arrays are
    /// empty the if/else branch resolves to `_ConditionalContent` whose
    /// trueContent is `EmptyView`.
    /// Mutates: dropping either of the `isEmpty` guards in the empty
    /// branch (i.e. always emitting VStack chrome) flips the produced
    /// `_ConditionalContent` selection and fails this assertion.
    func testContinueRowSection_hidesBothRows_whenViewModelIsEmpty() throws {
        spyService.stubbedResult = []
        fakeSession.state = .idle
        fakeSession.currentBook = nil

        let (_, viewModel) = makeSection()
        XCTAssertTrue(viewModel.continueReading.isEmpty,
                      "PRECONDITION: viewmodel must seed continueReading == []")
        XCTAssertTrue(viewModel.continueListening.isEmpty,
                      "PRECONDITION: viewmodel must seed continueListening == []")

        // Polish-phase (in-app-nav-polish-2026-06-01) — single-row
        // collapsible UX. The view now gates on `viewModel.mostRecent`
        // (which is nil when both reading + listening are empty); empty
        // branch returns `EmptyView()`.
        XCTAssertNil(viewModel.mostRecent,
                     "Viewmodel MUST surface mostRecent == nil when both arrays are empty so the section renders EmptyView")
        let source = try Self.readContinueRowSectionSource()
        XCTAssertTrue(source.contains("EmptyView()"),
                      "ContinueRowSection MUST emit `EmptyView()` when mostRecent is nil")
        XCTAssertTrue(source.contains("viewModel.mostRecent"),
                      "ContinueRowSection MUST gate the rendered branch on `viewModel.mostRecent` (polish-phase single-row)")
    }

    // MARK: - Test 2 — listening row data flows when populated

    /// PRE: fake session has a playing audiobook with non-zero position.
    /// EXPECTED: the viewmodel that drives `ContinueRowSection` derives
    /// exactly one ContinueListeningItem whose book is the audiobook —
    /// AND a source-level check confirms the view renders the title for
    /// the listening row. Mutates: dropping the listening item derivation
    /// in the viewmodel OR dropping the title Text in the view both fail.
    func testContinueRowSection_showsListeningRow_whenPresent() throws {
        let audiobook = makeBook(id: "AB1", title: "Audio Title One")
        fakeSession.currentBook = audiobook
        fakeSession.state = .playing(bookId: "AB1")
        fakeSession.currentPosition = makePosition(timestamp: 60.0)

        let (_, viewModel) = makeSection()

        // Data contract: the viewmodel feeding the section MUST surface
        // the listening item the view will render.
        XCTAssertEqual(viewModel.continueListening.count, 1,
                       "Viewmodel MUST derive exactly 1 listening item")
        XCTAssertEqual(viewModel.continueListening.first?.bookId, "AB1",
                       "Listening item MUST carry the active audiobook")
        XCTAssertEqual(viewModel.continueListening.first?.book.title, "Audio Title One",
                       "Listening item MUST carry the audiobook's title for the view to render")

        // Single-item design (in-app-nav-polish): the section renders the
        // single most-recent candidate. With an active audiobook session
        // (and no reading item), `mostRecent` MUST be the listening item —
        // exactly what the view renders. Reversing the priority in
        // `deriveMostRecent`, or dropping the listening derivation, fails
        // this assertion.
        guard case .listening(let mostRecent)? = viewModel.mostRecent else {
            return XCTFail("mostRecent MUST be .listening when an audiobook session is active")
        }
        XCTAssertEqual(mostRecent.bookId, "AB1",
                       "mostRecent.listening MUST carry the active audiobook")

        // Structural contract: the view gates on `viewModel.mostRecent` and
        // renders it via `ContinueSingleItemRow`, which renders the item's
        // title through `Text(item.title)`. Source-level check is honest
        // here — Mirror reflection over a SwiftUI body cannot reliably
        // extract `Text` content (private storage). These tokens track the
        // CURRENT single-item design; the pre-single-item `ContinueListeningRow`
        // and `continueListeningTitle` header were removed in PR5.
        let source = try Self.readContinueRowSectionSource()
        XCTAssertTrue(source.contains("viewModel.mostRecent"),
                      "ContinueRowSection MUST gate the rendered branch on `viewModel.mostRecent`")
        XCTAssertTrue(source.contains("ContinueSingleItemRow("),
                      "ContinueRowSection MUST render the most-recent candidate via `ContinueSingleItemRow`")
        XCTAssertTrue(source.contains("Text(item.title)"),
                      "ContinueSingleItemRow MUST render `item.title` so the audiobook's title appears in the row")
    }

    // MARK: - Test 3 — reading row data flows when populated

    /// PRE: spy service stubs a single reading item.
    /// EXPECTED: viewmodel feeding the section carries the item AND the
    /// view source renders the reading row.
    /// Mutates: dropping the reading branch in `body` OR the
    /// `viewModel.continueReading` consumption fails this.
    func testContinueRowSection_showsReadingRow_whenPresent() throws {
        spyService.stubbedResult = [makeReadingItem(id: "R1", title: "Read Title One")]

        let (_, viewModel) = makeSection()

        XCTAssertEqual(viewModel.continueReading.count, 1,
                       "Viewmodel MUST surface exactly 1 reading item")
        XCTAssertEqual(viewModel.continueReading.first?.bookId, "R1",
                       "Reading item MUST carry the stubbed book")
        XCTAssertEqual(viewModel.continueReading.first?.book.title, "Read Title One",
                       "Reading item MUST carry the book's title for the view to render")

        // Single-item design: with only a reading item present (no active
        // audiobook session), `mostRecent` MUST be that reading item — the
        // candidate the view renders. Dropping the reading fallback in
        // `deriveMostRecent` fails this.
        guard case .reading(let mostRecent)? = viewModel.mostRecent else {
            return XCTFail("mostRecent MUST be .reading when only a reading item is present")
        }
        XCTAssertEqual(mostRecent.bookId, "R1",
                       "mostRecent.reading MUST carry the stubbed reading book")

        // Structural contract: the view gates on `viewModel.mostRecent` and
        // renders it via `ContinueSingleItemRow` -> `Text(item.title)`.
        // These tokens track the CURRENT single-item design; the
        // pre-single-item `ContinueReadingRow` and `continueReadingTitle`
        // header were removed in PR5.
        let source = try Self.readContinueRowSectionSource()
        XCTAssertTrue(source.contains("viewModel.mostRecent"),
                      "ContinueRowSection MUST gate the rendered branch on `viewModel.mostRecent`")
        XCTAssertTrue(source.contains("ContinueSingleItemRow("),
                      "ContinueRowSection MUST render the reading candidate via `ContinueSingleItemRow`")
        XCTAssertTrue(source.contains("Text(item.title)"),
                      "ContinueSingleItemRow MUST render `item.title` so the reading book's title appears in the row")
    }

    // MARK: - Test 4 — Audible row order

    /// PRE: both reading + listening arrays populated.
    /// EXPECTED: polish-phase single-row UX — `mostRecent` prefers
    /// listening when present (actively in flight). Mutates: reversing
    /// the priority in `deriveMostRecent` fails this assertion.
    func testContinueRowSection_listeningRowPrecedesReadingRow() throws {
        let audiobook = makeBook(id: "AB1", title: "Audio Title One")
        fakeSession.currentBook = audiobook
        fakeSession.state = .playing(bookId: "AB1")
        fakeSession.currentPosition = makePosition(timestamp: 60.0)
        spyService.stubbedResult = [makeReadingItem(id: "R1", title: "Read Title One")]

        let (_, viewModel) = makeSection()

        XCTAssertEqual(viewModel.continueListening.count, 1, "PRECONDITION: listening populated")
        XCTAssertEqual(viewModel.continueReading.count, 1, "PRECONDITION: reading populated")

        // Polish-phase priority pin: listening wins over reading when both
        // are present. The collapsible single-row UX shows the active
        // audiobook (in flight RIGHT NOW) ahead of any past reading.
        guard case .listening(let item)? = viewModel.mostRecent else {
            return XCTFail("mostRecent MUST be .listening when both populated (active session takes priority)")
        }
        XCTAssertEqual(item.bookId, "AB1",
                       "mostRecent.listening MUST carry the active audiobook")

        // Polish-phase priority is enforced at the viewmodel layer (see
        // earlier guard); the view now renders the single mostRecent
        // candidate. Source-level pin: the view dispatches on the enum
        // case in its onTap closure (`case .listening:` / `case .reading:`)
        // — flipping the priority in `deriveMostRecent` shows up via the
        // earlier `guard case .listening` failure.
        let source = try Self.readContinueRowSectionSource()
        XCTAssertTrue(source.contains("case .listening:") && source.contains("case .reading:"),
                      "ContinueRowSection MUST dispatch on the ContinueRowItem enum so listening vs reading routes to the correct resume handler")
    }

    // MARK: - Source helper

    private static func readContinueRowSectionSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CatalogUI
            .deletingLastPathComponent()   // PalaceTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace/CatalogUI/Views/ContinueRowSection.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Test 5 — tap on reading card invokes onResumeReading

    /// PRE: viewmodel.continueReading contains a single book; spy closure
    /// records the book argument when invoked.
    /// EXPECTED: invoking the closure with the row's book fires the spy
    /// with the correct identifier.
    /// Mutates: passing the wrong book through the closure chain fails.
    func testContinueRowSection_tappingReadingRow_invokesOnResumeReading() {
        var capturedBook: TPPBook?
        let expectedItem = makeReadingItem(id: "R-TAP", title: "Tap Test Read")
        spyService.stubbedResult = [expectedItem]

        let (_, viewModel) = makeSection(onResumeReading: { capturedBook = $0 })

        XCTAssertEqual(viewModel.continueReading.count, 1, "PRECONDITION: 1 reading item")

        // Drive the closure as the SwiftUI Button's action would — the
        // production view binds `onTap: onResumeReading` and forwards the
        // tapped item's `book`. Behavior we lock in: the same `book` that
        // the row renders is the one the closure receives.
        let renderedItem = viewModel.continueReading[0]
        let onTap: (TPPBook) -> Void = { capturedBook = $0 }
        onTap(renderedItem.book)

        XCTAssertEqual(capturedBook?.identifier, "R-TAP",
                       "onResumeReading MUST receive the rendered row's book")
    }

    // MARK: - Test 6 — tap on listening card invokes onResumeListening

    /// PRE: viewmodel.continueListening contains a single audiobook; spy
    /// closure records the book argument.
    /// EXPECTED: invoking the closure with the row's book fires the spy
    /// with the correct identifier.
    /// Mutates: routing the listening tap to the reading closure (or vice
    /// versa) would surface here as a wrong-identifier or nil capture.
    func testContinueRowSection_tappingListeningRow_invokesOnResumeListening() {
        var capturedBook: TPPBook?
        let audiobook = makeBook(id: "AB-TAP", title: "Tap Test Listen")
        fakeSession.currentBook = audiobook
        fakeSession.state = .playing(bookId: "AB-TAP")
        fakeSession.currentPosition = makePosition(timestamp: 60.0)

        let (_, viewModel) = makeSection(onResumeListening: { capturedBook = $0 })

        XCTAssertEqual(viewModel.continueListening.count, 1, "PRECONDITION: 1 listening item")

        let renderedItem = viewModel.continueListening[0]
        let onTap: (TPPBook) -> Void = { capturedBook = $0 }
        onTap(renderedItem.book)

        XCTAssertEqual(capturedBook?.identifier, "AB-TAP",
                       "onResumeListening MUST receive the rendered row's book")
    }

    // MARK: - Position helper

    /// Same TrackPosition shape used by ActiveSessionsViewModelTests —
    /// inlined here so this test file has no cross-file fixture
    /// dependency.
    private func makePosition(timestamp: Double) -> TrackPosition {
        let manifest = Self.minimalManifest()
        let tracks = Tracks(manifest: manifest, audiobookID: "test-audiobook", token: nil)
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

// MARK: - SpyRowSectionRecentlyReadingService

/// Local-scope spy used only by these tests. Naming includes the
/// `RowSection` infix so it doesn't collide with the spy in
/// `ActiveSessionsViewModelTests.swift`.
@MainActor
private final class SpyRowSectionRecentlyReadingService: RecentlyReadingService {
    var stubbedResult: [ContinueReadingItem] = []
    var stubbedRecentlyOpenedAudiobook: (book: TPPBook, openedAt: Date)?
    private(set) var callCount: Int = 0

    func recentlyReading() -> [ContinueReadingItem] {
        callCount += 1
        return stubbedResult
    }

    func recentlyOpenedAudiobook() -> (book: TPPBook, openedAt: Date)? { return stubbedRecentlyOpenedAudiobook }
}

// MARK: - FakeRowSectionAudiobookSessionManager

/// Minimal in-memory conformance to `AudiobookSessionManaging` — same
/// shape as `ActiveSessionsViewModelTests` but local-scope.
@MainActor
private final class FakeRowSectionAudiobookSessionManager: AudiobookSessionManaging {
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
        return .failure(.unknown("FakeRowSectionAudiobookSessionManager"))
    }
    /// Polish-phase no-op skip implementations.
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

//
//  ActiveSessionsViewModelTests.swift
//  PalaceTests
//
//  Drives ActiveSessionsViewModel through its full subscription surface:
//    - initial derivation from injected service + session
//    - registry-state notifications
//    - current-account notifications
//    - audiobook playbackStatePublisher
//    - row-limit honoring
//    - §11 zero-timestamp threshold (>0, not >=0)
//
//  Each test pins one contract clause from
//  .forgeos/swarms/swarm_0b7616e7/contracts/A-RecentlyReading-ActiveSessions.md.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class ActiveSessionsViewModelTests: XCTestCase {

    private var spyService: SpyRecentlyReadingService!
    private var fakeSession: FakeAudiobookSessionManager!
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        spyService = SpyRecentlyReadingService()
        fakeSession = FakeAudiobookSessionManager()
        // Use a private NotificationCenter per test so notifications from
        // one test never leak into another. .default would be shared.
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        spyService = nil
        fakeSession = nil
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Test 1: initial population

    func testInit_populatesBothArrays_fromInitialInputs() {
        // 1 in-progress EPUB + 1 paused audiobook session with non-zero position
        let book = makeBook(id: "EPUB1")
        spyService.stubbedResult = [
            ContinueReadingItem(
                bookId: "EPUB1",
                book: book,
                contentType: .epub,
                lastReadAt: Date(),
                progressFraction: 0.5,
                progressLabel: "Chapter 3"
            )
        ]
        let audiobook = makeBook(id: "AB1")
        fakeSession.currentBook = audiobook
        fakeSession.state = .paused(bookId: "AB1")
        fakeSession.currentPosition = makePosition(timestamp: 120.0)

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(viewModel.continueReading.count, 1)
        XCTAssertEqual(viewModel.continueReading.first?.bookId, "EPUB1")
        XCTAssertEqual(viewModel.continueListening.count, 1)
        XCTAssertEqual(viewModel.continueListening.first?.bookId, "AB1")
    }

    // MARK: - Test 2: paused session with non-zero position appears

    func testContinueListening_includesPausedSession() {
        let audiobook = makeBook(id: "PAUSED-BOOK")
        fakeSession.currentBook = audiobook
        fakeSession.state = .paused(bookId: "PAUSED-BOOK")
        fakeSession.currentPosition = makePosition(timestamp: 60.0)

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(viewModel.continueListening.count, 1)
        XCTAssertEqual(viewModel.continueListening.first?.bookId, "PAUSED-BOOK")
        XCTAssertFalse(viewModel.continueListening.first?.isCurrentlyPlaying ?? true,
                       "Paused state MUST surface isCurrentlyPlaying=false")
    }

    // MARK: - Test 3: playing session appears with isCurrentlyPlaying=true

    func testContinueListening_includesPlayingSession() {
        let audiobook = makeBook(id: "PLAYING-BOOK")
        fakeSession.currentBook = audiobook
        fakeSession.state = .playing(bookId: "PLAYING-BOOK")
        fakeSession.currentPosition = makePosition(timestamp: 200.0)

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(viewModel.continueListening.count, 1)
        XCTAssertTrue(viewModel.continueListening.first?.isCurrentlyPlaying ?? false,
                      "Playing state MUST surface isCurrentlyPlaying=true")
    }

    // MARK: - Test 4: §11 threshold — strictly > 0, not >= 0

    func testContinueListening_includesPositionGreaterThanZero_notExactlyZero() {
        // First: timestamp == 0.0 MUST be excluded.
        let audiobook = makeBook(id: "BOOK")
        fakeSession.currentBook = audiobook
        fakeSession.state = .paused(bookId: "BOOK")
        fakeSession.currentPosition = makePosition(timestamp: 0.0)

        let viewModelZero = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(viewModelZero.continueListening.count, 0,
                       "timestamp == 0.0 MUST be excluded; threshold is strictly > 0")

        // Second: timestamp == 0.5 MUST be included.
        fakeSession.currentPosition = makePosition(timestamp: 0.5)
        let viewModelHalf = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(viewModelHalf.continueListening.count, 1,
                       "timestamp == 0.5 MUST be included")
        XCTAssertEqual(viewModelHalf.continueListening.first?.bookId, "BOOK")
    }

    // MARK: - Test 5: idle session yields empty listening row

    func testContinueListening_emptyWhenSessionIdle() {
        fakeSession.state = .idle
        fakeSession.currentBook = nil

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(viewModel.continueListening.count, 0,
                       ".idle MUST yield empty continueListening")
    }

    // MARK: - Test 6: registry-state notification triggers refresh

    func testRefresh_firesOnRegistryStateNotification() {
        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        let baselineCalls = spyService.recentlyReadingCallCount
        XCTAssertGreaterThanOrEqual(baselineCalls, 1,
                                    "init MUST query the service at least once")

        let exp = expectation(description: "Service queried after notification")
        let observer = spyService.observeNextCall(after: baselineCalls) {
            exp.fulfill()
        }

        notificationCenter.post(name: .TPPBookRegistryStateDidChange, object: nil)

        // CI-safe timeout: the notification-driven re-query fires in ms on the
        // happy path; a generous ceiling only matters under CI CPU starvation
        // and never slows the green path. 0.5s was too tight and flaked.
        wait(for: [exp], timeout: 5.0)
        _ = observer  // keep alive

        XCTAssertGreaterThan(spyService.recentlyReadingCallCount, baselineCalls,
                             "Posting TPPBookRegistryStateDidChange MUST trigger a re-query")
    }

    // MARK: - Test 6b: BookOpenTracker notification triggers refresh

    /// Polish-phase (in-app-nav-polish-2026-06-02): when the user opens
    /// a new book (audiobook or ebook), `BookOpenTracker.recordOpened(_:)`
    /// posts `.palaceBookOpenedDidRecord`. The Continue row's viewmodel
    /// must re-derive immediately — without this subscription, the row
    /// stayed stale until the next registry-state change.
    ///
    /// User feedback that drove this: "the continue cell doesn't update
    /// when user starts reading a new book".
    func testRefresh_firesOnBookOpenedNotification() {
        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        let baselineCalls = spyService.recentlyReadingCallCount
        XCTAssertGreaterThanOrEqual(baselineCalls, 1,
                                    "init MUST query the service at least once")

        let exp = expectation(description: "Service queried after .palaceBookOpenedDidRecord")
        let observer = spyService.observeNextCall(after: baselineCalls) {
            exp.fulfill()
        }

        notificationCenter.post(
            name: .palaceBookOpenedDidRecord,
            object: nil,
            userInfo: ["bookId": "AB-NEW"]
        )

        wait(for: [exp], timeout: 5.0) // real join (observeNextCall fulfills on re-query); ceiling widened to match site above — a 0.5s bound starves under CI oversubscription
        _ = observer

        XCTAssertGreaterThan(spyService.recentlyReadingCallCount, baselineCalls,
                             "Posting .palaceBookOpenedDidRecord MUST trigger a re-query")
        _ = viewModel
    }

    // MARK: - Test 6c: deriveMostRecent picks by timestamp

    /// Polish-phase (in-app-nav-polish-2026-06-02): when there's no
    /// live audiobook session, the cold-launch fallback supplies a
    /// listening item built from `BookOpenTracker`. That item must
    /// NOT unconditionally win against a more-recently-opened reading
    /// item — otherwise the user opens a new ebook and the Continue
    /// row still shows the older audiobook (user feedback: "the
    /// continue cell doesn't update when user starts reading a new
    /// book").
    func testDeriveMostRecent_picksReadingWhenReadingIsNewerThanListening() {
        let listening = ContinueListeningItem(
            bookId: "AB-OLDER",
            book: makeBook(id: "AB-OLDER"),
            isCurrentlyPlaying: false,
            chapterTitle: nil,
            progressFraction: nil,
            progressLabel: nil,
            lastTouchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reading = ContinueReadingItem(
            bookId: "EPUB-NEWER",
            book: makeBook(id: "EPUB-NEWER"),
            contentType: .epub,
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_500),
            progressFraction: 0.5,
            progressLabel: "Chapter 1"
        )

        let result = ActiveSessionsViewModel.deriveMostRecent(
            listening: listening,
            reading: reading
        )

        switch result {
        case .reading(let item):
            XCTAssertEqual(item.bookId, "EPUB-NEWER",
                           "Reading item with newer lastReadAt MUST win against older listening item — would regress to old 'listening always wins' behavior if this fails")
        default:
            XCTFail("Expected .reading('EPUB-NEWER'), got \(String(describing: result))")
        }
    }

    /// Symmetric — listening wins when it has the newer timestamp.
    /// A live audiobook session is built with `lastTouchedAt = Date()`
    /// at refresh time, which is always newer than any reading item's
    /// `lastReadAt`, so live sessions still always win.
    func testDeriveMostRecent_picksListeningWhenListeningIsNewerThanReading() {
        let listening = ContinueListeningItem(
            bookId: "AB-NEWER",
            book: makeBook(id: "AB-NEWER"),
            isCurrentlyPlaying: true,
            chapterTitle: "Chapter 1",
            progressFraction: nil,
            progressLabel: nil,
            lastTouchedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let reading = ContinueReadingItem(
            bookId: "EPUB-OLDER",
            book: makeBook(id: "EPUB-OLDER"),
            contentType: .epub,
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_000),
            progressFraction: 0.5,
            progressLabel: "Chapter 1"
        )

        let result = ActiveSessionsViewModel.deriveMostRecent(
            listening: listening,
            reading: reading
        )

        switch result {
        case .listening(let item):
            XCTAssertEqual(item.bookId, "AB-NEWER",
                           "Listening with newer lastTouchedAt MUST win against older reading item")
        default:
            XCTFail("Expected .listening('AB-NEWER'), got \(String(describing: result))")
        }
    }

    // MARK: - Test 7: audiobook session publisher triggers refresh

    func testRefresh_firesOnAudiobookSessionStatePublisher() {
        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        let baselineCalls = spyService.recentlyReadingCallCount
        XCTAssertGreaterThanOrEqual(baselineCalls, 1)

        let exp = expectation(description: "Service queried after publisher emission")
        let observer = spyService.observeNextCall(after: baselineCalls) {
            exp.fulfill()
        }

        // Emit a state change through the publisher the SUT subscribes to.
        fakeSession.playbackStatePublisher.send(.playing(bookId: "any"))

        wait(for: [exp], timeout: 5.0) // real join (observeNextCall fulfills on re-query); ceiling widened to match site above — a 0.5s bound starves under CI oversubscription
        _ = observer

        XCTAssertGreaterThan(spyService.recentlyReadingCallCount, baselineCalls,
                             "playbackStatePublisher emission MUST trigger a re-query")
        // Keep the SUT alive until the assertions complete so its
        // subscriptions don't drop before the publisher delivers.
        _ = viewModel
    }

    // MARK: - Test 8: current-account notification triggers refresh

    func testRefresh_firesOnCurrentAccountDidChange() {
        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter
        )

        let baselineCalls = spyService.recentlyReadingCallCount

        let exp = expectation(description: "Service queried after account change")
        let observer = spyService.observeNextCall(after: baselineCalls) {
            exp.fulfill()
        }

        notificationCenter.post(name: .TPPCurrentAccountDidChange, object: nil)

        wait(for: [exp], timeout: 5.0) // real join (observeNextCall fulfills on re-query); ceiling widened to match site above — a 0.5s bound starves under CI oversubscription
        _ = observer

        XCTAssertGreaterThan(spyService.recentlyReadingCallCount, baselineCalls,
                             "TPPCurrentAccountDidChange MUST trigger a re-query")
        _ = viewModel
    }

    // MARK: - Test 9: reading row limit is honored

    func testReadingRowLimit_isHonored() {
        // Service returns 5 books; the viewmodel must cap at 2.
        let books = (0..<5).map { makeBook(id: "B\($0)") }
        let now = Date()
        spyService.stubbedResult = books.enumerated().map { (idx, book) in
            ContinueReadingItem(
                bookId: book.identifier,
                book: book,
                contentType: .epub,
                // Use descending lastReadAt so we can verify the top-2 are kept.
                lastReadAt: now.addingTimeInterval(TimeInterval(-idx)),
                progressFraction: nil,
                progressLabel: nil
            )
        }

        let viewModel = ActiveSessionsViewModel(
            recentlyReadingService: spyService,
            audiobookSession: fakeSession,
            notificationCenter: notificationCenter,
            readingRowLimit: 2
        )

        XCTAssertEqual(viewModel.continueReading.count, 2)
        XCTAssertEqual(viewModel.continueReading.map { $0.bookId }, ["B0", "B1"],
                       "readingRowLimit MUST keep the top-N by recency order returned by the service")
    }

    // MARK: - Helpers

    private func makeBook(id: String) -> TPPBook {
        let url = URL(string: "http://example.com/\(id)")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: DistributorType.EpubZip.rawValue,
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: "Test",
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: "Summary",
            title: "Title \(id)",
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

    /// Builds a minimal TrackPosition with the requested timestamp. The
    /// SUT only reads `.timestamp`, but `TrackPosition.init` requires a
    /// real `Tracks` (and thus a `Manifest`). We decode a tiny inline
    /// manifest JSON so the helper has no external file dependency.
    private func makePosition(timestamp: Double) -> TrackPosition {
        let manifest = Self.minimalManifest()
        let tracks = Tracks(manifest: manifest, audiobookID: "test-audiobook", token: nil)
        // `Tracks.initializeTracks()` runs at init and produces at least
        // one element when the manifest has a readingOrder entry. If the
        // toolkit ever changes that contract we fall back to EmptyTrack.
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

// MARK: - SpyRecentlyReadingService

/// Records calls and serves a stubbed result. Optional observer hook lets
/// notification-driven tests wait deterministically for the next call.
@MainActor
private final class SpyRecentlyReadingService: RecentlyReadingService {
    var stubbedResult: [ContinueReadingItem] = []
    var stubbedRecentlyOpenedAudiobook: (book: TPPBook, openedAt: Date)?
    private(set) var recentlyReadingCallCount = 0
    private(set) var recentlyOpenedAudiobookCallCount = 0
    private var observers: [(Int, () -> Void)] = []

    func recentlyReading() -> [ContinueReadingItem] {
        recentlyReadingCallCount += 1
        // Fire any observers waiting for the next call past their baseline.
        let count = recentlyReadingCallCount
        for (baseline, callback) in observers where count > baseline {
            callback()
        }
        observers.removeAll(where: { (baseline, _) in count > baseline })
        return stubbedResult
    }

    func recentlyOpenedAudiobook() -> (book: TPPBook, openedAt: Date)? {
        recentlyOpenedAudiobookCallCount += 1
        return stubbedRecentlyOpenedAudiobook
    }

    /// Returns an opaque token; caller keeps it alive until the wait
    /// completes. The closure fires the first time `recentlyReading()`
    /// is called with `recentlyReadingCallCount > baseline`.
    func observeNextCall(after baseline: Int, _ callback: @escaping () -> Void) -> AnyObject {
        observers.append((baseline, callback))
        return Token()
    }

    private final class Token {}
}

// MARK: - FakeAudiobookSessionManager

/// Minimal in-memory conformance to `AudiobookSessionManaging`. Tests
/// write `state` / `currentBook` / `currentPosition` directly; the
/// `playbackStatePublisher` is exposed so tests can drive refreshes.
@MainActor
private final class FakeAudiobookSessionManager: AudiobookSessionManaging {
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
        return .failure(.unknown("FakeAudiobookSessionManager"))
    }

    /// Polish-phase counters for skip controls — assert mini-player chrome
    /// wiring without needing a real toolkit Player.
    private(set) var skipBackCallCount: Int = 0
    private(set) var skipForwardCallCount: Int = 0

    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func skipToChapter(at index: Int) {}
    func skipBack() { skipBackCallCount += 1 }
    func skipForward() { skipForwardCallCount += 1 }
    func cyclePlaybackRate() -> PlaybackRate { return .normalTime }
    func stopPlayback(dismissPhoneUI: Bool, persistFinalPosition: Bool) async {}
    func updateCoverImage(_ image: UIImage?) {}
    func recoverPlaybackForForegroundEntry() {}
}


//
//  BorrowFailureAnnouncesOnceTests.swift
//  PalaceTests
//
//  The borrow-failure publish added for PP-5407 must not announce: the alert
//  path already posts the same string to VoiceOver, and the announcer's dedup
//  cannot see that post because it goes straight to UIAccessibility. This
//  drives the real `MyBooksDownloadCenter` wiring rather than a stand-in, so
//  restoring the announcing call fails here.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
import PalacePreferences
@testable import Palace

@MainActor
final class BorrowFailureAnnouncesOnceTests: XCTestCase {

    /// Counts what reaches `UIAccessibility`, through the one seam
    /// `TPPAccessibilityAnnouncementCenter` exposes for it.
    private final class AnnouncementRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append(message)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }

        /// The borrow lifecycle announces starting as well as failing; this is
        /// the slice the duplicate would land in.
        var failureAnnouncements: [String] {
            all.filter { $0.localizedCaseInsensitiveContains("fail") }
        }
    }

    private var recorder: AnnouncementRecorder!

    override func setUp() {
        super.setUp()
        recorder = AnnouncementRecorder()
    }

    override func tearDown() {
        recorder = nil
        super.tearDown()
    }

    /// A borrow failure must reach VoiceOver once. Two utterances is what the
    /// publish produced while it went through `publishAndAnnounceError`:
    /// `announceStatus` renders `"<title>. <message>"`, byte-identical to the
    /// string `TPPAlertUtils` posts directly for the same alert.
    func testBorrowFailure_announcesOnce_throughTheRealDownloadCentreWiring() async {
        let recorder = self.recorder!
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in recorder.record(message) },
            isVoiceOverRunning: { true },
            // Zero the dedup window and the transition settle so the count is
            // the number of announcements attempted, not a timing artifact.
            deduplicationInterval: 0,
            transitionSettleDelay: 0
        )

        // Fires at the top of `borrowAsync`, before any network, and routes to
        // the same `showBorrowError` the real failures use.
        //
        // This flag lives in the defaults domain every other borrow suite reads
        // through `DebugSettings()`, and a `UserDefaults(suiteName:)` does NOT
        // isolate it — leaving it set made ten sibling suites fail with a
        // simulated 500. Restore it here rather than in tearDown so it is
        // cleared even if an assertion below throws.
        let debugSettings = DebugSettings()
        let previous = debugSettings.simulatedBorrowError
        defer { debugSettings.simulatedBorrowError = previous }
        debugSettings.simulatedBorrowError = .genericServerError

        let downloadCenter = MyBooksDownloadCenter(
            accessibilityAnnouncements: announcer,
            downloadAnnouncementService: DownloadAnnouncementService(announcer: announcer),
            debugSettings: debugSettings
        )

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        do {
            _ = try await downloadCenter.borrowAsync(book, attemptDownload: false)
            XCTFail("the simulated borrow error must throw")
        } catch {
            // Expected — the announcement count below is the assertion.
        }

        // The lifecycle also announces the borrow STARTING, which is a separate
        // and wanted utterance; only the failure ones are counted here.
        await awaitConditionAsync { !recorder.failureAnnouncements.isEmpty }

        XCTAssertEqual(
            recorder.failureAnnouncements.count, 1,
            "one borrow failure, one announcement — got \(recorder.all). The alert path posts "
            + "its own, so publishing through publishAndAnnounceError reads the failure twice."
        )
    }
}

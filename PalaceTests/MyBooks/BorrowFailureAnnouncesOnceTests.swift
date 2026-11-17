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
import Combine
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

    /// This is the only suite that drives `borrowAsync` on a real
    /// `MyBooksDownloadCenter`, so it is the only one that runs the production
    /// alert closure — `TPPAlertUtils.presentFromViewControllerOrNil` with a
    /// nil presenter, which resolves the SHARED
    /// `(UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController()`
    /// and presents a real `UIAlertController` there. Left presented, it makes
    /// the next nil-presenter test fail the `!(top is UIAlertController)` guard,
    /// exhaust its three retries and drop its own alert
    /// (`TPPAlertUtils.swift:325-334`). The protocol is the one documented in
    /// `TPPAlertUtilsTests`, adapted: this suite presents on the shared
    /// hierarchy rather than a window of its own, so it dismisses what it
    /// landed there instead of releasing a window it owns.
    @MainActor private static func topMostController() -> UIViewController? {
        (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController()
    }

    override func tearDown() async throws {
        await drainMainQueueAsync()

        // A presentation attempt that finds the shared top mid-transition or
        // already alerting schedules a retry at 0.4s, then 0.8s, then 1.6s
        // (`TPPAlertUtils.retryPresentation`). So an alert can land on the
        // shared hierarchy well after this teardown would otherwise have
        // returned, and present itself during a sibling suite. Sampling once is
        // not enough: when the first attempt has not landed yet there is
        // nothing to see, and a single check passes while a retry is still
        // pending.
        //
        // So drain across the whole retry window, dismissing whatever arrives.
        // The sleep is this loop's poll interval under a deadline, the same
        // shape `awaitConditionAsync` uses internally, not a wait standing in
        // for synchronisation. `awaitConditionAsync` cannot serve here because
        // it fails the test when its predicate never becomes true, and
        // "no alert ever arrives" is the expected case.
        let retryWindowEnd = Date().addingTimeInterval(3.0)
        while Date() < retryWindowEnd {
            if let top = Self.topMostController(), top is UIAlertController {
                top.presentingViewController?.dismiss(animated: false)
                // Poll rather than await a completion UIKit may never call. The
                // predicate is "this one went away", so a second alert queued
                // behind it is handled by the next turn of the loop.
                await awaitConditionAsync(timeout: 3.0) { Self.topMostController() !== top }
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await Task.yield()
            }
        }

        // Self-verifying, and deliberately here rather than in a test method:
        // a tearDown assertion runs after every test in this class, so it can
        // never be ordered before the test that presents. If the cleanup above
        // ever goes inert, this fails in this suite instead of reddening an
        // unrelated nil-presenter suite later.
        XCTAssertFalse(Self.topMostController() is UIAlertController,
                       "A leftover alert makes the next nil-presenter test exhaust its three retries and drop its own alert")

        recorder = nil
        try await super.tearDown()
    }

    /// A borrow failure must reach VoiceOver once. Two utterances is what the
    /// publish produced while it went through `publishAndAnnounceError`:
    /// `announceStatus` renders `"<title>. <message>"`, byte-identical to the
    /// string `TPPAlertUtils` posts directly for the same alert.
    func testBorrowFailure_announcesOnce_throughTheRealDownloadCentreWiring() async throws {
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
        // Scoped to its own defaults suite, never `.standard`: this flag makes
        // every borrow throw a simulated 500, and `MyBooksDownloadCenter` hands
        // the instance straight to `BorrowOperation`, so the scope holds. The
        // domain is removed even if an assertion below throws.
        let suiteName = "pp5407.announceonce.\(UUID().uuidString)"
        let scopedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { scopedDefaults.removePersistentDomain(forName: suiteName) }
        let debugSettings = DebugSettings(defaults: scopedDefaults)
        debugSettings.simulatedBorrowError = .genericServerError

        // A mock registry, so this suite reads no production object graph it
        // does not need. The real alert and publish closures are the point of
        // the suite and are unaffected: both are built from the instance, not
        // from the registry.
        let downloadCenter = MyBooksDownloadCenter(
            bookRegistry: TPPBookRegistryMock(),
            accessibilityAnnouncements: announcer,
            downloadAnnouncementService: DownloadAnnouncementService(announcer: announcer),
            debugSettings: debugSettings
        )

        // Also pin that the closure still PUBLISHES. Counting announcements
        // alone passes just as well if the body is emptied to `{ _ in }`, which
        // the compiler cannot catch — the parameter would still be supplied.
        var published: [DownloadErrorInfo] = []
        let subscription = downloadCenter.downloadErrorPublisher.sink { published.append($0) }
        defer { subscription.cancel() }

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

        XCTAssertEqual(published.count, 1,
                       "the borrow failure must still reach downloadErrorPublisher — that publish is what unsticks the half-sheet")
        XCTAssertEqual(published.first?.kind, .borrow)
        XCTAssertEqual(published.first?.presentsAlert, false,
                       "the alert is already on screen; a subscriber raising a second one is the defect this flag prevents")
        XCTAssertEqual(
            recorder.failureAnnouncements.count, 1,
            "one borrow failure, one announcement — got \(recorder.all). The alert path posts "
            + "its own, so publishing through publishAndAnnounceError reads the failure twice."
        )

        // Establish that an alert actually reached the shared hierarchy, rather
        // than leaving teardown to infer it. Teardown's own check passes
        // identically when nothing was ever presented, so on its own it cannot
        // tell "dismissed it" from "there was nothing there".
        await awaitConditionAsync(timeout: 5.0) { Self.topMostController() is UIAlertController }
    }
}

//
//  AudiobookLoaderPositionTraceWiringTests.swift
//  PalaceTests
//
//  PP-4963 — the join between the recorder and the session graph.
//
//  Every other test in this pack builds a recorder itself and drives it
//  directly, so all of them stay green while the SHIPPED instrument observes
//  nothing: the three lines in `AudiobookLoader.finalizeBuild` that construct
//  the recorder, hand it to the bookmark logic, install that as
//  `manager.bookmarkDelegate` and subscribe the liveness signal could all be
//  deleted without a single failure. Mutation does not reach it either — the
//  defect available here is a deleted CALL, not a flipped operator.
//
//  The failure direction is the bad one. `saveReportPayload` returns nil for
//  everything except `.dry`, `.tickGap` and `.clockRegressed`, so an unwired
//  recorder emits nothing at all, and nothing at all is also what a healthy
//  fleet looks like.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

@MainActor
final class AudiobookLoaderPositionTraceWiringTests: XCTestCase {

    private var loader: AudiobookLoader!
    private var host: FakePositionTraceHost!
    private var book: TPPBook!
    private var center: NotificationCenter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        loader = AudiobookLoader()
        book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        center = NotificationCenter()
        host = try FakePositionTraceHost(bookID: book.identifier)
    }

    override func tearDownWithError() throws {
        host = nil
        center = nil
        book = nil
        loader = nil
        try super.tearDownWithError()
    }

    // MARK: - Ownership

    /// The recorder must be reachable from the manager for the whole session,
    /// and the bookmark delegate is what makes it so. Every local reference is
    /// dropped inside the helper, so if the delegate does not hold it the
    /// object is gone by the time the assertion runs.
    ///
    /// Proven red by deleting `manager.bookmarkDelegate = bookmarkLogic`.
    func testMakePositionTrace_leavesTheRecorderReachableFromTheManager() {
        let collector = VerdictCollector()

        let weakTrace = wire(collector: collector)

        // lint-ignore: FLUFF-003 — `weakTrace.value` is a WEAK reference, so this
        // is a liveness assertion, not a constructor-returns-non-nil tautology.
        // `wire` has returned and its locals are gone; anything still holding the
        // recorder is the graph under test. The rule's regex cannot distinguish
        // the two shapes.
        XCTAssertNotNil(
            weakTrace.value,
            "nothing else in the graph holds the recorder — LoadedAudiobook is a "
            + "struct `bind` destructures and drops — so without the delegate it "
            + "deinits before the first locked listen begins"
        )
        XCTAssertTrue(
            host.bookmarkDelegate is AudiobookBookmarkBusinessLogic,
            "the save path and the trace must be the same object; a delegate that "
            + "is not the bookmark logic reports no saves at all"
        )
    }

    /// The other half of the same statement, so the assertion above is about
    /// the delegate rather than about an autorelease pool: releasing the
    /// delegate releases the recorder. If some other reference had crept in,
    /// this would still find the object alive.
    func testMakePositionTrace_recorderDiesWithTheDelegateAndNotBefore() {
        let collector = VerdictCollector()
        let weakTrace = wire(collector: collector)
        // lint-ignore: FLUFF-003 — weak reference; see the note above.
        XCTAssertNotNil(weakTrace.value, "precondition")

        host.bookmarkDelegate = nil

        XCTAssertNil(
            weakTrace.value,
            "the bookmark delegate is the single owner; a second reference would "
            + "let the trace outlive the save path it measures and report .dry for "
            + "a session whose saver had legitimately gone away"
        )
    }

    // MARK: - Subscription

    /// `observe` installs both sinks — the player's position signal and
    /// foreground return — in one call, so the foreground trigger firing is
    /// evidence the call happened. The position sink's own delivery is pinned
    /// by `AudiobookPositionTraceSeamTests.testObserve_deliversPlayerPositionsToTheRecorder`.
    ///
    /// Driven through an injected `NotificationCenter`: a global
    /// `didBecomeActiveNotification` also wakes `NowPlayingCoordinator`, which
    /// can emit a 403, and `DownloadThrottlingService` — in whichever test runs
    /// next.
    ///
    /// Proven red by deleting the `positionTrace.observe(player:...)` line.
    func testMakePositionTrace_subscribesTheRecorderToForegroundReturn() {
        let collector = VerdictCollector()
        wire(collector: collector)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(
            collector.verdicts, [.noPlayback],
            "a recorder that is never subscribed produces no verdict at any "
            + "foreground return, for the whole session"
        )
    }

    /// Non-vacuity for the test above: the same recorder, built the same way
    /// but never wired, stays silent. Without this, an `observe` that fired on
    /// construction would be indistinguishable from one the loader installed.
    func testWithoutMakePositionTrace_theSameForegroundReturnProducesNothing() {
        let collector = VerdictCollector()
        _ = makeRecorder(collector: collector)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(collector.verdicts, [])
    }

    // MARK: - Harness

    private func makeRecorder(collector: VerdictCollector) -> AudiobookPositionTraceRecorder {
        AudiobookPositionTraceRecorder(
            bookID: book.identifier,
            markerStore: NoopMarkerStore(),
            diagnosticsEnabled: { false },
            reportSaveVerdict: { verdict, _ in collector.append(verdict) },
            reportGapVerdict: { _ in },
            fileLog: { _ in },
            emitFleetEvent: { _, _, _ in }
        )
    }

    /// Wires a recorder and returns ONLY a weak handle. Every strong reference
    /// is a local of this function, so the caller's assertions are about what
    /// the graph holds rather than about what the test body does.
    @discardableResult
    private func wire(collector: VerdictCollector) -> WeakTraceHandle {
        let recorder = makeRecorder(collector: collector)
        loader.makePositionTrace(
            book: book,
            manager: host,
            recorder: recorder,
            notificationCenter: center
        )
        return WeakTraceHandle(recorder)
    }
}

// MARK: - Doubles

/// The `AudiobookManager` slice the trace joins to, over a real toolkit
/// `Audiobook` — the player is what `observe(player:)` subscribes to, and a
/// stubbed one would make the subscription assertion meaningless.
@MainActor
private final class FakePositionTraceHost: AudiobookPositionTraceHost {
    var bookmarkDelegate: AudiobookBookmarkDelegate?
    let audiobook: Audiobook

    init(bookID: String) throws {
        let json: [String: Any] = [
            "id": bookID,
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "identifier": bookID,
                "title": "Wiring Fixture",
                "duration": 300
            ],
            "readingOrder": [
                ["title": "One", "href": "https://example.com/one.mp3",
                 "duration": 100, "type": "audio/mpeg"],
                ["title": "Two", "href": "https://example.com/two.mp3",
                 "duration": 200, "type": "audio/mpeg"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: data)
        guard let audiobook = AudiobookFactory.audiobook(
            for: manifest, bookIdentifier: bookID, decryptor: nil, token: nil, fulfillURL: nil
        ) else {
            throw WiringFixtureError.factoryReturnedNil
        }
        self.audiobook = audiobook
    }
}

private enum WiringFixtureError: Error {
    case factoryReturnedNil
}

private final class VerdictCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PositionSaveVerdict] = []

    var verdicts: [PositionSaveVerdict] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ verdict: PositionSaveVerdict) {
        lock.lock(); defer { lock.unlock() }
        storage.append(verdict)
    }
}

private final class NoopMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    func marker(forBookID bookID: String) -> LastLivePositionMarker? { nil }
    func save(_ marker: LastLivePositionMarker) {}
}

/// Weak box so a test can observe deallocation without holding the object.
private final class WeakTraceHandle {
    private(set) weak var value: AudiobookPositionTraceRecorder?
    init(_ value: AudiobookPositionTraceRecorder) { self.value = value }
}

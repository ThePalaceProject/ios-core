//
//  AudiobookPlayerProgressRedrawTests.swift
//  PalaceTests
//
//  A playback tick arrives four times a second. Only the views that show
//  progress may observe it; the player root must not (PP-5505).
//

import SwiftUI
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookPlayerProgressRedrawTests: XCTestCase {

    private var host: AccessibilityAuditHost?

    override func tearDown() {
        host?.tearDown()
        host = nil
        super.tearDown()
    }

    private func mountExpandedPlayer(
        configure: (SpyShimSession) -> Void = { _ in }
    ) -> (AccessibilityAuditHost, AudiobookSessionPresenter, SpyShimSession) {
        let session = SpyShimSession()
        configure(session)
        let presenter = AudiobookSessionPresenter(sessionManager: session, applicationStateProvider: { .active })
        presenter.adoptBook(TPPBookMocker.snapshotAudiobook())
        presenter.expand()
        let suite = "progress-redraw.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = AudiobookMorphingPlayerView(
            presenter: presenter, progress: presenter.progress, audiobookSession: session)
            .defaultAppStorage(defaults)
        let host = AccessibilityAuditHost(UIHostingController(rootView: player))
        self.host = host
        host.settle(1.0)
        return (host, presenter, session)
    }

    private func tick(_ presenter: AudiobookSessionPresenter, offset: TimeInterval, timeLeft: TimeInterval, title: String) {
        presenter.applyPlaybackTick(.init(
            position: nil,
            chapter: .init(offset: offset, timeLeft: timeLeft, title: title)
        ))
    }

    private func labels(in host: AccessibilityAuditHost) -> [String] {
        AccessibilityTraversalAudit.traverse(host.window).map(\.label)
    }

    /// SwiftUI re-evaluates a view's body when an `ObservableObject` it holds
    /// as `@ObservedObject`/`@StateObject` publishes. The player root must not
    /// hold the four-times-a-second progress object that way.
    func testPlayerRoot_doesNotObserveThePlaybackProgress() {
        let presenter = AudiobookSessionPresenter(sessionManager: SpyShimSession())
        let root = AudiobookMorphingPlayerView(
            presenter: presenter, progress: presenter.progress, audiobookSession: SpyShimSession())

        XCTAssertEqual(Self.observedProgressProperties(of: root), [],
                       "the player root re-evaluates on every playback tick")
    }

    /// Stored properties that subscribe the view to `AudiobookPlaybackProgress`.
    private static func observedProgressProperties(of view: Any) -> [String] {
        Mirror(reflecting: view).children.compactMap { child in
            switch child.value {
            case is ObservedObject<AudiobookPlaybackProgress>,
                 is StateObject<AudiobookPlaybackProgress>,
                 is EnvironmentObject<AudiobookPlaybackProgress>:
                return child.label
            default:
                return nil
            }
        }
    }

    /// The time labels and the chapter title still follow each tick.
    func testPlaybackTick_updatesTheTimeLabelsAndChapterTitle() {
        let (host, presenter, _) = mountExpandedPlayer()

        tick(presenter, offset: 125, timeLeft: 475, title: "Chapter Seven")
        host.settle(0.3)

        let shown = labels(in: host)
        XCTAssertTrue(shown.contains(Strings.Generic.timeElapsedLabel("2:05")), "elapsed label: \(shown)")
        XCTAssertTrue(shown.contains(Strings.Generic.timeRemainingLabel("-7:55")), "remaining label: \(shown)")
        XCTAssertTrue(shown.contains("Chapter Seven"), "chapter title: \(shown)")

        tick(presenter, offset: 126, timeLeft: 474, title: "Chapter Seven")
        host.settle(0.3)

        let next = labels(in: host)
        XCTAssertTrue(next.contains(Strings.Generic.timeElapsedLabel("2:06")), "elapsed label after the next tick: \(next)")
        XCTAssertTrue(next.contains(Strings.Generic.timeRemainingLabel("-7:54")), "remaining label after the next tick: \(next)")
    }

    /// The seek bar's spoken value follows the tick: percent through the chapter
    /// and the elapsed timecode.
    func testPlaybackTick_updatesTheSeekBarValue() throws {
        let (host, presenter, _) = mountExpandedPlayer()

        tick(presenter, offset: 150, timeLeft: 450, title: "Chapter Seven")
        host.settle(0.3)

        let seekBar = try XCTUnwrap(AccessibilityTraversalAudit.traverse(host.window)
            .first { $0.label == Strings.Generic.playbackPosition })
        XCTAssertEqual(seekBar.object.accessibilityValue, "25%, 2:30")
    }

    /// `isLoaded` is read off the player and not published. A tick must still
    /// carry its change to the root, or the loading skeleton stays over a
    /// player that is ready.
    func testPlaybackTick_afterThePlayerLoads_removesTheLoadingSkeleton() {
        let (host, presenter, session) = mountExpandedPlayer { $0.isLoaded = false }
        XCTAssertTrue(labels(in: host).contains(Strings.Generic.audiobookLoading), "precondition: skeleton shown")

        session.isLoaded = true
        tick(presenter, offset: 1, timeLeft: 599, title: "Chapter One")
        host.settle(0.6)

        XCTAssertFalse(labels(in: host).contains(Strings.Generic.audiobookLoading),
                       "the skeleton stayed after the player loaded")
    }
}

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
@testable import PalaceAudiobookToolkit

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

    /// Control for the test above: the same probe finds the progress
    /// observation on the leaf that shows the timecodes.
    func testSeekBarLeaf_observesThePlaybackProgress() {
        let leaf = AudiobookPlayerSeekBar(
            progress: AudiobookPlaybackProgress(), audioWaitPhase: .none, bookTitle: nil,
            forwardStepSeconds: 30, backStepSeconds: 30, onSeek: { _ in })

        XCTAssertEqual(Self.observedProgressProperties(of: leaf), ["_progress"])
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

    /// On a first open the transport's wait for data is also unpublished; a
    /// tick must bring the skeleton back over controls that would play silence.
    func testPlaybackTick_whenTheTransportStartsWaiting_showsTheLoadingSkeleton() {
        let (host, presenter, session) = mountExpandedPlayer()
        XCTAssertFalse(labels(in: host).contains(Strings.Generic.audiobookLoading), "precondition: player usable")

        session.transportIsWaitingForData = true
        tick(presenter, offset: 1, timeLeft: 599, title: "Chapter One")
        host.settle(0.6)

        XCTAssertTrue(labels(in: host).contains(Strings.Generic.audiobookLoading),
                      "the controls stayed up while the transport waited for data")
    }

    /// A slow chapter start reported by the session alone (the open itself was
    /// not slow) must still swap the skeleton for the download explanation.
    func testPlaybackTick_whenTheSessionExpectsASlowStart_showsTheDownloadingPanel() {
        let (host, presenter, session) = mountExpandedPlayer { $0.isLoaded = false }
        XCTAssertTrue(labels(in: host).contains(Strings.Generic.audiobookLoading), "precondition: skeleton shown")

        session.expectsSlowChapterStart = true
        tick(presenter, offset: 0, timeLeft: 600, title: "Chapter One")
        host.settle(0.6)

        let shown = labels(in: host)
        XCTAssertTrue(shown.contains { $0.hasPrefix(Strings.Generic.audiobookDownloading) },
                      "no download explanation for a slow chapter start: \(shown)")
    }
}

/// The values the progress leaves show, moved out of the player root
/// unchanged (PP-5505).
@MainActor
final class AudiobookPlayerProgressTextTests: XCTestCase {
    private typealias Text = AudiobookPlayerProgressText

    func testClampedChapterProgress_keepsValuesInsideTheChapter() {
        XCTAssertEqual(Text.clampedChapterProgress(0.4), 0.4)
        XCTAssertEqual(Text.clampedChapterProgress(-0.2), 0)
        XCTAssertEqual(Text.clampedChapterProgress(1.3), 1)
    }

    /// A NaN or infinite fraction would put the thumb off the track.
    func testClampedChapterProgress_nonFinite_isZero() {
        XCTAssertEqual(Text.clampedChapterProgress(.nan), 0)
        XCTAssertEqual(Text.clampedChapterProgress(.infinity), 0)
    }

    func testChapterDuration_addsElapsedAndRemaining_ignoringNegatives() {
        XCTAssertEqual(Text.chapterDuration(offset: 120, timeLeft: 480), 600)
        XCTAssertEqual(Text.chapterDuration(offset: -5, timeLeft: 300), 300)
        XCTAssertEqual(Text.chapterDuration(offset: 90, timeLeft: -1), 90)
    }

    func testElapsedAndRemainingText_matchTheTimecodeFormat() {
        XCTAssertEqual(Text.elapsedText(offset: 125), "2:05")
        XCTAssertEqual(Text.remainingText(timeLeft: 475), "-7:55")
        XCTAssertEqual(Text.remainingText(timeLeft: -3), "-0:00")
    }

    /// At the live position the spoken value is the live timecode.
    func testSeekValue_atTheLivePosition_readsTheLiveTimecode() {
        XCTAssertEqual(
            Text.seekAccessibilityValue(fraction: 0.25, liveFraction: 0.25, chapterDuration: 600, liveElapsed: "2:31"),
            "25%, 2:31")
    }

    /// After a VoiceOver step the value names the step's target.
    func testSeekValue_afterAStep_readsTheTargetTimecode() {
        XCTAssertEqual(
            Text.seekAccessibilityValue(fraction: 0.5, liveFraction: 0.25, chapterDuration: 600, liveElapsed: "2:30"),
            "50%, 5:00")
    }

    func testSeekValue_withUnknownChapterLength_readsOnlyThePercentage() {
        XCTAssertEqual(
            Text.seekAccessibilityValue(fraction: 0.5, liveFraction: 0.5, chapterDuration: 0, liveElapsed: "0:00"),
            "50%")
    }

    func testWholeBookRemaining_withoutAPosition_isEmpty() {
        XCTAssertEqual(Text.wholeBookRemaining(position: nil, rate: .normalTime), "")
    }

    /// Book time left is the total less the playhead, phrased at the patron's speed.
    func testWholeBookRemaining_fromThePlayhead_usesTheRemainingBookTime() throws {
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        let tracks = Tracks(manifest: manifest, audiobookID: "remaining", token: nil)
        let position = TrackPosition(track: tracks.tracks[1], timestamp: 100, tracks: tracks)
        let remaining = tracks.totalDuration - position.durationToSelf()
        XCTAssertGreaterThan(position.durationToSelf(), 120, "precondition: the playhead is minutes into the book")

        XCTAssertEqual(
            Text.wholeBookRemaining(position: position, rate: .doubleTime),
            AudiobookMorphingPlayerView.wholeBookRemainingText(bookTimeRemaining: remaining, rate: .doubleTime))
        XCTAssertNotEqual(
            Text.wholeBookRemaining(position: position, rate: .doubleTime),
            AudiobookMorphingPlayerView.wholeBookRemainingText(bookTimeRemaining: tracks.totalDuration, rate: .doubleTime),
            "the figure must count from the playhead, not from the start")
    }
}

//
//  BackgroundPlaybackMemoryTrimmerTests.swift
//  PalaceTests
//
//  A trim runs once per background period, only while the app is in the
//  background with an audiobook playing; a return to the foreground restores
//  what views still hold (PP-5581).
//

import Combine
import UIKit
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class BackgroundPlaybackMemoryTrimmerTests: XCTestCase {

    private var center: NotificationCenter!
    private var playing: CurrentValueSubject<Bool, Never>!
    private var trims = 0
    private var restores = 0
    private var trimmer: BackgroundPlaybackMemoryTrimmer!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        trims = 0
        restores = 0
    }

    override func tearDown() {
        trimmer = nil
        playing = nil
        center = nil
        super.tearDown()
    }

    private func start(playing isPlaying: Bool, inBackground: Bool = false) {
        playing = CurrentValueSubject(isPlaying)
        trimmer = BackgroundPlaybackMemoryTrimmer(
            center: center,
            isPlaying: playing.eraseToAnyPublisher(),
            startsInBackground: inBackground,
            trim: { [unowned self] in trims += 1 },
            restore: { [unowned self] in restores += 1 }
        )
    }

    private func enterBackground() { center.post(name: UIApplication.didEnterBackgroundNotification, object: nil) }
    private func enterForeground() { center.post(name: UIApplication.willEnterForegroundNotification, object: nil) }

    // MARK: - States × events

    /// Foreground, playing, enter background: one trim.
    func testPlaying_EnterBackground_TrimsOnce() {
        start(playing: true)
        enterBackground()
        XCTAssertEqual(trims, 1)
    }

    /// Foreground, paused, enter background: no trim, so a paused app keeps its screens.
    func testPaused_EnterBackground_DoesNotTrim() {
        start(playing: false)
        enterBackground()
        XCTAssertEqual(trims, 0)
    }

    /// Background, paused, playback starts (lock screen play): one trim.
    func testBackgroundPaused_PlaybackStarts_Trims() {
        start(playing: false)
        enterBackground()
        playing.send(true)
        XCTAssertEqual(trims, 1)
    }

    /// Started in the background (relaunch for audio), playback starts: one trim.
    func testStartsInBackground_PlaybackStarts_Trims() {
        start(playing: false, inBackground: true)
        playing.send(true)
        XCTAssertEqual(trims, 1)
    }

    /// Background, already trimmed: pause and play again, or a repeated
    /// background notice, do not trim again in the same background period.
    func testTrimmed_PauseResumeAndRepeatedBackground_DoNotTrimAgain() {
        start(playing: true)
        enterBackground()
        playing.send(false)
        playing.send(true)
        enterBackground()
        XCTAssertEqual(trims, 1)
    }

    /// Foreground: playback changes never trim.
    func testForeground_PlaybackChanges_DoNotTrim() {
        start(playing: false)
        playing.send(true)
        playing.send(false)
        playing.send(true)
        XCTAssertEqual(trims, 0)
    }

    /// Trimmed, enter foreground: one restore; the next background period trims again.
    func testTrimmed_EnterForeground_RestoresOnce_AndNextBackgroundTrimsAgain() {
        start(playing: true)
        enterBackground()
        enterForeground()
        enterForeground()
        XCTAssertEqual(restores, 1)

        enterBackground()

        XCTAssertEqual(trims, 2)
    }

    /// Not trimmed, enter foreground: nothing to restore.
    func testNotTrimmed_EnterForeground_DoesNotRestore() {
        start(playing: false)
        enterBackground()
        enterForeground()
        XCTAssertEqual(restores, 0)
    }

    /// Background, playback stops: nothing more happens until the next trigger.
    func testBackgroundPlaying_PlaybackStops_DoesNotRestoreOrTrim() {
        start(playing: true)
        enterBackground()
        playing.send(false)
        XCTAssertEqual(trims, 1)
        XCTAssertEqual(restores, 0)
    }

    // MARK: - Container wiring

    /// A session built while the app is in the background trims as soon as
    /// playback starts; one built in the foreground waits for the background.
    func testContainerTrimmer_builtInBackground_trimsOnPlayback() {
        let coordinator = MemoryReleaseCoordinator(center: NotificationCenter())
        let owner = NSObject()
        let released = ReleaseCount()
        coordinator.register(owner, stage: .catalogFeeds) { _ in released.increment() }
        let isPlaying = CurrentValueSubject<Bool, Never>(false)
        let store = BookCoverStore(limits: .init(byteLimit: .max, keepRecent: 0))
        let background = AppContainer.makeBackgroundPlaybackTrimmer(
            isPlaying: isPlaying.eraseToAnyPublisher(), applicationState: .background,
            memoryRelease: coordinator, bookCoverStore: store, center: center
        )
        let foregroundPlaying = CurrentValueSubject<Bool, Never>(false)
        let foreground = AppContainer.makeBackgroundPlaybackTrimmer(
            isPlaying: foregroundPlaying.eraseToAnyPublisher(), applicationState: .active,
            memoryRelease: coordinator, bookCoverStore: store, center: NotificationCenter()
        )

        isPlaying.send(true)
        XCTAssertEqual(released.value, 1, "the background-built trimmer trims on playback")
        foregroundPlaying.send(true)
        XCTAssertEqual(released.value, 1, "the foreground-built trimmer does not")
        withExtendedLifetime((background, foreground, owner)) {}
    }

    /// A container trim releases only the screen stages and the cover store's
    /// images outside the keep list, never the player's LCP decrypt cache,
    /// downloads, book cells or the decoded-image cache; returning to the
    /// foreground restores the covers views still hold.
    func testContainerTrimmer_trimsOnlyScreenMemory_andRestoresOnForeground() async {
        let coordinator = MemoryReleaseCoordinator(center: NotificationCenter())
        let log = StageLog()
        let owners = MemoryReleaseStage.allCases.map { stage -> NSObject in
            let owner = NSObject()
            coordinator.register(owner, stage: stage) { _ in log.append(stage) }
            return owner
        }
        let store = BookCoverStore(limits: .init(byteLimit: .max, keepRecent: 0))
        let shown = Self.makeBook("trim-shown", store: store)
        let playing = Self.makeBook("trim-playing", store: store)
        await drainMainQueueAsync()
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let playingCover = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        shown.coverImage = drawn
        playing.coverImage = playingCover
        let trimmer = AppContainer.makeBackgroundPlaybackTrimmer(
            isPlaying: Just(true).eraseToAnyPublisher(), applicationState: .active,
            memoryRelease: coordinator, bookCoverStore: store,
            keepList: { ["trim-playing"] }, center: center
        )

        enterBackground()

        XCTAssertEqual(Set(log.all), [.catalogFeeds, .cachedData])
        XCTAssertNil(store.state(for: "trim-shown").coverImage, "the store released the shown cover")
        XCTAssertIdentical(store.state(for: "trim-playing").coverImage, playingCover, "the playing book's cover stays")

        enterForeground()

        XCTAssertIdentical(store.state(for: "trim-shown").coverImage, drawn, "restore made the held cover strong again")
        withExtendedLifetime((trimmer, owners, shown, playing, drawn)) {}
    }

    private final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [MemoryReleaseStage] = []
        var all: [MemoryReleaseStage] { lock.withLock { stages } }
        func append(_ stage: MemoryReleaseStage) { lock.withLock { stages.append(stage) } }
    }

    private static func makeBook(_ identifier: String, store: BookCoverStore) -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Title",
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
            imageCache: MockImageCache(),
            coverStore: store
        )
    }

    private final class ReleaseCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    // MARK: - Stages

    /// A trim runs only the stages a return to the foreground can redraw from
    /// without a placeholder or a fetch: feeds the screens already hold and
    /// the memory layer of disk caches.
    func testStages_AreTheScreenOnlyStages() {
        XCTAssertEqual(BackgroundPlaybackMemoryTrimmer.stages, [.catalogFeeds, .cachedData])
    }
}

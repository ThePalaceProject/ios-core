//  AudiobookSessionPresenterBackgroundTickTests.swift
//
//  PP-4970: the root player view observes `progress`, so every playback tick
//  re-evaluates the whole player. These tests pin that ticks arriving while
//  the app is in the background do not notify `progress` observers, that the
//  latest held tick is applied on foreground entry, and that unchanged values
//  are not re-published.

import Combine
import UIKit
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookSessionPresenterBackgroundTickTests: XCTestCase {

    private var spySession: SpyShimSession!
    private var notificationCenter: NotificationCenter!
    private let appState = LockIsolated<UIApplication.State>(.active)
    private var tracks: Tracks!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        spySession = SpyShimSession()
        notificationCenter = NotificationCenter()
        appState.value = .active
        let manifest = try Manifest.from(
            jsonFileName: ManifestJSON.snowcrash.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: "pp-4970-book", token: nil)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        spySession = nil
        notificationCenter = nil
        tracks = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makePresenter() -> AudiobookSessionPresenter {
        AudiobookSessionPresenter(
            sessionManager: spySession,
            applicationStateProvider: { [appState] in appState.value },
            notificationCenter: notificationCenter
        )
    }

    private func tick(at seconds: Double, title: String = "Chapter 1") -> AudiobookSessionPresenter.PlaybackTick {
        let position = TrackPosition(track: tracks.tracks[0], timestamp: seconds, tracks: tracks)
        return AudiobookSessionPresenter.PlaybackTick(
            position: position,
            chapter: .init(offset: seconds, timeLeft: 600 - seconds, title: title)
        )
    }

    private func countProgressChanges(_ presenter: AudiobookSessionPresenter) -> LockIsolated<Int> {
        let count = LockIsolated(0)
        presenter.progress.objectWillChange
            .sink { _ in count.withValue { $0 += 1 } }
            .store(in: &cancellables)
        return count
    }

    private func spinMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Background gate

    /// Ticks while backgrounded (screen locked) must not invalidate the player
    /// view; nothing is on screen to read them.
    func testPlaybackTicks_whileInBackground_doNotNotifyProgressObservers() {
        let presenter = makePresenter()
        appState.value = .background
        let changes = countProgressChanges(presenter)

        for second in stride(from: 10.0, to: 15.0, by: 0.25) {
            presenter.applyPlaybackTick(tick(at: second))
        }

        XCTAssertEqual(changes.value, 0, "background ticks must not publish to the player view")
        XCTAssertNil(presenter.progress.currentLocation, "background ticks must not write progress")
    }

    /// `.inactive` covers Control Center and incoming-call banners, where the
    /// player is still visible behind the overlay. Only `.background` holds ticks.
    func testPlaybackTick_whileInactive_stillUpdatesProgress() {
        let presenter = makePresenter()
        appState.value = .inactive

        presenter.applyPlaybackTick(tick(at: 42))

        XCTAssertEqual(presenter.progress.currentLocation?.timestamp, 42)
        XCTAssertEqual(presenter.progress.chapterOffset, 42)
    }

    func testPlaybackTick_whileActive_mirrorsEveryField() {
        let presenter = makePresenter()

        presenter.applyPlaybackTick(tick(at: 120, title: "Chapter 3"))

        XCTAssertEqual(presenter.progress.currentLocation?.timestamp, 120)
        XCTAssertEqual(presenter.progress.chapterOffset, 120)
        XCTAssertEqual(presenter.progress.chapterTimeLeft, 480)
        XCTAssertEqual(presenter.progress.chapterTitle, "Chapter 3")
        XCTAssertEqual(presenter.progress.chapterProgress, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThan(presenter.progress.playbackProgress, 0)
    }

    // MARK: - Foreground re-sync

    /// The latest held tick must reach the view on foreground entry, so the
    /// player does not show the position from when the screen was locked.
    func testForegroundEntry_appliesLatestTickHeldInBackground() {
        let presenter = makePresenter()
        presenter.applyPlaybackTick(tick(at: 10))
        appState.value = .background
        presenter.applyPlaybackTick(tick(at: 300, title: "Chapter 2"))
        presenter.applyPlaybackTick(tick(at: 301, title: "Chapter 2"))
        XCTAssertEqual(presenter.progress.currentLocation?.timestamp, 10, "PRECONDITION: held while backgrounded")

        notificationCenter.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        spinMainQueue()

        XCTAssertEqual(presenter.progress.currentLocation?.timestamp, 301)
        XCTAssertEqual(presenter.progress.chapterTitle, "Chapter 2")
        XCTAssertEqual(presenter.progress.chapterOffset, 301)
    }

    /// A held tick is applied once; a second foreground entry with no new tick
    /// must not re-publish it.
    func testForegroundEntry_withNoHeldTick_doesNotNotifyProgressObservers() {
        let presenter = makePresenter()
        presenter.applyPlaybackTick(tick(at: 10))
        let changes = countProgressChanges(presenter)

        notificationCenter.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        spinMainQueue()

        XCTAssertEqual(changes.value, 0)
    }

    /// Clearing the session drops a held tick, so a foreground entry after
    /// closing the book cannot resurrect the old position.
    func testClearActiveSession_dropsHeldTick() {
        let presenter = makePresenter()
        appState.value = .background
        presenter.applyPlaybackTick(tick(at: 300))

        presenter.clearActiveSession()
        notificationCenter.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        spinMainQueue()

        XCTAssertNil(presenter.progress.currentLocation)
    }

    // MARK: - Unchanged values

    /// The chapter title is the same on almost every tick; re-assigning an
    /// unchanged `@Published` value still notifies observers.
    func testPlaybackTick_withUnchangedChapterTitle_doesNotRepublishTitle() {
        let presenter = makePresenter()
        presenter.applyPlaybackTick(tick(at: 10, title: "Chapter 1"))
        let titleWrites = LockIsolated(0)
        presenter.progress.$chapterTitle.dropFirst()
            .sink { _ in titleWrites.withValue { $0 += 1 } }
            .store(in: &cancellables)

        presenter.applyPlaybackTick(tick(at: 10.25, title: "Chapter 1"))
        presenter.applyPlaybackTick(tick(at: 10.5, title: "Chapter 1"))

        XCTAssertEqual(titleWrites.value, 0)
    }

    func testPlaybackTick_identicalToPrevious_doesNotNotifyProgressObservers() {
        let presenter = makePresenter()
        presenter.applyPlaybackTick(tick(at: 10))
        let changes = countProgressChanges(presenter)

        presenter.applyPlaybackTick(tick(at: 10))

        XCTAssertEqual(changes.value, 0)
    }

    /// A tick without chapter values (the playback model was released) still
    /// updates the book-level fields and leaves the chapter fields alone.
    func testPlaybackTick_withoutChapterValues_updatesOnlyBookLevelFields() {
        let presenter = makePresenter()
        presenter.applyPlaybackTick(tick(at: 10, title: "Chapter 1"))
        let position = TrackPosition(track: tracks.tracks[0], timestamp: 20, tracks: tracks)

        presenter.applyPlaybackTick(.init(position: position, chapter: nil))

        XCTAssertEqual(presenter.progress.currentLocation?.timestamp, 20)
        XCTAssertEqual(presenter.progress.chapterOffset, 10)
        XCTAssertEqual(presenter.progress.chapterTitle, "Chapter 1")
    }
}

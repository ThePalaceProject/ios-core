//
//  AppContainerPlaytimeUploaderTests.swift
//  PalaceTests
//
//  The container serves one play-time uploader, wired to the activity
//  policy so it sends when the app goes to the background (PP-5508).
//

import XCTest
@testable import Palace

@MainActor
final class AppContainerPlaytimeUploaderTests: XCTestCase {

    private let libraryId = "urn:uuid:container-playtime-library"
    private let trackingURL = URL(string: "https://cm.example.com/lib/playtimes/container-book")!

    private var spy: SpyAudiobookNetworkExecutor!
    private var container: AppContainer!
    private var originalScene: SceneVisibility = .background

    override func setUp() async throws {
        try await super.setUp()
        clearStoreFile()
        // The container built here owns its own process services, so its
        // uploader is built against this test's executor. Do not rebuild the
        // app's container here: that drains every live AccountsManager, which
        // takes longer the more tests ran before this one.
        spy = SpyAudiobookNetworkExecutor()
        let defaults = TestContainerDefaults.make()
        defaults.set(libraryId, forKey: currentAccountIdentifierKey)
        container = makeTestAppContainer(networkExecutor: spy, defaults: defaults)
        originalScene = container.activityPolicy.state.scene
    }

    override func tearDown() async throws {
        container?.activityPolicy.setScene(originalScene)
        container = nil
        spy = nil
        clearStoreFile()
        try await super.tearDown()
    }

    func testPlaytimeUploader_TwoReads_ReturnTheSameInstance() {
        let first = container.playtimeUploader

        XCTAssertTrue(first === container.playtimeUploader, "every tracker must save into one queue")
    }

    func testPlaytimeUploader_WhenTheAppGoesToTheBackground_SendsTheQueueThroughTheContainerExecutor() async {
        let uploader = container.playtimeUploader
        uploader.store.queue.removeAll()
        uploader.store.urls.removeAll()
        // The reachability subscription may sync the empty queue once.
        await drainMainQueueAsync()
        uploader.syncQueue.sync {}
        spy.reset()
        uploader.save(time: AudiobookTimeEntry(
            id: "container-entry-1", bookId: "container-book", libraryId: libraryId,
            timeTrackingUrl: trackingURL, duringMinute: "2026-11-10T10:00Z", duration: 30
        ))
        uploader.syncQueue.sync {}

        let policy = container.activityPolicy
        policy.setScene(.active)
        policy.setScene(.background)
        uploader.syncQueue.sync {}

        XCTAssertEqual(spy.postedURLs, [trackingURL])
    }

    private func clearStoreFile() {
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: "timetracker") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("store.json"))
        }
    }
}

//
//  AudiobookReliabilityTests.swift
//  PalaceTests
//
//  Tests for audiobook reliability fixes including:
//  - Background session recovery
//  - Download storage location
//  - Download watchdog
//  - Position state management
//  - Download persistence
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

// MARK: - AudiobookSessionManager Tests

final class AudiobookSessionManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear state before each test
        AudiobookSessionManager.shared.clearAllState()
    }

    override func tearDown() {
        AudiobookSessionManager.shared.clearAllState()
        super.tearDown()
    }

    func testRegisterActiveDownload() async {
        // Given
        let sessionId = "test-session-\(UUID().uuidString)"
        let bookId = "test-book-123"
        let trackKey = "track-1"
        let remoteURL = URL(string: "https://example.com/audio.mp3")!
        let localURL = URL(fileURLWithPath: "/tmp/test.mp3")

        // When
        AudiobookSessionManager.shared.registerActiveDownload(
            sessionIdentifier: sessionId,
            bookID: bookId,
            trackKey: trackKey,
            originalURL: remoteURL,
            localDestination: localURL
        )

        // Wait for async operation
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Then
        let downloads = AudiobookSessionManager.shared.activeDownloads(forBookID: bookId)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.first?.trackKey, trackKey)
        XCTAssertEqual(downloads.first?.state, .downloading)
    }

    func testUpdateDownloadProgress() async {
        // Given
        let sessionId = "test-session-\(UUID().uuidString)"
        let bookId = "test-book-456"

        AudiobookSessionManager.shared.registerActiveDownload(
            sessionIdentifier: sessionId,
            bookID: bookId,
            trackKey: "track-1",
            originalURL: URL(string: "https://example.com/audio.mp3")!,
            localDestination: URL(fileURLWithPath: "/tmp/test.mp3")
        )

        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000)

        // When
        AudiobookSessionManager.shared.updateDownloadProgress(sessionIdentifier: sessionId, progress: 0.5)

        // Wait for update
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Then
        let info = AudiobookSessionManager.shared.downloadInfo(forSessionIdentifier: sessionId)
        XCTAssertEqual(Double(info?.progress ?? 0), 0.5, accuracy: 0.01)
    }

    func testBackgroundCompletionHandlerRegistration() {
        // Given
        let sessionId = "test-session-\(UUID().uuidString)"
        let handlerExpectation = expectation(description: "Background completion handler should be called")

        // When - register the handler
        AudiobookSessionManager.shared.registerBackgroundCompletionHandler({
            handlerExpectation.fulfill()
        }, forSessionIdentifier: sessionId)

        // Allow registration to complete on the concurrent queue
        let registrationExpectation = expectation(description: "Registration completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            registrationExpectation.fulfill()
        }
        wait(for: [registrationExpectation], timeout: 1.0)

        // Then call it
        AudiobookSessionManager.shared.callCompletionHandler(forSessionIdentifier: sessionId)

        // Assert - wait for the handler to be called on the main thread
        wait(for: [handlerExpectation], timeout: 3.0)
    }
}

// MARK: - Download Watchdog Tests

final class DownloadWatchdogTests: XCTestCase {

    func testWatchdogConfiguration() {
        // Given
        let config = DownloadWatchdog.Configuration(
            stallTimeout: 30.0,
            maxRetries: 5,
            retryDelay: 3.0,
            checkInterval: 5.0
        )

        // When
        let watchdog = DownloadWatchdog(configuration: config)

        // Then
        XCTAssertEqual(watchdog.configuration.stallTimeout, 30.0)
        XCTAssertEqual(watchdog.configuration.maxRetries, 5)
        XCTAssertEqual(watchdog.configuration.retryDelay, 3.0)
        XCTAssertEqual(watchdog.configuration.checkInterval, 5.0)
    }

    func testDefaultConfiguration() {
        // Given/When
        let config = DownloadWatchdog.Configuration.default

        // Then
        XCTAssertEqual(config.stallTimeout, 45.0)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.retryDelay, 5.0)
        XCTAssertEqual(config.checkInterval, 10.0)
    }

    func testStartAndStop() async {
        // Given
        let watchdog = DownloadWatchdog()

        // When
        watchdog.start()

        // Allow async task to initialize
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Then
        XCTAssertTrue(watchdog.status.isEmpty) // No downloads monitored yet

        // Cleanup
        watchdog.stop()

        // Allow cleanup to complete
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

// MARK: - Download Persistence Store Tests

final class DownloadPersistenceStoreTests: XCTestCase {

    private var store: DownloadPersistenceStore!

    override func setUp() {
        super.setUp()
        store = DownloadPersistenceStore.shared
        // Clear any existing data
        store.clearAll()
    }

    override func tearDown() {
        store.clearAll()
        super.tearDown()
    }

    func testRegisterDownload() {
        // Given
        let bookID = "test-book-\(UUID().uuidString)"
        let trackKey = "track-1"
        let remoteURL = URL(string: "https://example.com/audio.mp3")!
        let localURL = URL(fileURLWithPath: "/tmp/test.mp3")

        // When
        store.registerDownload(
            bookID: bookID,
            trackKey: trackKey,
            remoteURL: remoteURL,
            localFileURL: localURL,
            totalBytes: 1000000
        )

        // Then — getDownload uses queue.sync which drains all prior async barriers
        let download = store.getDownload(bookID: bookID, trackKey: trackKey)
        XCTAssertNotNil(download)
        XCTAssertEqual(download?.bookID, bookID)
        XCTAssertEqual(download?.trackKey, trackKey)
        XCTAssertEqual(download?.state, .pending)
        XCTAssertEqual(download?.progress, 0)
    }

    func testUpdateProgress() {
        // Given
        let bookID = "test-book-\(UUID().uuidString)"
        let trackKey = "track-1"

        store.registerDownload(
            bookID: bookID,
            trackKey: trackKey,
            remoteURL: URL(string: "https://example.com/audio.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test.mp3"),
            totalBytes: 1000000
        )

        // When
        store.updateProgress(
            bookID: bookID,
            trackKey: trackKey,
            downloadedBytes: 500000,
            state: .inProgress
        )

        // Then — getDownload uses queue.sync which drains all prior async barriers
        let download = store.getDownload(bookID: bookID, trackKey: trackKey)
        XCTAssertEqual(download?.downloadedBytes, 500000)
        XCTAssertEqual(download?.state, .inProgress)
        XCTAssertEqual(Double(download?.progress ?? 0), 0.5, accuracy: 0.01)
    }

    func testMarkCompleted() {
        // Given
        let bookID = "test-book-\(UUID().uuidString)"
        let trackKey = "track-1"

        store.registerDownload(
            bookID: bookID,
            trackKey: trackKey,
            remoteURL: URL(string: "https://example.com/audio.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test.mp3"),
            totalBytes: 1000000
        )

        // When
        store.markCompleted(bookID: bookID, trackKey: trackKey)

        // Then — getDownload uses queue.sync which drains all prior async barriers
        let download = store.getDownload(bookID: bookID, trackKey: trackKey)
        XCTAssertEqual(download?.state, .completed)
        XCTAssertTrue(download?.isComplete ?? false)
    }

    func testGetIncompleteDownloads() {
        // Given
        let bookID = "test-book-\(UUID().uuidString)"

        store.registerDownload(
            bookID: bookID,
            trackKey: "track-1",
            remoteURL: URL(string: "https://example.com/audio1.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test1.mp3"),
            totalBytes: 1000000
        )

        store.registerDownload(
            bookID: bookID,
            trackKey: "track-2",
            remoteURL: URL(string: "https://example.com/audio2.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test2.mp3"),
            totalBytes: 1000000
        )

        // Complete one download
        store.markCompleted(bookID: bookID, trackKey: "track-1")

        // When — getIncompleteDownloads uses queue.sync which drains all prior async barriers
        // (register track-1, register track-2, markCompleted track-1) before reading
        let incomplete = store.getIncompleteDownloads(bookID: bookID)

        // Then
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(incomplete.first?.trackKey, "track-2")
    }

    func testBookDownloadsOverallProgress() {
        // Given
        let bookID = "test-book-\(UUID().uuidString)"

        store.registerDownload(
            bookID: bookID,
            trackKey: "track-1",
            remoteURL: URL(string: "https://example.com/audio1.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test1.mp3"),
            totalBytes: 1000
        )

        store.registerDownload(
            bookID: bookID,
            trackKey: "track-2",
            remoteURL: URL(string: "https://example.com/audio2.mp3")!,
            localFileURL: URL(fileURLWithPath: "/tmp/test2.mp3"),
            totalBytes: 1000
        )

        // Update progress
        store.updateProgress(bookID: bookID, trackKey: "track-1", downloadedBytes: 500)
        store.updateProgress(bookID: bookID, trackKey: "track-2", downloadedBytes: 250)

        // When — getBookDownloads uses queue.sync which drains all prior async barriers
        let bookDownloads = store.getBookDownloads(bookID: bookID)

        // Then
        // (0.5 + 0.25) / 2 = 0.375
        XCTAssertEqual(bookDownloads?.overallProgress ?? 0, 0.375, accuracy: 0.01)
    }
}

// MARK: - Storage Location Tests

final class AudiobookStorageLocationTests: XCTestCase {

    func testApplicationSupportDirectoryExists() {
        // Given
        let fileManager = FileManager.default

        // When
        let appSupportURLs = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)

        // Then
        XCTAssertFalse(appSupportURLs.isEmpty)
        XCTAssertTrue(appSupportURLs.first != nil)
    }

    func testAudiobooksDirectoryPath() {
        // Given
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("No application support directory")
            return
        }

        // When
        let expectedPath = appSupport.appendingPathComponent("Audiobooks/Downloads", isDirectory: true)

        // Then
        XCTAssertTrue(expectedPath.path.contains("Library/Application Support"))
        XCTAssertTrue(expectedPath.path.hasSuffix("Audiobooks/Downloads"))
    }

    func testOverdriveDirectoryPath() {
        // Given
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("No application support directory")
            return
        }

        // When - OverDrive now uses the same shared directory as OpenAccess for backward compatibility
        let expectedPath = appSupport.appendingPathComponent("Audiobooks/Downloads", isDirectory: true)

        // Then
        XCTAssertTrue(expectedPath.path.contains("Library/Application Support"))
        XCTAssertTrue(expectedPath.path.hasSuffix("Audiobooks/Downloads"))
    }
}

// MARK: - Background Listener Tests

final class BackgroundListenerTests: XCTestCase {

    func testOpenAccessListenerIdentifiesCorrectSessions() {
        // Given
        let listener = OpenAccessBackgroundListener()

        // When/Then - correct identifier
        var handled = false
        let correctId = "com.palace.app.openAccessBackgroundIdentifier.abc123"

        handled = listener.handleBackgroundURLSession(for: correctId) { }
        XCTAssertTrue(handled)

        // When/Then - wrong identifier
        let wrongId = "com.palace.app.overdriveBackgroundIdentifier.xyz"
        handled = listener.handleBackgroundURLSession(for: wrongId) { }
        XCTAssertFalse(handled)

        // When/Then - Findaway identifier
        let findawayId = "FWAE_session_123"
        handled = listener.handleBackgroundURLSession(for: findawayId) { }
        XCTAssertFalse(handled)
    }

    func testOverdriveListenerIdentifiesCorrectSessions() {
        // Given
        let listener = OverdriveBackgroundListener()

        // When/Then - correct identifier
        var handled = false
        let correctId = "com.palace.app.overdriveBackgroundIdentifier.book123-hash456"

        handled = listener.handleBackgroundURLSession(for: correctId) { }
        XCTAssertTrue(handled)

        // When/Then - wrong identifier
        let wrongId = "com.palace.app.openAccessBackgroundIdentifier.abc123"
        handled = listener.handleBackgroundURLSession(for: wrongId) { }
        XCTAssertFalse(handled)
    }
}

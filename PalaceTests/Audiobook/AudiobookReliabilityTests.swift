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

// MARK: - Download Watchdog Tests

@MainActor
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

    func testDefaultConfiguration() {        // Given/When
        let config = DownloadWatchdog.Configuration.default

        // Then
        XCTAssertEqual(config.stallTimeout, 45.0)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.retryDelay, 5.0)
        XCTAssertEqual(config.checkInterval, 10.0)
    }

    func testStartAndStop() {
        let watchdog = DownloadWatchdog(configuration: .default)

        watchdog.start()
        XCTAssertTrue(watchdog.status.isEmpty)
        watchdog.stop()

        // Regression guard: the pre-fix DownloadWatchdog strong-rebound `self`
        // at the top of its monitoring Task, so `stop()` returned while the
        // Task was still alive and holding the instance. deinit firing at
        // scope exit raced the still-pending `queue.async(flags: .barrier)`
        // cleanup and crashed the process ~20s after this test asserted.
        // With stop() now fully synchronous (barrier-sync) and the Task
        // weak-only, the instance must be safe to drop at scope exit.
        XCTAssertTrue(watchdog.status.isEmpty, "stop() must leave status cleared")
    }
}

// MARK: - Download Persistence Store Tests

@MainActor
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

@MainActor
final class AudiobookStorageLocationTests: XCTestCase {

    func testApplicationSupportDirectoryExists() {
        // Given
        let fileManager = FileManager.default

        // When
        let appSupportURLs = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportURL = appSupportURLs.first

        // Then — directory must exist and be a directory (not a file)
        XCTAssertFalse(appSupportURLs.isEmpty, "Application support directories list must not be empty")
        XCTAssertNotNil(appSupportURL, "Must have at least one application support directory URL")
        if let url = appSupportURL {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            XCTAssertTrue(exists, "Application support directory must exist on disk")
            XCTAssertTrue(isDir.boolValue, "Application support URL must point to a directory, not a file")
        }
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

        // Then — verify path structure and that it is buildable (not a dead path reference)
        XCTAssertTrue(expectedPath.path.contains("Library/Application Support"),
                      "Audiobooks/Downloads path must reside in Library/Application Support")
        XCTAssertTrue(expectedPath.path.hasSuffix("Audiobooks/Downloads"),
                      "Path must end with Audiobooks/Downloads")
        XCTAssertTrue(expectedPath.hasDirectoryPath,
                      "URL must be marked as a directory path")
        XCTAssertFalse(expectedPath.path.isEmpty, "Resulting path must not be empty")
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

@MainActor
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

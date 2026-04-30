//
//  BookContentResetServiceTests.swift
//  PalaceTests
//
//  Coverage for the per-account content obliteration paths in
//  BookContentResetService. The current-account reset() flow's
//  task-cancel + state-clear + content-dir-remove sequence is the
//  highest-value branch — that's the sign-out cleanup path.
//

import XCTest
@testable import Palace

final class BookContentResetServiceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var bookFileManager: SpyBookFileManager!
    private var reporter: DownloadProgressReporter!
    private var localContent: SpyLocalContentService!
    private var service: BookContentResetService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BookContentResetServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        bookFileManager = SpyBookFileManager(tempDir: tempDir, bookRegistry: registry)
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        localContent = SpyLocalContentService()

        service = BookContentResetService(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            stateManager: stateManager,
            bookFileManager: bookFileManager,
            progressReporter: reporter,
            localContentService: localContent
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        stateManager = nil
        bookFileManager = nil
        reporter = nil
        localContent = nil
        service = nil
        try super.tearDownWithError()
    }

    // NOTE: deleteAudiobooks(forAccount:) and the per-account branch of
    // reset(account:) cannot be unit-tested with TPPBookRegistryMock —
    // its `with(account:perform:)` is a no-op that doesn't invoke the
    // block (the closure parameter is the concrete TPPBookRegistry type
    // which the mock can't furnish). Those branches are exercised
    // end-to-end via the sign-in-flow integration that calls
    // TPPBookDownloadsDeleting.reset(_:) when the user signs out.

    // MARK: - purgeAllAudiobookCaches

    func testPurge_force_invokesEvenWithActiveAudiobooks() throws {
        // Drop a fake .mp3 in the system caches dir so we can verify the
        // sweep ran. Restore on tearDown.
        let cachesDir = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let fakeAudio = cachesDir.appendingPathComponent("BookContentResetTests-\(UUID().uuidString).mp3")
        try Data(repeating: 0, count: 32).write(to: fakeAudio)
        defer { try? FileManager.default.removeItem(at: fakeAudio) }

        // Active audiobook in registry — without `force: true`, the purge
        // should skip. With force: true, it must clear our test file.
        let audiobook = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        registry.addBook(audiobook, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        service.purgeAllAudiobookCaches(force: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeAudio.path),
                       "force=true must clear audiobook caches even with active audiobooks")
    }

    // MARK: - reset(account:) for non-current account

    func testResetAccount_otherAccount_removesContentDirectory() throws {
        // The per-account-content-dir-removal branch IS testable even
        // though deleteAudiobooks is a no-op against the mock — we just
        // check the directory actually got cleaned up.
        let otherAccount = "definitely-not-the-current-account-\(UUID().uuidString)"
        let otherURL = tempDir.appendingPathComponent("other-content-dir")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        bookFileManager.fakeContentDirectoryByAccount[otherAccount] = otherURL

        service.reset(account: otherAccount)

        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.path),
                       "Per-account reset must remove the content directory for the named account")
    }
}

// MARK: - Spies

private final class SpyBookFileManager: BookFileManager {
    private let tempDir: URL
    var fakeContentDirectoryByAccount: [String?: URL] = [:]

    init(tempDir: URL, bookRegistry: TPPBookRegistryProvider) {
        self.tempDir = tempDir
        super.init(
            bookRegistry: bookRegistry,
            accountsManager: AppContainer.production().accountsManager,
            fileManager: .default
        )
    }

    override func contentDirectoryURL(_ account: String?) -> URL? {
        fakeContentDirectoryByAccount[account] ?? tempDir
    }
}

private final class SpyLocalContentService: LocalBookContentService {
    var deleteForIdentifierCalls: [String] = []

    init() {
        super.init(
            bookRegistry: TPPBookRegistryMock(),
            accountsManager: AppContainer.production().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: TPPBookRegistryMock()),
            fileManager: .default
        )
    }

    override func deleteLocalContent(for identifier: String, account: String? = nil) {
        deleteForIdentifierCalls.append(identifier)
    }
}

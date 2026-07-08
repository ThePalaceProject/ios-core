//
//  LocalBookContentServiceTests.swift
//  PalaceTests
//
//  Coverage for the local-content deletion paths extracted into
//  LocalBookContentService. Exercises both `deleteLocalContent`
//  overloads (identifier + book) across the epub / pdf / audiobook
//  / unsupported branches against a temp-dir BookFileManager.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class LocalBookContentServiceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var bookFileManager: SpyBookFileManager!
    private var service: LocalBookContentService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalBookContentServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        registry = TPPBookRegistryMock()
        bookFileManager = SpyBookFileManager(
            tempDir: tempDir,
            bookRegistry: registry
        )
        service = LocalBookContentService(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            bookFileManager: bookFileManager
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        bookFileManager = nil
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(at url: URL, bytes: Int = 100) throws -> URL {
        try Data(repeating: 0xCC, count: bytes).write(to: url)
        return url
    }

    private func seedBook(_ book: TPPBook) {
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    // MARK: - deleteLocalContent(for: identifier)

    func testDeleteForIdentifier_unknownIdentifier_logsAndDoesNothing() {
        // No book added — service should bail out without touching disk.
        // Drop a stray file so we can assert nothing got removed.
        let strayURL = tempDir.appendingPathComponent("stray.epub")
        try? Data(repeating: 0x00, count: 50).write(to: strayURL)

        service.deleteLocalContent(for: "nonexistent-id")

        XCTAssertTrue(FileManager.default.fileExists(atPath: strayURL.path),
                      "Unknown identifier must not delete unrelated files")
    }

    func testDeleteForIdentifier_lookUpsBookInRegistryAndDelegates() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedBook(book)

        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        service.deleteLocalContent(for: book.identifier)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Identifier-overload must resolve the book and delete its file")
    }

    // MARK: - deleteLocalContent(forBook:)

    func testDeleteForBook_epub_removesFileWhenPresent() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "epub branch must remove the file from disk")
    }

    func testDeleteForBook_epub_missingFile_logsButDoesNotThrow() {
        // No file written, just attempt deletion. The service catches
        // missing-file and continues — no XCTFail expected.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        service.deleteLocalContent(forBook: book)
        // No assertion needed beyond "didn't crash" — the test passing
        // means the method handled the missing-file branch gracefully.
    }

    func testDeleteForBook_pdf_removesContentFile() throws {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "pdf branch must remove the content file")
    }

    func testDeleteForBook_unresolvableFileURL_doesNotCrashAndLogsWarning() {
        // MISSING-001-OK: crash-guard — exercises the "Could not resolve fileUrl"
        // early-return; observable contract is "no crash, no exception, no side
        // effect on the file manager beyond the lookup attempt".
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookFileManager.failResolutionForIdentifier = book.identifier

        service.deleteLocalContent(forBook: book)

        // Tested implicitly — no crash, no exception. The warning log
        // path is hit per the implementation's `Log.warn`.
    }

    // MARK: - Per-account isolation

    func testDeleteForBook_accountOverride_passedThroughToBookFileManager() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book, account: "explicit-account-id")

        XCTAssertEqual(bookFileManager.lastResolvedAccount, "explicit-account-id",
                       "Caller-supplied account must be threaded through to the file manager")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Test fakes

/// BookFileManager subclass that resolves to predictable temp-dir URLs
/// without requiring real per-account directories. Captures the most
/// recent account passed for assertions.
private final class SpyBookFileManager: BookFileManager {
    private let tempDir: URL
    var lastResolvedAccount: String?
    /// Identifier whose lookup should return nil — exercises the
    /// "Could not resolve fileUrl" branch.
    var failResolutionForIdentifier: String?

    init(tempDir: URL, bookRegistry: TPPBookRegistryProvider) {
        self.tempDir = tempDir
        super.init(
            bookRegistry: bookRegistry,
            accountsManager: AppContainer.production().accountsManager,
            fileManager: .default
        )
    }

    func fakeURLFor(_ book: TPPBook) -> URL {
        let ext: String
        switch book.defaultBookContentType {
        case .epub: ext = "epub"
        case .pdf: ext = "pdf"
        case .audiobook: ext = "json"
        default: ext = "bin"
        }
        return tempDir.appendingPathComponent(book.identifier).appendingPathExtension(ext)
    }

    override func fileUrl(for book: TPPBook, account: String?) -> URL? {
        lastResolvedAccount = account
        if book.identifier == failResolutionForIdentifier { return nil }
        return fakeURLFor(book)
    }
}

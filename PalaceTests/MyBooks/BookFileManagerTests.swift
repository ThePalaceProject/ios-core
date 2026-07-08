//
//  BookFileManagerTests.swift
//  PalaceTests
//
//  Verifies the on-disk path geometry — per-account content directory
//  creation, hashed-identifier file naming, LCP-aware extension selection,
//  and the registry-lookup short-circuits. Uses real TPPBookContentMetadata
//  paths under a per-test account so the helper's static disk side-effects
//  are visible (and reversible).
//

import XCTest
@testable import Palace

final class BookFileManagerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var sut: BookFileManager!
    private var testAccountId: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        testAccountId = "bookfilemanager-test-\(UUID().uuidString)"
        sut = BookFileManager(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            fileManager: .default
        )
    }

    override func tearDownWithError() throws {
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: testAccountId) {
            try? FileManager.default.removeItem(at: dir)
        }
        registry = nil
        sut = nil
        testAccountId = nil
        try super.tearDownWithError()
    }

    // MARK: - pathExtension

    func testPathExtension_defaultsToEpub_forNilOrNonLCPBooks() {
        // The path extension drives where the downloaded artefact lands on
        // disk and which Reader stack opens it. The non-LCP fallback for
        // both nil-input and regular epub books MUST be "epub" — anything
        // else and the wrong reader gets invoked + the file is unreadable.
        XCTAssertEqual(sut.pathExtension(for: nil), "epub", "pathExtension must fall through to .epub when no book is provided (registry-loading + utility paths hit this).")

        let regularBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        XCTAssertEqual(sut.pathExtension(for: regularBook), "epub", "Non-LCP books must resolve to the .epub extension.")

        let alsoEpub = TPPBookMocker.mockBook(identifier: "alt-id", title: "Different Title", distributorType: .EpubZip)
        XCTAssertEqual(sut.pathExtension(for: alsoEpub), "epub", "Different epub books must all use the same extension — extension is content-type-driven, not book-instance-driven.")
    }

    // MARK: - contentDirectoryURL

    func testContentDirectoryURL_createsDirectoryOnFirstCall() throws {
        let url = try XCTUnwrap(sut.contentDirectoryURL(testAccountId), "Helper must produce a URL for a valid account.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "First call must create the content directory on disk.")
        XCTAssertTrue(url.path.hasSuffix("/content"), "Returned URL must point at the per-account `content` subdirectory.")
    }

    func testContentDirectoryURL_idempotent_reusesExistingDirectory() throws {
        let first  = try XCTUnwrap(sut.contentDirectoryURL(testAccountId))
        let second = try XCTUnwrap(sut.contentDirectoryURL(testAccountId))
        // Compare via `.path` (not URL equality) — Foundation adds a trailing
        // slash once the directory exists on disk, so the two URL strings
        // differ by `/` only despite resolving to the same location.
        XCTAssertEqual(first.path, second.path, "Repeated calls for the same account must resolve to the same directory — the path is shared, not per-call.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "Second call must not delete or recreate the directory destructively.")
    }

    func testContentDirectoryURL_distinctAccounts_distinctDirectories() throws {
        let other = "bookfilemanager-test-other-\(UUID().uuidString)"
        defer {
            if let dir = TPPBookContentMetadataFilesHelper.directory(for: other) {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        let mine  = try XCTUnwrap(sut.contentDirectoryURL(testAccountId))
        let theirs = try XCTUnwrap(sut.contentDirectoryURL(other))
        XCTAssertNotEqual(mine.path, theirs.path, "Two distinct accounts must resolve to two distinct directories — books from one account must never co-mingle with another's.")
    }

    // MARK: - fileUrl(for: TPPBook, account:)

    func testFileUrl_forBook_buildsHashedFileNameWithEpubExtension() throws {
        let book = TPPBookMocker.mockBook(identifier: "moby-dick-1851", title: "Moby Dick", distributorType: .EpubZip)

        let url = try XCTUnwrap(sut.fileUrl(for: book, account: testAccountId))

        XCTAssertEqual(url.pathExtension, "epub", "Non-LCP book must produce a .epub URL.")
        let expectedHash = "moby-dick-1851".sha256()
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, expectedHash, "Filename stem must be the SHA-256 of the book identifier — leaks the same id to the same path on every call.")
        XCTAssertTrue(url.path.contains("/content/"), "URL must sit inside the per-account `content` directory.")
    }

    // MARK: - fileUrl(for: identifier, account:)

    func testFileUrl_byIdentifier_returnsUrlWhenBookInRegistry() throws {
        let book = TPPBookMocker.mockBook(identifier: "registered-id", title: "X", distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)

        let url = try XCTUnwrap(sut.fileUrl(for: "registered-id", account: testAccountId))

        XCTAssertEqual(url.pathExtension, "epub")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "registered-id".sha256())
    }

    func testFileUrl_byIdentifier_returnsNilWhenBookNotInRegistry() {
        // Registry empty for "unknown-id" — assert the precondition AND that
        // the call doesn't accidentally register the book as a side-effect
        // (a regression we explicitly want to catch — file-URL lookup must
        // be a pure read, not a write).
        XCTAssertNil(registry.book(forIdentifier: "unknown-id"),
                     "Precondition: registry has no entry for 'unknown-id'")
        let url = sut.fileUrl(for: "unknown-id", account: testAccountId)
        XCTAssertNil(url,
                     "Unknown identifier must short-circuit to nil — never invent a file path for a book the registry doesn't know about.")
        XCTAssertNil(registry.book(forIdentifier: "unknown-id"),
                     "Postcondition: fileUrl(for:account:) must not auto-register the lookup — pure read, no side-effect")
    }

    // MARK: - fileUrl(for:account:) and fileUrl(for: TPPBook, account:) agree

    func testFileUrl_byIdentifier_andByBook_returnSameUrlForSameAccount() throws {
        let book = TPPBookMocker.mockBook(identifier: "consistency-id", title: "Consistency Probe", distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)

        let viaIdentifier = try XCTUnwrap(sut.fileUrl(for: "consistency-id", account: testAccountId))
        let viaBook       = try XCTUnwrap(sut.fileUrl(for: book, account: testAccountId))

        XCTAssertEqual(viaIdentifier, viaBook, "The two fileUrl flavors must agree — registry-lookup is just a convenience over the book-direct path; they cannot diverge.")
    }
}

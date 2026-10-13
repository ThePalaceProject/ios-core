//  LCPPDFDiskExtractTests.swift
//
//  PP-4454: an extract that crashed mid-write on a large LCP PDF left a partial
//  file, and `cachedURL` checked only that the file existed, so the next open
//  handed it to PDFKit ("Unable to load PDF file."). Pins the cache validation
//  in `LCPPDFDiskExtract.cachedURL`: a minimum size, a `%PDF-` header, and
//  deletion of a file that fails either check.

#if LCP

import XCTest
import CryptoKit
@testable import Palace

@MainActor
final class LCPPDFDiskExtractTests: XCTestCase {

    private let testAccountID = "lcp-pdf-disk-extract-test-account"
    private let bookIdentifier = "urn:isbn:9780000000000"

    /// Returns the file URL `LCPPDFDiskExtract.cachedURL` will probe.
    /// Re-derives the same path from the public account-directory
    /// helper so a refactor of the production filename strategy is
    /// caught by the test (the production constant + the test
    /// constant diverging).
    private func extractURL(forBookId id: String, account: String) -> URL? {
        guard let accountDir = TPPBookContentMetadataFilesHelper.directory(for: account) else {
            return nil
        }
        // Mirrors the production SHA-256 keying — kept verbatim so
        // a mismatch is obvious if either side changes hashing.
        let digest = SHA256.hash(data: Data(id.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        return accountDir
            .appendingPathComponent("registry")
            .appendingPathComponent("lcp-pdf-extracts")
            .appendingPathComponent("\(hashed).pdf")
    }

    override func setUp() async throws {
        try await super.setUp()
        // Fresh slate per test so prior fixtures don't poison cache hits.
        if let url = extractURL(forBookId: bookIdentifier, account: testAccountID),
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    override func tearDown() async throws {
        if let url = extractURL(forBookId: bookIdentifier, account: testAccountID),
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    // MARK: - Cache hit (valid file)

    func testCachedURL_validPDFHeaderAndSize_returnsURL() throws {
        let expectedURL = try XCTUnwrap(extractURL(forBookId: bookIdentifier, account: testAccountID))
        try FileManager.default.createDirectory(
            at: expectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 2KB valid PDF: `%PDF-1.4` header + filler. Real PDF parses
        // by xref, which PDFKit handles at reader time; we only need
        // the cache validator to recognize the magic header.
        var data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]) // %PDF-1.4
        data.append(Data(repeating: 0x20, count: 2_048))
        try data.write(to: expectedURL)

        let resolved = LCPPDFDiskExtract.cachedURL(
            bookIdentifier: bookIdentifier,
            account: testAccountID
        )

        XCTAssertEqual(resolved, expectedURL, "valid PDF should be returned as-is")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedURL.path),
            "valid file must NOT be deleted by the validator"
        )
    }

    // MARK: - Corrupt cache: too small

    func testCachedURL_undersizedFile_returnsNilAndDeletesFile() throws {
        let expectedURL = try XCTUnwrap(extractURL(forBookId: bookIdentifier, account: testAccountID))
        try FileManager.default.createDirectory(
            at: expectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 5 bytes — below the 1KB sanity floor. Mimics a crashed
        // partial write that only flushed the magic header.
        let stub = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        try stub.write(to: expectedURL)

        let resolved = LCPPDFDiskExtract.cachedURL(
            bookIdentifier: bookIdentifier,
            account: testAccountID
        )

        XCTAssertNil(resolved, "undersized fixture must be rejected")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedURL.path),
            "rejected fixture must be deleted so re-extract starts clean"
        )
    }

    // MARK: - Corrupt cache: wrong header

    func testCachedURL_wrongMagicBytes_returnsNilAndDeletesFile() throws {
        let expectedURL = try XCTUnwrap(extractURL(forBookId: bookIdentifier, account: testAccountID))
        try FileManager.default.createDirectory(
            at: expectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 4KB but starts with ZIP magic (PK\x03\x04) — simulates the
        // raw LCP container leaking through instead of the decrypted
        // PDF. PDFKit would crash trying to parse this.
        var data = Data([0x50, 0x4B, 0x03, 0x04]) // PK\x03\x04
        data.append(Data(repeating: 0xFF, count: 4_096))
        try data.write(to: expectedURL)

        let resolved = LCPPDFDiskExtract.cachedURL(
            bookIdentifier: bookIdentifier,
            account: testAccountID
        )

        XCTAssertNil(resolved, "non-PDF header must be rejected")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedURL.path),
            "corrupt fixture must be deleted"
        )
    }

    // MARK: - Negative paths

    func testCachedURL_noFileOnDisk_returnsNil() {
        // setUp deleted any pre-existing fixture; no write here.
        let resolved = LCPPDFDiskExtract.cachedURL(
            bookIdentifier: bookIdentifier,
            account: testAccountID
        )
        XCTAssertNil(resolved, "missing file must return nil, not throw")
    }

    func testCachedURL_partialWriteWithGoodHeader_stillRejected() throws {
        // Edge case: a partial write that DID flush the %PDF- header
        // but truncated before the file became real (well under 1KB).
        // Without the size floor we'd happily return this and PDFKit
        // would error at open. With the floor, we reject and re-extract.
        let expectedURL = try XCTUnwrap(extractURL(forBookId: bookIdentifier, account: testAccountID))
        try FileManager.default.createDirectory(
            at: expectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        data.append(Data(repeating: 0x20, count: 512)) // 517 bytes total — header present, size insufficient
        try data.write(to: expectedURL)

        let resolved = LCPPDFDiskExtract.cachedURL(
            bookIdentifier: bookIdentifier,
            account: testAccountID
        )

        XCTAssertNil(resolved, "valid header alone is not enough — size floor must also pass")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedURL.path),
            "rejected fixture must be deleted regardless of which check failed"
        )
    }

    // MARK: - Writing the extract

    private struct ReadFailure: Error {}

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lcp-pdf-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func bytes(_ range: Range<UInt64>, of source: Data) -> Data {
        source.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testWriteExtract_AllChunksRead_PublishesTheCompleteFileOnly() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")
        let source = Data((0..<10).map { UInt8($0) })

        let url = try await LCPPDFDiskExtract.writeExtract(
            to: dest, totalBytes: 10, chunkSize: 4,
            read: { range -> Result<Data, ReadFailure> in .success(self.bytes(range, of: source)) },
            onChunk: { _ in })

        XCTAssertEqual(url, dest)
        XCTAssertEqual(try Data(contentsOf: dest), source)
        XCTAssertEqual(try contents(of: dir), ["book.pdf"], "No partial file may be left beside the extract")
    }

    /// `cachedURL` accepts any file at the cache path with a PDF header, so a
    /// reopen during an extract must never find a partly written file there.
    func testWriteExtract_WhileWriting_CachePathHoldsNoPartialFile() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")
        let source = Data(repeating: 0x25, count: 12)
        var visibleMidWrite = false

        _ = try await LCPPDFDiskExtract.writeExtract(
            to: dest, totalBytes: 12, chunkSize: 4,
            read: { range -> Result<Data, ReadFailure> in
                if range.lowerBound > 0, FileManager.default.fileExists(atPath: dest.path) {
                    visibleMidWrite = true
                }
                return .success(self.bytes(range, of: source))
            },
            onChunk: { _ in })

        XCTAssertFalse(visibleMidWrite)
    }

    func testWriteExtract_ReadFails_LeavesNoFiles() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")

        do {
            _ = try await LCPPDFDiskExtract.writeExtract(
                to: dest, totalBytes: 12, chunkSize: 4,
                read: { range -> Result<Data, ReadFailure> in
                    range.lowerBound == 0 ? .success(Data(count: 4)) : .failure(ReadFailure())
                },
                onChunk: { _ in })
            XCTFail("A failed read must fail the extract")
        } catch {
            XCTAssertEqual(try contents(of: dir), [])
        }
    }

    /// A back-out cancels the extract: it stops reading, reports no further
    /// progress and leaves nothing on disk.
    func testWriteExtract_Cancelled_StopsAndLeavesNoFiles() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")
        var reads = 0
        var reported = 0

        let task = Task { @MainActor in
            try await LCPPDFDiskExtract.writeExtract(
                to: dest, totalBytes: 16, chunkSize: 4,
                read: { _ -> Result<Data, ReadFailure> in
                    reads += 1
                    if reads == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return .success(Data(count: 4))
                },
                onChunk: { reported += $0 })
        }
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reads, 2, "No chunk may be read after cancellation")
        XCTAssertEqual(reported, 4, "The chunk read as cancellation arrived must not count as progress")
        XCTAssertEqual(try contents(of: dir), [])
    }

    func testWriteExtract_EarlierExtractPresent_IsReplaced() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")
        try Data(repeating: 0xFF, count: 20).write(to: dest)
        let source = Data(repeating: 0x01, count: 8)

        _ = try await LCPPDFDiskExtract.writeExtract(
            to: dest, totalBytes: 8, chunkSize: 4,
            read: { range -> Result<Data, ReadFailure> in .success(self.bytes(range, of: source)) },
            onChunk: { _ in })

        XCTAssertEqual(try Data(contentsOf: dest), source)
        XCTAssertEqual(try contents(of: dir), ["book.pdf"])
    }

    /// An app kill mid-extract leaves a decrypted partial file; the next extract
    /// of that book removes it, and leaves other books' partials alone.
    func testWriteExtract_OrphanedPartialsForThisBook_AreRemoved() async throws {
        let dir = try makeScratchDirectory()
        let dest = dir.appendingPathComponent("book.pdf")
        let orphan = dir.appendingPathComponent("book-\(UUID().uuidString).partial")
        let otherBook = dir.appendingPathComponent("other-\(UUID().uuidString).partial")
        try Data(count: 4).write(to: orphan)
        try Data(count: 4).write(to: otherBook)
        let source = Data(repeating: 0x02, count: 8)

        _ = try await LCPPDFDiskExtract.writeExtract(
            to: dest, totalBytes: 8, chunkSize: 4,
            read: { range -> Result<Data, ReadFailure> in .success(self.bytes(range, of: source)) },
            onChunk: { _ in })

        XCTAssertEqual(try contents(of: dir), ["book.pdf", otherBook.lastPathComponent].sorted())
        XCTAssertEqual(try Data(contentsOf: dest), source)
    }

    /// Returning the loan drops the extract and any partial file an
    /// interrupted extract left for that book, but not other books' files.
    func testInvalidate_RemovesTheBooksPartialFilesOnly() throws {
        let expectedURL = try XCTUnwrap(extractURL(forBookId: bookIdentifier, account: testAccountID))
        let dir = expectedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = expectedURL.deletingPathExtension().lastPathComponent
        let partial = dir.appendingPathComponent("\(stem)-\(UUID().uuidString).partial")
        let otherPartial = dir.appendingPathComponent("other-\(UUID().uuidString).partial")
        try Data(count: 4).write(to: expectedURL)
        try Data(count: 4).write(to: partial)
        try Data(count: 4).write(to: otherPartial)
        addTeardownBlock { try? FileManager.default.removeItem(at: otherPartial) }

        LCPPDFDiskExtract.invalidate(bookIdentifier: bookIdentifier, account: testAccountID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherPartial.path))
    }
}

#endif

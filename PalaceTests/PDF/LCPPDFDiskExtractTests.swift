//
//  LCPPDFDiskExtractTests.swift
//  PalaceTests
//
//  Covers the cache-correctness guardrail in `LCPPDFDiskExtract.cachedURL`.
//  Real-world failure that motivated these tests (PP-4454): the
//  `stream(consume:)`-based extract crashed mid-write on a large
//  Marketplace LCP PDF, leaving a partial file. The original `cachedURL`
//  only checked `FileManager.default.fileExists` — so the next open
//  handed the partial garbage straight to PDFKit and surfaced "Unable
//  to load PDF file." The validation rules (size + `%PDF-` header) +
//  delete-on-fail ARE the fix; this test class locks them in so a
//  refactor can't accidentally regress to "trust the file exists."
//
//  Each test surveys mutations on the production code:
//   - flip the size threshold → testMissesUnderSizeThreshold breaks
//   - drop the magic-byte check → testRejectsNonPDFHeader breaks
//   - skip the on-fail removeItem → assertion that file is GONE breaks
//

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
}

#endif

//
//  DownloadIntegrityTests.swift
//  PalaceTests
//
//  Deep mutation-killing coverage for the *integrity* leg of the
//  download lifecycle: file existence + non-zero size validation, hash
//  comparison against the server-declared content hash (where the
//  contract is currently size-based as documented in
//  BackgroundDownloadHandler.validateDownloadedFile), and the audiobook
//  manifest contract — when an audiobook manifest is part of the
//  payload, the registry must still be authoritative for the loan state
//  and the underlying bytes must round-trip without corruption.
//
//  These tests stay hermetic: per-test temp dir, no network, no Adobe
//  RMSDK. They drive BackgroundDownloadHandler.validateDownloadedFile /
//  replaceBook / moveFile so we can pin the contract a downstream hash
//  check would extend, and surface seam gaps for fields that aren't yet
//  threaded through (commented below).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import CryptoKit
@testable import Palace
import PalaceBookModel

private let integrityTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    return URLSession(configuration: config)
}()

@MainActor
final class DownloadIntegrityTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var mockDelegate: MockBackgroundDownloadDelegate!
    private var handler: BackgroundDownloadHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        HTTPStubURLProtocol.reset()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DownloadIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = TPPBookRegistryMock()
        mockDelegate = MockBackgroundDownloadDelegate(bookRegistry: registry)
        handler = BackgroundDownloadHandler(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        HTTPStubURLProtocol.reset()
        handler = nil
        mockDelegate = nil
        registry = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func inertTask() -> URLSessionDownloadTask {
        integrityTestSession.downloadTask(with: URL(string: "https://example.com/x")!)
    }

    private func makeBook(_ id: String = UUID().uuidString, type: DistributorType = .EpubZip) -> TPPBook {
        let book = TPPBookMocker.mockBook(identifier: id, title: "T-\(id)", distributorType: type)
        registry.addBook(book, state: .downloading)
        return book
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Existence + size validation (mutation kill on the > 0 guard)

    /// Size > 0 is the gate. Any mutation that flips to `>= 0` (silent
    /// accept of empty payloads) is killed by this test.
    func testValidate_nonEmptyFile_passes() throws {
        let book = makeBook()
        let file = tempDir.appendingPathComponent("ok.epub")
        try Data("non-empty".utf8).write(to: file)

        XCTAssertTrue(handler.validateDownloadedFile(at: file, for: book))
    }

    func testValidate_zeroByteFile_fails() throws {
        let book = makeBook()
        let file = tempDir.appendingPathComponent("zero.epub")
        FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: nil)

        XCTAssertFalse(handler.validateDownloadedFile(at: file, for: book),
                       "Zero-byte payload must fail validation — never claim success")
    }

    func testValidate_missingFile_fails() {
        let book = makeBook()
        let missing = tempDir.appendingPathComponent("never-here.epub")
        XCTAssertFalse(handler.validateDownloadedFile(at: missing, for: book),
                       "Missing file at destination must fail validation")
    }

    // MARK: - Hash matching (size+hash contract pinned for downstream extension)

    /// Round-trips a payload through `replaceBook` and verifies the on-disk
    /// SHA-256 matches the source SHA-256. This pins the byte-for-byte
    /// integrity contract: any mutation that, e.g., off-by-ones a buffer
    /// length during move/replace would diverge the hashes.
    func testReplaceBook_byteForByteHashMatch() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("book.epub")
        mockDelegate.fileUrls[book.identifier] = dest

        // Build a deterministic payload with structure (not all-zero) so a
        // truncation or byte-shift would change the hash.
        var bytes = Data(count: 8_192)
        for i in 0..<bytes.count { bytes[i] = UInt8(i & 0xFF) }
        let source = tempDir.appendingPathComponent("src.epub")
        try bytes.write(to: source)
        let expectedHash = sha256(bytes)

        XCTAssertTrue(handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(sha256(onDisk), expectedHash,
                       "On-disk bytes must hash-match the source byte-for-byte")
        XCTAssertEqual(onDisk.count, bytes.count,
                       "On-disk size must equal source size (no truncation, no padding)")
    }

    /// If a downstream caller validated against a *declared* hash and the
    /// content drifted (corruption), the destination would need to be
    /// removed. We pin the contract: when `validateDownloadedFile` returns
    /// false post-move, the registry state must NOT be flipped to
    /// .downloadSuccessful. This is the seam an actual hash check plugs
    /// into; production currently only size-validates, so we use a 0-byte
    /// source to drive the negative branch.
    func testReplaceBook_validationFailureLeavesRegistryUnchanged() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("book.epub")
        mockDelegate.fileUrls[book.identifier] = dest

        let corrupt = tempDir.appendingPathComponent("corrupt.epub")
        try Data().write(to: corrupt)  // empty triggers the size > 0 guard

        let result = handler.replaceBook(book, withFileAtURL: corrupt, forDownloadTask: inertTask())
        XCTAssertFalse(result, "Validation-fail post-replace must surface as false")
        XCTAssertNotEqual(registry.state(for: book.identifier), .downloadSuccessful,
                          "Validation failure must NOT advance registry to .downloadSuccessful")
    }

    /// Seam-gap pin: production `validateDownloadedFile` currently only
    /// checks existence + size > 0. The contract this test surfaces is
    /// that the *same* file can be validated repeatedly and the answer
    /// stays stable — a mutation that, e.g., consumed the file on first
    /// read would break re-validation after replays/recovery.
    func testValidate_repeatedCallsAreIdempotent() throws {
        let book = makeBook()
        let file = tempDir.appendingPathComponent("stable.epub")
        try Data("stable-bytes".utf8).write(to: file)

        XCTAssertTrue(handler.validateDownloadedFile(at: file, for: book))
        XCTAssertTrue(handler.validateDownloadedFile(at: file, for: book),
                      "Validate must be idempotent — no side-effects on the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Validate must not consume / delete the file it checked")
    }

    /// Hash-drift surrogate: write A, replace with B (different bytes,
    /// same length). The hash AFTER replace must match B, not A. A
    /// mutation that "skips the replace if sizes are equal" would be
    /// caught here.
    func testReplaceBook_sameSizeDifferentBytes_writesNewBytes() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("book.epub")
        let bytesA = Data(repeating: 0xAA, count: 4_096)
        try bytesA.write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let bytesB = Data(repeating: 0xBB, count: 4_096)
        let source = tempDir.appendingPathComponent("src.epub")
        try bytesB.write(to: source)

        XCTAssertTrue(handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(sha256(onDisk), sha256(bytesB),
                       "After replace, hash must reflect the new bytes — even if size is unchanged")
        XCTAssertNotEqual(sha256(onDisk), sha256(bytesA),
                          "Pre-replace hash must NOT survive the replace operation")
    }

    // MARK: - Audiobook manifest contract pin (registry stays authoritative)

    /// Audiobook payloads route through the same replaceBook seam.
    /// The contract: even for audiobook-typed books, the bytes must
    /// land at the destination URL exactly as provided AND the registry
    /// flip to .downloadSuccessful must follow validation success.
    /// (LCP audiobooks defer the registry flip; see other tests.) For
    /// non-LCP audiobooks (OpenAccess / Findaway), the registry update
    /// is unconditional on success — pin that branch.
    func testReplaceBook_openAccessAudiobookManifest_writesAndMarksSuccessful() throws {
        let book = makeBook("audio", type: .OpenAccessAudiobook)
        let dest = tempDir.appendingPathComponent("audio.json")
        mockDelegate.fileUrls[book.identifier] = dest

        let manifest = #"{"@context":"https://readium.org/webpub-manifest/context.jsonld","metadata":{"title":"X"}}"#
        let manifestBytes = Data(manifest.utf8)
        let source = tempDir.appendingPathComponent("manifest.json")
        try manifestBytes.write(to: source)

        XCTAssertTrue(handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk, manifestBytes,
                       "Audiobook manifest bytes must round-trip without modification")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful,
                       "Non-LCP audiobook manifest must advance registry to .downloadSuccessful")
    }

    /// Audiobook manifest re-fetch contract pin (PP-4178 / token-expiry):
    /// when the manifest payload is replaced (i.e. user reopens after token
    /// refresh and the manifest is re-downloaded), the destination URL is
    /// the same and the new bytes must atomically replace the old ones —
    /// never end up with two manifests at adjacent paths.
    func testReplaceBook_manifestReFetch_overwritesOldManifest() throws {
        let book = makeBook("audio-refetch", type: .OpenAccessAudiobook)
        let dest = tempDir.appendingPathComponent("manifest.json")
        mockDelegate.fileUrls[book.identifier] = dest

        let v1 = Data(#"{"version":1}"#.utf8)
        try v1.write(to: dest)

        let v2 = Data(#"{"version":2,"url":"https://refetched"}"#.utf8)
        let source = tempDir.appendingPathComponent("v2.json")
        try v2.write(to: source)

        XCTAssertTrue(handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk, v2,
                       "Re-fetched manifest must overwrite the previous version on disk")
        let parent = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(parent.filter { $0.hasSuffix(".json") }.count, 1,
                       "Re-fetch must result in exactly one manifest at the destination — no stragglers")
    }

    // MARK: - moveFile integrity (no-existing-dest path)

    /// moveFile (no existing dest) is the "first download" path. Pin the
    /// integrity: the destination ends up with exactly the source bytes.
    /// Mutation that, e.g., wrote a placeholder before move would be caught
    /// by the byte-equal assertion.
    func testMoveFile_firstDownload_landsExactBytes() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("first.epub")
        mockDelegate.fileUrls[book.identifier] = dest

        var bytes = Data(count: 1_024)
        for i in 0..<bytes.count { bytes[i] = UInt8((i * 7) & 0xFF) }
        let source = tempDir.appendingPathComponent("first-src.epub")
        try bytes.write(to: source)

        XCTAssertTrue(handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: inertTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(sha256(onDisk), sha256(bytes),
                       "First-download move must produce a byte-for-byte copy at the destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "Move semantics: source must be consumed, not copied")
    }
}

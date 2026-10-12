//
//  LCPTrackFileWriterTests.swift
//  PalaceTests
//
//  Pins the bounded-read contract for writing a decrypted LCP track to disk
//  (PP-5347: whole-track reads ran 3.3.1 out of memory).
//

#if LCP

import XCTest
@preconcurrency import ReadiumShared
@testable import Palace

final class LCPTrackFileWriterTests: XCTestCase {

    private let chunkSize: UInt64 = 4096
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCPTrackFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var destination: URL { directory.appendingPathComponent("track.mp3") }

    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func directoryContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Bounded reads

    /// A multi-chunk track is read only through ranged reads no larger than the chunk size.
    func testWrite_LargeTrack_ReadsInBoundedRangesAndWritesAllBytes() async throws {
        let input = bytes(Int(chunkSize) * 10 + 123)
        let resource = FakeTrackResource(data: input)

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        let ranges = resource.requestedRanges
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertFalse(ranges.contains { $0 == nil }, "A nil range reads the whole track into memory")
        XCTAssertLessThanOrEqual(ranges.compactMap { $0?.count }.max() ?? 0, Int(chunkSize))
        XCTAssertEqual(ranges.count, 11)
        XCTAssertEqual(try Data(contentsOf: destination), input)
    }

    /// Ranges are contiguous and start at zero, so no byte is skipped or repeated.
    func testWrite_LargeTrack_RequestsContiguousRangesFromZero() async throws {
        let input = bytes(Int(chunkSize) * 2 + 1)
        let resource = FakeTrackResource(data: input)

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        XCTAssertEqual(resource.requestedRanges, [
            0 ..< chunkSize,
            chunkSize ..< 2 * chunkSize,
            2 * chunkSize ..< 3 * chunkSize,
        ])
    }

    /// A track that is an exact multiple of the chunk size needs one empty read to find its end.
    func testWrite_ExactMultipleOfChunkSize_WritesAllBytesAndStopsAfterEmptyRead() async throws {
        let input = bytes(Int(chunkSize) * 3)
        let resource = FakeTrackResource(data: input)

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        XCTAssertEqual(try Data(contentsOf: destination), input)
        XCTAssertEqual(resource.requestedRanges.count, 4)
    }

    /// An empty track still produces a file: the toolkit treats an existing destination as decrypted.
    func testWrite_EmptyTrack_CreatesEmptyDestinationFile() async throws {
        let resource = FakeTrackResource(data: Data())

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data())
        XCTAssertEqual(try directoryContents(), ["track.mp3"])
    }

    /// A destination left by an earlier attempt is replaced, matching the old atomic write.
    func testWrite_DestinationAlreadyExists_ReplacesItsContents() async throws {
        try Data(repeating: 0xEE, count: 50_000).write(to: destination)
        let input = bytes(Int(chunkSize) + 10)

        try await LCPTrackFileWriter.write(FakeTrackResource(data: input), to: destination, chunkSize: chunkSize)

        XCTAssertEqual(try Data(contentsOf: destination), input)
        XCTAssertEqual(try directoryContents(), ["track.mp3"])
    }

    // MARK: - Production defaults

    /// The default chunk size bounds each read at 1 MiB, the limit the PP-5347 fix depends on.
    func testWrite_DefaultChunkSize_BoundsEachReadAtOneMebibyte() async throws {
        let oneMiB = 1_048_576
        let input = bytes(oneMiB * 2 + 5)
        let resource = FakeTrackResource(data: input)

        try await LCPTrackFileWriter.write(resource, to: destination)

        XCTAssertEqual(resource.requestedRanges.map { $0?.count }, [oneMiB, oneMiB, oneMiB])
        XCTAssertEqual(try Data(contentsOf: destination), input)
    }

    /// The decrypt path the toolkit calls writes the track through bounded reads, not one whole read.
    func testDecryptWithPublication_WritesTrackThroughBoundedReads() async throws {
        let oneMiB = 1_048_576
        let input = bytes(oneMiB + 7)
        let resource = FakeTrackResource(data: input)
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Track")),
            container: SingleResourceContainer(resource: resource, at: AnyURL(path: "track.mp3")!)
        )
        let destination = self.destination

        // Joins the completion directly, which fires exactly once, instead of polling a deadline.
        let error: Error? = await withCheckedContinuation { continuation in
            LCPAudiobooks.decryptWithPublication(publication, url: URL(string: "track.mp3")!, to: destination) { error in
                continuation.resume(returning: error)
            }
        }

        XCTAssertNil(error)
        XCTAssertFalse(resource.requestedRanges.contains { $0 == nil }, "A nil range reads the whole track into memory")
        XCTAssertEqual(resource.requestedRanges.count, 2)
        XCTAssertEqual(try Data(contentsOf: destination), input)
    }

    // MARK: - Errors

    /// A read error mid-track is rethrown unchanged and leaves neither a destination nor a partial file.
    func testWrite_ReadFailsMidTrack_RethrowsReadErrorAndRemovesPartialFile() async throws {
        let input = bytes(Int(chunkSize) * 5)
        let resource = FakeTrackResource(data: input, failAtOffset: 2 * chunkSize)

        do {
            try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)
            XCTFail("Expected the read error to propagate")
        } catch let ReadError.decoding(inner) {
            XCTAssertEqual(inner as? FakeTrackError, .decryptFailed)
        } catch {
            XCTFail("Expected ReadError.decoding, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try directoryContents(), [])
        XCTAssertEqual(resource.requestedRanges.count, 3, "Reading stops at the first failure")
    }

    /// A failure while writing (missing parent directory) is thrown, not reported as success.
    func testWrite_DestinationDirectoryMissing_Throws() async throws {
        let unreachable = directory.appendingPathComponent("missing/track.mp3")

        do {
            try await LCPTrackFileWriter.write(FakeTrackResource(data: bytes(10)), to: unreachable, chunkSize: chunkSize)
            XCTFail("Expected a file-system error")
        } catch {
            XCTAssertFalse(error is ReadError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreachable.path))
    }

    // MARK: - Unknown length fallback

    /// Without a known length an LCP CBC resource cannot serve ranged reads, so the whole-read path is kept.
    func testWrite_LengthUnknown_FallsBackToWholeRead() async throws {
        let input = bytes(Int(chunkSize) * 2)
        let resource = FakeTrackResource(data: input, lengthResult: .success(nil))

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        XCTAssertEqual(resource.requestedRanges, [nil])
        XCTAssertEqual(try Data(contentsOf: destination), input)
    }

    /// A failed length lookup also keeps the whole-read path, which carries its own fallback in Readium.
    func testWrite_LengthLookupFails_FallsBackToWholeRead() async throws {
        let input = bytes(100)
        let resource = FakeTrackResource(data: input, lengthResult: .failure(.decoding(FakeTrackError.lengthUnavailable)))

        try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)

        XCTAssertEqual(resource.requestedRanges, [nil])
        XCTAssertEqual(try Data(contentsOf: destination), input)
    }

    /// The whole-read fallback still rethrows the resource's read error.
    func testWrite_LengthUnknownAndReadFails_RethrowsAndWritesNothing() async throws {
        let resource = FakeTrackResource(data: bytes(10), lengthResult: .success(nil), failAtOffset: 0)

        do {
            try await LCPTrackFileWriter.write(resource, to: destination, chunkSize: chunkSize)
            XCTFail("Expected the read error to propagate")
        } catch let ReadError.decoding(inner) {
            XCTAssertEqual(inner as? FakeTrackError, .decryptFailed)
        }
        XCTAssertEqual(try directoryContents(), [])
    }
}

// MARK: - Fake resource

private enum FakeTrackError: Error, Equatable {
    case decryptFailed
    case lengthUnavailable
    case tooManyReads
}

/// In-memory `Resource` that records every requested range and can fail from a given offset.
private final class FakeTrackResource: Resource, @unchecked Sendable {
    let sourceURL: AbsoluteURL? = nil
    private let data: Data
    private let lengthResult: ReadResult<UInt64?>?
    private let failAtOffset: UInt64?
    private let lock = NSLock()
    private var ranges: [Range<UInt64>?] = []

    init(data: Data, lengthResult: ReadResult<UInt64?>? = nil, failAtOffset: UInt64? = nil) {
        self.data = data
        self.lengthResult = lengthResult
        self.failAtOffset = failAtOffset
    }

    var requestedRanges: [Range<UInt64>?] {
        lock.withLock { ranges }
    }

    func properties() async -> ReadResult<ResourceProperties> {
        .success(ResourceProperties())
    }

    func estimatedLength() async -> ReadResult<UInt64?> {
        lengthResult ?? .success(UInt64(data.count))
    }

    func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        let callCount = lock.withLock { ranges.append(range); return ranges.count }
        // A reader that never detects the end would otherwise loop forever.
        guard callCount <= 1000 else {
            return .failure(.decoding(FakeTrackError.tooManyReads))
        }

        let total = UInt64(data.count)
        let requested = range ?? 0 ..< total
        let clamped = min(requested.lowerBound, total) ..< min(requested.upperBound, total)
        if let failAtOffset, clamped.upperBound > failAtOffset || range == nil {
            return .failure(.decoding(FakeTrackError.decryptFailed))
        }
        consume(data.subdata(in: Int(clamped.lowerBound) ..< Int(clamped.upperBound)))
        return .success(())
    }
}

#endif

//  ImageCacheWriteOnceTests.swift
//
//  A cover is encoded and written once: aliases share the stored file, a key
//  that is already on disk is not encoded again, and a memory warning does not
//  drop queued writes (PP-5499).

import XCTest
import UIKit
@testable import Palace

final class ImageCacheWriteOnceTests: XCTestCase {

    private var cache: ImageCache?
    private var encodeCount: LockIsolated<Int>!

    override func setUp() {
        super.setUp()
        encodeCount = LockIsolated(0)
        let counter = encodeCount!
        cache = ImageCache._makeIsolatedForTesting(
            cacheName: "ImageCacheWriteOnceTests-\(UUID().uuidString)",
            encode: { image, quality in
                counter.withValue { $0 += 1 }
                return image.jpegData(compressionQuality: quality)
            }
        )
    }

    override func tearDown() {
        cache?.processingQueue.cancelAllOperations()
        cache?.processingQueue.isSuspended = false
        cache.map(Self.drain)
        cache?.clear()
        cache = nil
        super.tearDown()
    }

    /// One decoded cover stored under its sized key and the bare identifier
    /// is one encode and one file, not two.
    func testSet_sameImageUnderTwoKeys_encodesOnceAndSharesOneFile() throws {
        let cache = try XCTUnwrap(cache)

        cache.set(Self.image(), for: ["book-1_300px", "book-1"], expiresIn: nil)
        Self.drain(cache)

        XCTAssertEqual(encodeCount.value, 1)
        let first = try Self.fileNumber(at: cache._diskURLForTesting(for: "book-1_300px"))
        let second = try Self.fileNumber(at: cache._diskURLForTesting(for: "book-1"))
        XCTAssertEqual(first, second, "the alias must name the same stored file")
    }

    func testSet_aliasKey_readsBackFromDiskAfterDecodedImagesAreEvicted() async throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Self.image(), for: ["book-2_thumbnail", "book-2"], expiresIn: nil)
        Self.drain(cache)
        cache.evictDecodedImages()

        let viaAlias = await cache.getAsync(for: "book-2")

        XCTAssertNotNil(viaAlias)
    }

    /// A sync that hands the cache covers it already has on disk encodes nothing.
    func testSet_whenEveryKeyIsAlreadyOnDisk_doesNotEncode() throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Self.image(), for: ["book-3", "book-3_thumbnail"], expiresIn: nil)
        Self.drain(cache)
        encodeCount.value = 0

        cache.set(Self.image(), for: "book-3", expiresIn: nil)
        cache.set(Self.image(), for: ["book-3", "book-3_thumbnail"], expiresIn: nil)
        Self.drain(cache)

        XCTAssertEqual(encodeCount.value, 0)
    }

    func testSet_whenOnlySomeKeysAreOnDisk_encodesOnceForTheMissingOnes() throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Self.image(), for: "book-4", expiresIn: nil)
        Self.drain(cache)
        encodeCount.value = 0

        cache.set(Self.image(), for: ["book-4_600px", "book-4"], expiresIn: nil)
        Self.drain(cache)

        XCTAssertEqual(encodeCount.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: "book-4_600px").path))
    }

    /// An expired file is a miss, so the cover is encoded and written again.
    func testSet_whenTheFileOnDiskHasExpired_encodesAgain() throws {
        let cache = try XCTUnwrap(cache)
        cache.set(Self.image(), for: "book-5", expiresIn: -60)
        Self.drain(cache)
        encodeCount.value = 0

        cache.set(Self.image(), for: "book-5", expiresIn: nil)
        Self.drain(cache)

        XCTAssertEqual(encodeCount.value, 1)
    }

    /// A memory warning drops decode work, not queued writes: a cover handed
    /// to the cache just before the warning is still on disk afterwards.
    func testMemoryWarning_withQueuedWrites_writesStillLand() throws {
        let cache = try XCTUnwrap(cache)
        let keys = (0..<5).map { "queued-write-\($0)" }
        cache.processingQueue.isSuspended = true
        for key in keys {
            cache.set(Self.image(), for: key, expiresIn: nil)
        }

        cache.handleMemoryWarning()
        cache.processingQueue.isSuspended = false
        Self.drain(cache)

        for key in keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: key).path),
                          "\(key) must be written despite the memory warning")
        }
    }

    /// Reads queued when the warning arrives are dropped, and each awaiting
    /// caller still resumes exactly once.
    @MainActor
    func testMemoryWarning_withQueuedGetAsync_eachCallResumesOnce() async throws {
        let cache = try XCTUnwrap(cache)
        cache.processingQueue.isSuspended = true
        let count = 20
        let resumed = LockIsolated<Int>(0)
        let fanOut = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<count {
                    group.addTask {
                        _ = await cache.getAsync(for: "queued-read-\(i)")
                        resumed.withValue { $0 += 1 }
                    }
                }
            }
        }
        cache.set(Self.image(), for: "queued-read-write", expiresIn: nil)
        await awaitConditionAsync(timeout: 30) { cache.processingQueue.operationCount >= count + 1 } // FLAKE-003-OK: hang guard below the execution-time allowance, not a timing assertion

        cache.handleMemoryWarning()
        cache.processingQueue.isSuspended = false

        await awaitConditionAsync(timeout: 30) { resumed.value == count } // FLAKE-003-OK: hang guard below the execution-time allowance, not a timing assertion
        XCTAssertEqual(resumed.value, count)
        if resumed.value == count { await fanOut.value }
        Self.drain(cache)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: "queued-read-write").path))
    }

    // MARK: - Helpers

    private static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
    }

    private static func fileNumber(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }

    /// Synchronous so async tests can call it: `waitUntilAllOperationsAreFinished`
    /// is unavailable from async contexts.
    private static func drain(_ cache: ImageCache) {
        cache.processingQueue.waitUntilAllOperationsAreFinished()
    }

}

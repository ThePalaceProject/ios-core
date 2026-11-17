//  ImageCacheCapacityTierTests.swift
//
//  `ImageCache.set` shrinks every stored cover to the device tier's
//  `maxDimension`. Detail (280 pt) and the audiobook player need about 840 and
//  1200 px on a 3x phone, so devices with memory to spare keep that size.

import XCTest
import UIKit
@testable import Palace

final class ImageCacheCapacityTierTests: XCTestCase {

    // MARK: - Tier boundaries

    func testLimits_underTwoGigabytes_keepsTheSmallestCap() {
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 1024).maxDimension, 200)
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 2047).maxDimension, 200)
    }

    func testLimits_twoToFourGigabytes_allowsListAndDetailSizes() {
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 2048).maxDimension, 600)
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 4095).maxDimension, 600)
    }

    func testLimits_fourGigabytesAndUp_allowsFullPlayerSize() {
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 4096).maxDimension, 1200)
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 12288).maxDimension, 1200)
    }

    /// The memory budget is what bounds the cache, so it must not grow with the
    /// larger images: bigger covers mean fewer cached covers, not more memory.
    func testLimits_memoryBudgetPerTier_isUnchanged() {
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 1024).memoryCostLimitMB, 15)
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 3072).memoryCostLimitMB, 25)
        XCTAssertEqual(ImageCache.limits(forDeviceMemoryMB: 8192).memoryCostLimitMB, 40)
    }

    // MARK: - Stored size

    func testSet_onHighMemoryDevice_storesCoverAtPlayerResolution() throws {
        let stored = try storedImage(deviceMemoryMB: 8192, sourceWidth: 1000, sourceHeight: 1500)

        XCTAssertEqual(stored.cgImage?.height, 1200)
        XCTAssertEqual(stored.cgImage?.width, 800)
    }

    func testSet_onMidMemoryDevice_storesCoverAtMidTierCap() throws {
        let stored = try storedImage(deviceMemoryMB: 3072, sourceWidth: 1000, sourceHeight: 1500)

        XCTAssertEqual(stored.cgImage?.height, 600)
    }

    func testSet_onLowMemoryDevice_stillShrinksToTwoHundred() throws {
        let stored = try storedImage(deviceMemoryMB: 1024, sourceWidth: 1000, sourceHeight: 1500)

        XCTAssertEqual(stored.cgImage?.height, 200)
    }

    func testSet_imageSmallerThanCap_isNotUpscaled() throws {
        let stored = try storedImage(deviceMemoryMB: 8192, sourceWidth: 300, sourceHeight: 450)

        XCTAssertEqual(stored.cgImage?.height, 450)
    }

    // MARK: - Helpers

    private func storedImage(deviceMemoryMB: UInt64, sourceWidth: Int, sourceHeight: Int) throws -> UIImage {
        let cache = ImageCache._makeIsolatedForTesting(deviceMemoryMB: deviceMemoryMB)
        let key = "capacity-tier-\(UUID().uuidString)"
        addTeardownBlock { cache.remove(for: key) }

        cache.set(Self.solidImage(width: sourceWidth, height: sourceHeight), for: key)
        cache.processingQueue.waitUntilAllOperationsAreFinished()

        return try XCTUnwrap(cache.get(for: key), "the processed image must be in the memory cache")
    }

    private static func solidImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

//
//  TPPBookCoverRegistryTests.swift
//  PalaceTests
//
//  Regression tests for PP-3682: Stanislaus County Library crashes when opening a swimlane.
//  The crash was caused by full-resolution image decoding triggering an iOS 26 JPEG color
//  space bug (rdar://143602439) and excessive memory pressure from concurrent image loads.
//

import XCTest
import ImageIO
@testable import Palace

final class TPPBookCoverRegistryTests: XCTestCase {

    // MARK: - Downsample Decode Tests

    /// Regression test for PP-3682: Verify that JPEG images are decoded at a bounded size
    /// instead of full resolution. The original code used UIImage(data:) + byPreparingForDisplay()
    /// which decoded at full resolution, triggering iOS 26's kCGImageBlockFormatBGRx8 bug
    /// on 24-bpp JFIF images and causing OOM crashes.
    func testDownsampleImage_DecodesJPEGAtTargetSize() {
        // Arrange - Create a large JPEG image (simulating a high-res book cover)
        let largeSize = CGSize(width: 2000, height: 3000)
        let maxDimension: CGFloat = 512
        let jpegData = createTestJPEGData(size: largeSize)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: jpegData, maxDimension: maxDimension)

        // Assert
        XCTAssertNotNil(result, "Should successfully decode JPEG data")
        guard let image = result else { return }

        let maxSide = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(maxSide, maxDimension,
                                 "Decoded image should be at most \(maxDimension)px, but was \(maxSide)px. " +
                                    "Full-resolution decoding wastes memory and triggers iOS 26 decode bugs.")
    }

    /// Verify that small images are not upscaled
    func testDownsampleImage_SmallImageNotUpscaled() {
        // Arrange
        let smallSize = CGSize(width: 100, height: 150)
        let maxDimension: CGFloat = 512
        let jpegData = createTestJPEGData(size: smallSize)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: jpegData, maxDimension: maxDimension)

        // Assert
        XCTAssertNotNil(result)
        guard let image = result else { return }

        // CGImageSource may slightly adjust dimensions but should not significantly upscale
        let maxSide = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(maxSide, maxDimension,
                                 "Small image should not be upscaled beyond target dimension")
    }

    /// Verify aspect ratio is preserved during downsampling
    func testDownsampleImage_PreservesAspectRatio() {
        // Arrange - Tall book cover aspect ratio (2:3)
        let originalSize = CGSize(width: 2000, height: 3000)
        let maxDimension: CGFloat = 600
        let jpegData = createTestJPEGData(size: originalSize)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: jpegData, maxDimension: maxDimension)

        // Assert
        XCTAssertNotNil(result)
        guard let image = result else { return }

        let originalAspectRatio = originalSize.width / originalSize.height
        let resultAspectRatio = image.size.width / image.size.height

        XCTAssertEqual(originalAspectRatio, resultAspectRatio, accuracy: 0.02,
                       "Aspect ratio should be preserved after downsampling")
    }

    /// Verify that PNG images also work with the downsampler
    func testDownsampleImage_DecodesPNGData() {
        // Arrange
        let size = CGSize(width: 1500, height: 2000)
        let maxDimension: CGFloat = 512
        let pngData = createTestPNGData(size: size)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: pngData, maxDimension: maxDimension)

        // Assert
        XCTAssertNotNil(result, "Should successfully decode PNG data")
        guard let image = result else { return }

        let maxSide = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(maxSide, maxDimension)
    }

    /// Verify that invalid data returns nil instead of crashing
    func testDownsampleImage_InvalidDataReturnsNil() {
        // Arrange - Garbage data that isn't a valid image
        let invalidData = Data("This is not an image".utf8)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: invalidData, maxDimension: 512)

        // Assert
        XCTAssertNil(result, "Invalid image data should return nil, not crash")
    }

    /// Verify that empty data returns nil instead of crashing
    func testDownsampleImage_EmptyDataReturnsNil() {
        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: Data(), maxDimension: 512)

        // Assert
        XCTAssertNil(result, "Empty data should return nil, not crash")
    }

    /// Regression test for PP-3682: Verify memory efficiency of the downsample path.
    /// The original code created 2 full-resolution copies (UIImage + byPreparingForDisplay)
    /// before resizing. The CGImageSource path should only create 1 image at target size.
    func testDownsampleImage_MemoryEfficiency_LargeImage() {
        // Arrange - Very large image simulating a high-DPI book cover
        let hugeSize = CGSize(width: 4000, height: 6000)
        let maxDimension: CGFloat = 768
        let jpegData = createTestJPEGData(size: hugeSize)

        // Act
        let result = TPPBookCoverRegistry.downsampleImage(data: jpegData, maxDimension: maxDimension)

        // Assert
        XCTAssertNotNil(result)
        guard let image = result, let cgImage = image.cgImage else { return }

        // The decoded image should be at the target size, not full resolution
        let decodedPixels = cgImage.width * cgImage.height
        let fullResPixels = Int(hugeSize.width * hugeSize.height)

        // Decoded image should be much smaller than full resolution
        XCTAssertLessThan(decodedPixels, fullResPixels / 4,
                          "Decoded image should be significantly smaller than full resolution. " +
                            "Got \(decodedPixels) pixels, full-res would be \(fullResPixels) pixels.")
    }

    // MARK: - Host Failure Tracker (Circuit Breaker) Tests

    /// Regression test for PP-3682: When a host is failing (e.g., palace-bookshelf-downloads.dp.la
    /// returning DNS errors), it should be marked as failing so subsequent requests skip immediately
    /// instead of waiting for DNS timeouts.
    func testHostFailureTracker_RecordsFailureAndSkips() async {
        // Arrange
        let tracker = HostFailureTracker(cooldownInterval: 300)
        let failingHost = "palace-bookshelf-downloads.dp.la"

        // Initially not failing
        let initialCheck = await tracker.isHostFailing(failingHost)
        XCTAssertFalse(initialCheck, "Host should not be failing initially")

        // Act - Record a failure
        await tracker.recordFailure(for: failingHost)

        // Assert
        let afterFailure = await tracker.isHostFailing(failingHost)
        XCTAssertTrue(afterFailure,
                      "Host should be marked as failing after a recorded failure. " +
                        "Without this, each book makes 2 wasted requests to the dead host.")
    }

    /// Verify that a successful request clears the failure record
    func testHostFailureTracker_SuccessClearsFailure() async {
        // Arrange
        let tracker = HostFailureTracker(cooldownInterval: 300)
        let host = "example.com"

        await tracker.recordFailure(for: host)
        let failing = await tracker.isHostFailing(host)
        XCTAssertTrue(failing)

        // Act - Record a success (host recovered)
        await tracker.recordSuccess(for: host)

        // Assert
        let afterSuccess = await tracker.isHostFailing(host)
        XCTAssertFalse(afterSuccess,
                       "Host should no longer be failing after a successful request")
    }

    /// Verify that the circuit breaker resets after the cooldown period
    func testHostFailureTracker_ResetsAfterCooldown() async {
        // Arrange - Use a very short cooldown for testing
        let tracker = HostFailureTracker(cooldownInterval: 0.1) // 100ms
        let host = "expired-failure.example.com"

        await tracker.recordFailure(for: host)
        let immediateCheck = await tracker.isHostFailing(host)
        XCTAssertTrue(immediateCheck)

        // Act - Wait for cooldown to expire
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Assert - Should allow retry after cooldown
        let afterCooldown = await tracker.isHostFailing(host)
        XCTAssertFalse(afterCooldown,
                       "Host failure should expire after cooldown period to allow retry")
    }

    /// Verify that nil hosts don't cause issues
    func testHostFailureTracker_NilHostHandledGracefully() async {
        let tracker = HostFailureTracker()

        // These should not crash
        await tracker.recordFailure(for: nil)
        await tracker.recordSuccess(for: nil)
        let result = await tracker.isHostFailing(nil)
        XCTAssertFalse(result, "nil host should never be considered failing")
    }

    /// Verify that different hosts are tracked independently
    func testHostFailureTracker_TracksHostsIndependently() async {
        let tracker = HostFailureTracker()
        let failingHost = "dead-host.example.com"
        let healthyHost = "healthy-host.example.com"

        // Only mark one host as failing
        await tracker.recordFailure(for: failingHost)

        let failingCheck = await tracker.isHostFailing(failingHost)
        let healthyCheck = await tracker.isHostFailing(healthyHost)

        XCTAssertTrue(failingCheck, "Failing host should be marked")
        XCTAssertFalse(healthyCheck, "Healthy host should not be affected")
    }

    /// Verify that reset clears all tracked failures
    func testHostFailureTracker_ResetClearsAll() async {
        let tracker = HostFailureTracker()

        await tracker.recordFailure(for: "host1.example.com")
        await tracker.recordFailure(for: "host2.example.com")

        // Act
        await tracker.reset()

        // Assert
        let check1 = await tracker.isHostFailing("host1.example.com")
        let check2 = await tracker.isHostFailing("host2.example.com")
        XCTAssertFalse(check1)
        XCTAssertFalse(check2)
    }

    /// Verify that the registry uses shorter timeouts for image fetches
    func testRegistry_UsesCustomImageSession() {
        // The image session should have shorter timeouts than the default 60s
        let config = TPPBookCoverRegistry.imageSession.configuration

        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 15,
                                 "Image fetch timeout should be ≤15s, not the default 60s. " +
                                    "Long timeouts cause the app to appear frozen when a host is down.")

        XCTAssertFalse(config.waitsForConnectivity,
                       "Image fetches should fail immediately without connectivity, not wait")
    }

    // MARK: - Helpers

    /// Creates JPEG data for a solid-color test image at the specified size
    private func createTestJPEGData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            // Draw a simple gradient to make it a realistic test image
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    /// Creates PNG data for a solid-color test image at the specified size
    private func createTestPNGData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }
}

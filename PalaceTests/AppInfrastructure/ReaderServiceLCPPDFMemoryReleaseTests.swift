//  ReaderServiceLCPPDFMemoryReleaseTests.swift
//
//  Opening an LCP PDF releases decoded covers directly instead of posting an
//  app-wide memory warning, which also paused downloads and cancelled queued
//  cover writes (PP-5499).

import XCTest
import UIKit
@testable import Palace
import PalaceBookModel

@MainActor
final class ReaderServiceLCPPDFMemoryReleaseTests: XCTestCase {

    private var observer: NSObjectProtocol?

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        super.tearDown()
    }

    func testReleaseMemoryBeforeLCPPDFOpen_evictsDecodedCoversWithoutAMemoryWarning() {
        let spy = EvictionSpyImageCache()
        let service = ReaderService(rootViewController: { nil }, imageCache: { spy })
        let warnings = LockIsolated(0)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in warnings.withValue { $0 += 1 } }

        service.releaseMemoryBeforeLCPPDFOpen()

        XCTAssertEqual(spy.evictions.value, 1)
        XCTAssertEqual(warnings.value, 0, "no app-wide memory warning may be posted")
    }
}

private final class EvictionSpyImageCache: ImageCacheType, @unchecked Sendable {
    let evictions = LockIsolated(0)
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
    func get(for key: String) -> UIImage? { nil }
    func getAsync(for key: String) async -> UIImage? { nil }
    func remove(for key: String) {}
    func clear() {}
    func warmMemoryCache(for keys: [String]) async {}
    func evictDecodedImages() { evictions.withValue { $0 += 1 } }
}

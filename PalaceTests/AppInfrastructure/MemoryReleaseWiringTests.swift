//
//  MemoryReleaseWiringTests.swift
//  PalaceTests
//
//  Each cache that used to observe the memory warning itself is now wired to
//  the one handler (PP-5580). These tests fail if a registration is dropped.
//

import UIKit
import XCTest
@testable import Palace
@testable import PalaceBookModel

@MainActor
final class MemoryReleaseWiringTests: XCTestCase {

    private func postSystemWarning() {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    // MARK: - A real warning still releases

    func testSystemWarning_emptiesGeneralCacheMemory() {
        let cache = GeneralCache<String, Data>(cacheName: "wiring-\(UUID().uuidString)", mode: .memoryOnly)
        cache.set(Data([1, 2, 3]), for: "key")
        XCTAssertNotNil(cache.get(for: "key"), "Precondition: the value is held in memory")

        postSystemWarning()

        XCTAssertNil(cache.get(for: "key"), "A memory warning must empty the memory layer")
    }

    #if LCP
    func testSystemWarning_emptiesLCPDecryptCache() {
        let cache = LCPDecryptCache()
        cache.store(Data(count: 16), for: Data([9, 9]))

        postSystemWarning()

        XCTAssertNil(cache.decrypted(for: Data([9, 9])))
        XCTAssertEqual(cache.byteCount, 0)
    }
    #endif

    // MARK: - Each owner registers under its stage

    func testImageCache_registersDecodedImages() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "wiring-\(UUID().uuidString)")
        XCTAssertEqual(MemoryReleaseCoordinator.shared.stages(registeredFor: cache), [.decodedImages])
    }

    func testGeneralCache_registersCachedData() {
        let cache = GeneralCache<String, Data>(cacheName: "wiring-\(UUID().uuidString)", mode: .memoryAndDisk)
        XCTAssertEqual(MemoryReleaseCoordinator.shared.stages(registeredFor: cache), [.cachedData])
    }

    func testAppContainerCatalogRepository_registersCatalogFeeds() {
        let container = makeTestAppContainer()
        let repository = container.catalogRepository as AnyObject
        XCTAssertEqual(MemoryReleaseCoordinator.shared.stages(registeredFor: repository), [.catalogFeeds])
    }

    func testAppContainerBookCellModelCache_registersBookCells() {
        let container = makeTestAppContainer()
        XCTAssertEqual(MemoryReleaseCoordinator.shared.stages(registeredFor: container.bookCellModelCache), [.bookCells])
    }

    /// The container wires its cover store to the warning once, however many
    /// containers share the store (PP-5583).
    func testAppContainers_registerTheirBookCoverStoreOnce() {
        let coordinator = MemoryReleaseCoordinator(center: NotificationCenter())
        let store = BookCoverStore(limits: .init(byteLimit: .max, keepRecent: 0))

        coordinator.registerBookCovers(store)
        coordinator.registerBookCovers(store)

        XCTAssertEqual(coordinator.stages(registeredFor: store), [.decodedImages])
    }

    func testAppContainer_registersItsBookCoverStore() {
        let container = makeTestAppContainer()
        XCTAssertEqual(MemoryReleaseCoordinator.shared.stages(registeredFor: container.bookCoverStore), [.decodedImages])
    }

    /// The monitor records the event first, then the network cache, downloads
    /// and disk space, in that order.
    func testMemoryPressureMonitor_registersRecordFirstThenItsReleases() {
        let coordinator = MemoryReleaseCoordinator(center: NotificationCenter())
        let monitor = MemoryPressureMonitor.shared

        monitor.registerReleaseSteps(on: coordinator)

        XCTAssertEqual(coordinator.stages(registeredFor: monitor), [.record, .networkResponses, .downloads, .diskSpace])
    }
}

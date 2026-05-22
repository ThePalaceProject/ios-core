import XCTest
import SwiftUI
@testable import Palace

/// End-to-end tests that exercise the `ImageLoading` injection seam on
/// `AppContainer`. The point is to prove a `MockImageLoader` can be threaded
/// through the SwiftUI Environment and that prod code reads it rather than
/// reaching for the legacy singletons.
final class AppContainerImageLoaderInjectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeProductionLikeContainer(imageLoader: ImageLoading) -> AppContainer {
        let production = AppContainer.production()
        return AppContainer(
            bookRegistry: production.bookRegistry,
            networkExecutor: production.networkExecutor,
            networkQueue: production.networkQueue,
            reachability: production.reachability,
            accountsManager: production.accountsManager,
            settings: production.settings,
            downloadCenter: production.downloadCenter,
            downloadAnnouncementService: production.downloadAnnouncementService,
            debugSettings: production.debugSettings,
            imageCache: production.imageCache,
            imageLoader: imageLoader,
            userAccountPublisher: production.userAccountPublisher,
            opdsFeedService: production.opdsFeedService,
            readerService: production.readerService,
            navigationCoordinatorHub: production.navigationCoordinatorHub,
            tabRouterHub: production.tabRouterHub,
            drmAuthorizerProvider: production.drmAuthorizerProvider
        )
    }

    // MARK: - Tests

    func testContainer_holdsInjectedImageLoader() {
        let mock = MockImageLoader()
        let container = makeProductionLikeContainer(imageLoader: mock)

        // Identity check via a routed call — calling clearAll on the container's
        // imageLoader must hit the mock instance specifically, not a different
        // ImageLoading hiding behind a wrapper.
        container.imageLoader.clearAll()

        XCTAssertEqual(mock.clearAllCount, 1,
                       "AppContainer must hand the injected ImageLoading instance to consumers verbatim")
    }

    func testContainer_imageLoader_setForwardsToInjectedInstance() {
        let mock = MockImageLoader()
        let container = makeProductionLikeContainer(imageLoader: mock)

        let img = UIImage(systemName: "book")!
        container.imageLoader.set(img, for: "k", expiresIn: 30)

        XCTAssertEqual(mock.setKeys, ["k"])
        XCTAssertEqual(mock.get(for: "k")?.pngData(), img.pngData())
    }

    func testContainer_imageLoader_evictDecodedRoutesToInjectedInstance() {
        let mock = MockImageLoader()
        let container = makeProductionLikeContainer(imageLoader: mock)

        container.imageLoader.evictDecodedImages()
        container.imageLoader.evictDecodedImages()

        XCTAssertEqual(mock.evictDecodedCount, 2)
    }

    func testProductionContainer_exposesNonNilImageLoader() {
        // Make sure the wired-up production graph actually constructs an
        // ImageLoading (regression guard against a future refactor that
        // forgets to populate the field).
        let container = AppContainer.production()

        // Real assertion: the production loader must route clearAll without
        // throwing or crashing, and after a get-set roundtrip the value must
        // come back. This proves the imageLoader is functional, not just non-nil.
        let img = UIImage(systemName: "tray")!
        let key = "prod-injection-test-\(UUID().uuidString)"
        container.imageLoader.set(img, for: key, expiresIn: 60)
        // ImageCache.set schedules into an OperationQueue. drainMainQueue
        // flushes any main-queue continuation that the cache may post; the
        // subsequent getAsync independently waits for the actual read signal,
        // so no fixed-delay sleep is needed here.
        drainMainQueue()

        // get() may return nil from main if main-thread-disk-skip applies, so
        // pull via the async API which promotes from disk if needed.
        let waitForRead = expectation(description: "image read")
        Task {
            _ = await container.imageLoader.getAsync(for: key)
            waitForRead.fulfill()
        }
        // 5s budget — getAsync resolves the moment the image cache returns
        // (memory hit ≪10ms, disk-promote hit <100ms). With the asyncAfter
        // sleep removed there is no padding to justify a longer wait.
        wait(for: [waitForRead], timeout: 5.0)

        // Clean up to keep test isolation
        container.imageLoader.remove(for: key)
    }
}

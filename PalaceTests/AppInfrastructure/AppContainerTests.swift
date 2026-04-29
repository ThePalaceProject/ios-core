import XCTest
import Combine
import SwiftUI
@testable import Palace

/// Contract tests for AppContainer as the single DI composition root.
///
/// The refactor goal these tests pin down: construction MUST be explicit
/// (no `.shared` reads hidden in default parameters), substitution MUST work
/// for every exposed service, and `@Environment(\.appContainer)` MUST route
/// through the same production factory used by the app entry points.
final class AppContainerTests: XCTestCase {

    // MARK: - Production Factory

    /// `AppContainer.production()` is the single composition root the app
    /// entry points (SceneDelegate, AppDelegate, EnvironmentKey default) call.
    /// It must hand back a stable, app-scoped registry — the same instance
    /// across calls. Identity is the contract: every consumer must subscribe
    /// to the *same* registryPublisher / observe the *same* state, so a
    /// refactor that quietly constructs a new registry per call would break
    /// every reactive UI binding. (Phase 6.6 replaced `TPPBookRegistry.shared`
    /// with this AppContainer-anchored instance — the singleton is gone.)
    func testProduction_handsOutStableAppScopedRegistry() {
        let containerA = AppContainer.production()
        let containerB = AppContainer.production()
        XCTAssertTrue(
            containerA.bookRegistry as AnyObject === containerB.bookRegistry as AnyObject,
            "Production container must hand out the same TPPBookRegistry across calls"
        )
    }

    // MARK: - Substitution (the whole point of DI)

    /// A test suite must be able to drop a mock registry into AppContainer
    /// and see that mock on the other side. If this breaks, no ViewModel that
    /// depends on AppContainer can be unit-tested.
    func testInit_withMockBookRegistry_exposesTheMockNotTheProductionRegistry() {
        let mock = TPPBookRegistryMock()
        let container = AppContainer(
            bookRegistry: mock,
            networkExecutor: AppContainer.production().networkExecutor,
            networkQueue: AppContainer.production().networkQueue,
            reachability: AppContainer.production().reachability,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            downloadCenter: AppContainer.production().downloadCenter,
            debugSettings: AppContainer.production().debugSettings,
            imageCache: ImageCache.shared,
            userAccountPublisher: .shared,
            opdsFeedService: AppContainer.production().opdsFeedService,
            readerService: AppContainer.production().readerService,
            navigationCoordinatorHub: NavigationCoordinatorHub(),
            tabRouterHub: AppTabRouterHub(),
            drmAuthorizerProvider: { nil }
        )
        XCTAssertTrue(
            container.bookRegistry as AnyObject === mock,
            "Container must hand back the injected mock, not the production registry"
        )
        XCTAssertFalse(
            container.bookRegistry as AnyObject === AppContainer.production().bookRegistry as AnyObject,
            "Substitution must displace the production instance, not shadow it"
        )
    }

    // MARK: - Value Semantics

    /// AppContainer is a `struct` for a reason — separate containers must
    /// be able to hold separate service graphs. If this regresses to a class
    /// with shared state, every test suite that builds its own container
    /// gets unexpected cross-contamination.
    func testInit_twoContainersWithDifferentRegistries_remainIndependent() {
        let mockA = TPPBookRegistryMock()
        let containerA = AppContainer(
            bookRegistry: mockA,
            networkExecutor: AppContainer.production().networkExecutor,
            networkQueue: AppContainer.production().networkQueue,
            reachability: AppContainer.production().reachability,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            downloadCenter: AppContainer.production().downloadCenter,
            debugSettings: AppContainer.production().debugSettings,
            imageCache: ImageCache.shared,
            userAccountPublisher: .shared,
            opdsFeedService: AppContainer.production().opdsFeedService,
            readerService: AppContainer.production().readerService,
            navigationCoordinatorHub: NavigationCoordinatorHub(),
            tabRouterHub: AppTabRouterHub(),
            drmAuthorizerProvider: { nil }
        )
        let containerB = AppContainer.production()
        XCTAssertFalse(
            containerA.bookRegistry as AnyObject === containerB.bookRegistry as AnyObject,
            "Distinct containers must hold distinct registry references"
        )
    }

    // MARK: - SwiftUI Environment Integration

    /// `@Environment(\.appContainer)` reads its default via `EnvironmentValues`.
    /// That default must be the production factory — not a second parallel
    /// composition path that could drift from what the app actually wires.
    func testEnvironmentValues_appContainerDefault_matchesProductionFactory() {
        let fromEnvironmentDefault = EnvironmentValues().appContainer
        let fromProductionFactory = AppContainer.production()
        XCTAssertTrue(
            fromEnvironmentDefault.bookRegistry as AnyObject
                === fromProductionFactory.bookRegistry as AnyObject,
            "@Environment default must route through .production() — a second path invites drift"
        )
    }
}

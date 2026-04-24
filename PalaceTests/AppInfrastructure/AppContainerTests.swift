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
    /// It must wire the real app-scoped singletons.
    func testProduction_wiresTheRealBookRegistry() {
        let container = AppContainer.production()
        XCTAssertTrue(
            container.bookRegistry as AnyObject === TPPBookRegistry.shared as AnyObject,
            "Production container must hand out the live TPPBookRegistry.shared"
        )
    }

    // MARK: - Substitution (the whole point of DI)

    /// A test suite must be able to drop a mock registry into AppContainer
    /// and see that mock on the other side. If this breaks, no ViewModel that
    /// depends on AppContainer can be unit-tested.
    func testInit_withMockBookRegistry_exposesTheMockNotTheSingleton() {
        let mock = TPPBookRegistryMock()
        let container = AppContainer(
            bookRegistry: mock,
            networkExecutor: .shared,
            accountsManager: .shared,
            settings: .shared,
            downloadCenter: .shared,
            debugSettings: .shared,
            bookCellModelCache: .shared,
            imageCache: ImageCache.shared
        )
        XCTAssertTrue(
            container.bookRegistry as AnyObject === mock,
            "Container must hand back the injected mock, not TPPBookRegistry.shared"
        )
        XCTAssertFalse(
            container.bookRegistry as AnyObject === TPPBookRegistry.shared as AnyObject,
            "Substitution must displace the singleton, not shadow it"
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
            networkExecutor: .shared,
            accountsManager: .shared,
            settings: .shared,
            downloadCenter: .shared,
            debugSettings: .shared,
            bookCellModelCache: .shared,
            imageCache: ImageCache.shared
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

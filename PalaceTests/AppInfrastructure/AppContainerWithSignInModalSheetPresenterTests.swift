//
//  AppContainerWithSignInModalSheetPresenterTests.swift
//  PalaceTests
//
//  swarm_d8f11437 Module B — `AppContainer.withSignInModalSheetPresenter(_:)`
//  testability seam (wave 4).
//
//  Pins the testability-seam modifier added to AppContainer so test
//  callers (Module A's wiring test among them) can inject a spy
//  `SignInModalSheetPresenter` without disturbing the static cache that
//  holds the production-resolved presenter. Two tests:
//
//   1. Override is preferred over the static cache — `AppContainer
//      .production().withSignInModalSheetPresenter(spy).signInModalSheetPresenter`
//      MUST `===` the spy, and the original `AppContainer.production()`
//      MUST be unaffected (struct copy-on-modify semantics).
//   2. When the override is nil (production-shaped container), the
//      computed property still short-circuits to the same cached
//      instance across reads — proves the new override-first branch
//      did NOT break the existing cache short-circuit.
//

import XCTest
@testable import Palace

@MainActor
final class AppContainerWithSignInModalSheetPresenterTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a distinct presenter against the production container.
    /// Uses the designated init (not the convenience `init(appContainer:)`)
    /// so the spy is structurally identical to a real presenter — same
    /// `@MainActor` class, same protocol surface — but is a fresh
    /// instance whose identity (`===`) is distinct from the cached
    /// production presenter.
    ///
    /// The driver is a no-op closure; this presenter is only ever
    /// inspected for identity in these tests, not driven.
    @MainActor
    private func makeSpyPresenter(appContainer: AppContainer) -> SignInModalSheetPresenter {
        return SignInModalSheetPresenter(
            appContainer: appContainer,
            currentAccountIDProvider: { nil },
            needsAuthProvider: { _ in false },
            driver: { _, _, completion in completion() }
        )
    }

    // MARK: - Tests

    /// `withSignInModalSheetPresenter(_:)` MUST return a copy of the
    /// container whose `signInModalSheetPresenter` resolves to the
    /// injected spy — NOT the static-cached production presenter. The
    /// ORIGINAL container MUST be unchanged (struct copy semantics).
    ///
    /// Kill case: a regression that ignores the override field in the
    /// computed property (always falls through to the static cache)
    /// fails this test — the asserted `overridden.signInModalSheetPresenter
    /// === spy` will not hold.
    func testWithSignInModalSheetPresenter_overrideValue_isPreferredOverStaticCache() {
        // Arrange: get the production container and prime the static
        // cache by reading the default presenter once. This is the
        // realistic test scenario — by the time tests run, some other
        // path in the suite has likely already primed the cache, so the
        // override branch MUST win even when the cache is hot.
        let container = AppContainer.production()
        let cachedPresenter = container.signInModalSheetPresenter
        let spy = makeSpyPresenter(appContainer: container)
        XCTAssertFalse(spy === cachedPresenter,
                       "Spy must be a distinct instance from the cached presenter")

        // Act: build an overridden container via the modifier.
        let overridden = container.withSignInModalSheetPresenter(spy)

        // Assert: overridden container resolves to the spy; original is
        // unchanged.
        XCTAssertTrue(overridden.signInModalSheetPresenter === spy,
                      "Overridden container must resolve to the injected spy presenter")
        XCTAssertTrue(container.signInModalSheetPresenter === cachedPresenter,
                      "Original container must continue to resolve to the cached presenter — modifier is a copy, not a mutation")
    }

    /// When the override is nil (the production-shaped container from
    /// `AppContainer.production()`), the computed property MUST still
    /// short-circuit to the same cached instance across multiple
    /// reads. Proves the new override-first branch did NOT break the
    /// existing static-cache fall-through.
    ///
    /// Kill case: a regression that re-constructs the presenter on
    /// every read (ignoring the cache) fails this test — the two reads
    /// will return distinct instances.
    func testWithSignInModalSheetPresenter_productionContainer_fallsThroughToStaticCacheWhenOverrideNil() {
        // Arrange + Act: read the production container's presenter twice.
        let container = AppContainer.production()
        let first = container.signInModalSheetPresenter
        let second = container.signInModalSheetPresenter

        // Assert: both reads return the same cached instance.
        XCTAssertTrue(first === second,
                      "Production container with nil override must short-circuit to the static cache on every read")
    }
}

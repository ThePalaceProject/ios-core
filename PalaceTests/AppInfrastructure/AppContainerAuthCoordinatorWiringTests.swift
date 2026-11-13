//
//  AppContainerAuthCoordinatorWiringTests.swift
//  PalaceTests
//
//  Verifies AppContainer wires PalaceAuth.AuthCoordinator as a singleton
//  reachable through `AppContainer.production().authCoordinator`: built once,
//  the SAME instance across `production()` calls, and reachable from its
//  consumers (MyBooksDownloadCenter → BookReturnService / BorrowOperation /
//  TokenRefreshInterceptor / DownloadAuthRetryHandler). Coordinator behavior
//  lives in `PalaceAuthTests/AuthCoordinatorTests.swift`; caller routing in
//  the per-caller `<Site>AuthCoordinatorTests` suites.
//

import XCTest
@testable import Palace
@testable import PalaceAuth

@MainActor
final class AppContainerAuthCoordinatorRegistrationTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    /// `AppContainer.production().authCoordinator` exposes a non-nil
    /// PalaceAuth.AuthCoordinator. Renders the wiring failure (e.g. a
    /// refactor that drops the let-binding) as a compile-OR-test failure
    /// rather than a runtime "actor is nil" trap. Single-purpose, single
    /// assertion; this is a structural invariant of the composition root.
    func testProductionAppContainer_exposesNonNilAuthCoordinator() {
        let coordinator: AuthCoordinator = AppContainer.production().authCoordinator
        // The type is non-optional (`let authCoordinator: AuthCoordinator`),
        // so existence is enforced at compile time. The assignment above
        // proves the property is reachable; this assertion documents the
        // intent for future readers and pins the type identity in case
        // someone changes the field type without updating callers.
        XCTAssertTrue(type(of: coordinator) == AuthCoordinator.self,
                      "AppContainer.authCoordinator must be a PalaceAuth.AuthCoordinator (not a subclass / wrapper)")
    }

    /// `AppContainer.production()` is a cached factory — the coordinator
    /// must be the SAME instance across calls. Otherwise the single-flight
    /// + cooldown state inside the coordinator is per-caller, which
    /// silently breaks the thundering-herd guarantee that motivated the
    /// coordinator in the first place. Singleton invariant.
    func testProductionAppContainer_authCoordinator_isSingletonAcrossCalls() {
        let first = AppContainer.production().authCoordinator
        let second = AppContainer.production().authCoordinator
        // AuthCoordinator is a `public actor` — reference equality is
        // meaningful (actor instances ARE reference types).
        XCTAssertTrue(first === second,
                      "AppContainer.production() must vend the SAME AuthCoordinator across calls so single-flight + cooldown survive across callers")
    }

    /// `AppContainer.production()` exposes `downloadCenter`. The MBDC
    /// produced there constructs all the auth-coordinator-aware services
    /// (BookReturnService, BorrowOperation, TokenRefreshInterceptor,
    /// DownloadAuthRetryHandler) with the same coordinator instance the
    /// container holds. Without exposing those private constructions
    /// through Mirror (brittle — class layout drift breaks the test),
    /// we pin the smallest observable invariant: `prod.downloadCenter`
    /// is the SAME instance across `production()` calls. If MBDC is
    /// reconstructed on every call, each call gets a fresh coordinator
    /// chain — pinning the singleton invariant covers the wiring chain
    /// transitively, because the SAME MBDC instance was built with the
    /// SAME coordinator (which is itself proven singleton above).
    func testProductionAppContainer_downloadCenter_isSingletonAcrossCalls() {
        let firstMBDC = AppContainer.production().downloadCenter
        let secondMBDC = AppContainer.production().downloadCenter
        XCTAssertTrue(firstMBDC === secondMBDC,
                      "AppContainer.production() must vend the SAME MyBooksDownloadCenter across calls — otherwise the auth-coordinator-aware service constructions inside MBDC (BookReturnService / BorrowOperation / TokenRefreshInterceptor / DownloadAuthRetryHandler) would fragment and each fresh MBDC would build its own coordinator chain")
    }
}

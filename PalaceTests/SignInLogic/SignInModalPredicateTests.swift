//
//  SignInModalPredicateTests.swift
//  PalaceTests
//
//  Closes the SignInModalView 0% mutation kill rate identified in the
//  2026-05-11 regression. The `shouldAutoDismiss` predicate was extracted
//  into a static helper so the mutation gate can verify a regression to
//  the inverted branch is caught by a focused unit test rather than
//  escaping as a stuck-modal user report.
//
//  Mutation surface covered:
//    - `SignInModalView.shouldAutoDismiss(authState:)` — `==` flip on .loggedIn
//
//  swarm_d8f11437 Module A wave 4 — the 4 `shouldFireDismissCallback`
//  tests were removed when the wave-4 migration deleted
//  `SignInModalHostingController` (the predicate's home). The
//  once-after-fully-dismissed semantics are now pinned at the presenter
//  level via SignInModalLifecycleTests.swift's state-transition tests.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class SignInModalPredicateTests: XCTestCase {

    // MARK: - shouldAutoDismiss

    func testShouldAutoDismiss_whenLoggedIn_returnsTrue() {
        // Pair-assert that the inverse predicate (loggedOut) is false on the
        // same call — pinning that the function is NOT a constant `true`. A
        // mutation that returns true unconditionally would fail the second
        // assertion.
        XCTAssertTrue(SignInModalView.shouldAutoDismiss(authState: .loggedIn),
                      ".loggedIn must auto-dismiss the modal")
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .loggedOut),
                       ".loggedOut must NOT auto-dismiss — pin that the predicate isn't a constant true")
    }

    func testShouldAutoDismiss_whenLoggedOut_returnsFalse() {
        // Pair-assert that .credentialsStale also returns false — so a
        // mutation that hard-codes false for .loggedOut still wouldn't pass
        // the multi-state contract.
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .loggedOut),
                       ".loggedOut must NOT auto-dismiss")
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .credentialsStale),
                       ".credentialsStale must also NOT auto-dismiss — neither does")
    }

    func testShouldAutoDismiss_whenCredentialsStale_returnsFalse() {
        // Stale credentials must NOT auto-dismiss the modal — the user
        // is mid-re-auth and the form is still showing. Pair-assert that
        // .loggedIn DOES dismiss — pinning the contract is multi-state, not
        // a constant function.
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .credentialsStale),
                       ".credentialsStale must NOT auto-dismiss — user is mid-re-auth")
        XCTAssertTrue(SignInModalView.shouldAutoDismiss(authState: .loggedIn),
                      "Sanity-check: .loggedIn still dismisses — pin that the predicate isn't a constant false")
    }

}

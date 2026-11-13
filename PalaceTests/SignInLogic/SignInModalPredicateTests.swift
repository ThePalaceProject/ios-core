//
//  SignInModalPredicateTests.swift
//  PalaceTests
//
//  Pins `SignInModalView.shouldAutoDismiss(authState:)`, extracted into a
//  static helper after the 2026-05-11 stuck-modal regression so an
//  inverted branch is caught by a focused unit test.
//
//  Once-after-fully-dismissed semantics are pinned at the presenter level
//  in SignInModalLifecycleTests.swift.
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
        // a regression that returns true unconditionally would fail the second
        // assertion.
        XCTAssertTrue(SignInModalView.shouldAutoDismiss(authState: .loggedIn),
                      ".loggedIn must auto-dismiss the modal")
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .loggedOut),
                       ".loggedOut must NOT auto-dismiss — pin that the predicate isn't a constant true")
    }

    func testShouldAutoDismiss_whenLoggedOut_returnsFalse() {
        // Pair-assert that .credentialsStale also returns false — so a
        // regression that hard-codes false for .loggedOut still wouldn't pass
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

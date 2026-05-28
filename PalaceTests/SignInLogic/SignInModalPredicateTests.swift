//
//  SignInModalPredicateTests.swift
//  PalaceTests
//
//  Closes the SignInModalView 0% mutation kill rate identified in the
//  2026-05-11 regression. Both predicates were extracted into static
//  helpers so the mutation gate can verify a regression to the inverted
//  branch is caught by a focused unit test rather than escaping as a
//  stuck-modal user report.
//
//  Mutation surface covered:
//    - `SignInModalView.shouldAutoDismiss(authState:)` — `==` flip on .loggedIn
//    - `SignInModalHostingController.shouldFireDismissCallback(...)` — `==` flip on presentingViewController
//

import XCTest
import SwiftUI
@testable import Palace

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

    // MARK: - shouldFireDismissCallback

    func testShouldFireDismissCallback_firstTimeAndDismissed_returnsTrue() {
        // The truthy branch — first-time, fully dismissed. Pair-assert the
        // boundary on the firedOnce side: once we've fired, the same fully-
        // dismissed state must return false. Pins the firedOnce predicate.
        XCTAssertTrue(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: false,
            presentingViewController: nil
        ), "First-time + no presenter must fire the callback")
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: nil
        ), "Subsequent (firedOnce=true) + no presenter must NOT fire — idempotent")
    }

    func testShouldFireDismissCallback_firstTimeButStillPresented_returnsFalse() {
        // The protective guard: viewDidDisappear fires during normal
        // nav-stack pushes BEFORE the modal is actually torn down. The
        // hosting controller still has a presentingViewController.
        // Firing the callback here would race the in-flight dismissal
        // and lock the BookDetail half-sheet (the bug this guard exists
        // to prevent).
        let presenter = UIViewController()
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: false,
            presentingViewController: presenter
        ))
    }

    func testShouldFireDismissCallback_alreadyFired_returnsFalse() {
        // The idempotency branch — once fired, stays false regardless of
        // presenter state. Pair-assert both presenter states so a mutation
        // that drops the firedOnce check (and relies entirely on presenter)
        // would surface here.
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: nil
        ), "firedOnce=true must suppress the callback even when fully dismissed")
        let presenter = UIViewController()
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: presenter
        ), "firedOnce=true must suppress the callback even when still presented")
    }

    func testShouldFireDismissCallback_alreadyFiredAndStillPresented_returnsFalse() {
        let presenter = UIViewController()
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: presenter
        ))
    }
}

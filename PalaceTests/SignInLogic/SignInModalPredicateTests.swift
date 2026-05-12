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
        XCTAssertTrue(SignInModalView.shouldAutoDismiss(authState: .loggedIn))
    }

    func testShouldAutoDismiss_whenLoggedOut_returnsFalse() {
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .loggedOut))
    }

    func testShouldAutoDismiss_whenCredentialsStale_returnsFalse() {
        // Stale credentials must NOT auto-dismiss the modal — the user
        // is mid-re-auth and the form is still showing.
        XCTAssertFalse(SignInModalView.shouldAutoDismiss(authState: .credentialsStale))
    }

    // MARK: - shouldFireDismissCallback

    func testShouldFireDismissCallback_firstTimeAndDismissed_returnsTrue() {
        XCTAssertTrue(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: false,
            presentingViewController: nil
        ))
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
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: nil
        ))
    }

    func testShouldFireDismissCallback_alreadyFiredAndStillPresented_returnsFalse() {
        let presenter = UIViewController()
        XCTAssertFalse(SignInModalHostingController<EmptyView>.shouldFireDismissCallback(
            firedOnce: true,
            presentingViewController: presenter
        ))
    }
}

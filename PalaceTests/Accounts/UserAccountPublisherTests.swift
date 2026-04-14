//
//  UserAccountPublisherTests.swift
//  PalaceTests
//
//  Unit tests for UserAccountPublisher state management and Combine publishers.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// SRS: SET-001 — Account state changes propagate through Combine publishers
@MainActor
final class UserAccountPublisherTests: XCTestCase {

    private var publisher: UserAccountPublisher!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        publisher = UserAccountPublisher()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        publisher = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInit_hasCorrectDefaults() {
        XCTAssertEqual(publisher.authState, .loggedOut)
        XCTAssertFalse(publisher.hasCredentials)
        XCTAssertNil(publisher.authToken)
        XCTAssertNil(publisher.barcode)
        XCTAssertNil(publisher.patronName)
        XCTAssertFalse(publisher.isSigningOut)
    }

    // MARK: - markLoggedIn

    func testMarkLoggedIn_setsLoggedInState() {
        publisher.markLoggedIn()

        XCTAssertEqual(publisher.authState, .loggedIn)
        XCTAssertTrue(publisher.hasCredentials)
    }

    // MARK: - markCredentialsStale

    func testMarkCredentialsStale_fromLoggedIn_setsStaleState() {
        publisher.markLoggedIn()

        publisher.markCredentialsStale()

        XCTAssertEqual(publisher.authState, .credentialsStale)
        // credentialsStale must be distinct from both loggedIn and loggedOut
        XCTAssertNotEqual(publisher.authState, .loggedIn, "credentialsStale must differ from loggedIn")
        XCTAssertNotEqual(publisher.authState, .loggedOut, "credentialsStale must differ from loggedOut")
    }

    func testMarkCredentialsStale_fromLoggedOut_doesNotChange() {
        // Should not transition from loggedOut to credentialsStale
        publisher.markCredentialsStale()

        XCTAssertEqual(publisher.authState, .loggedOut,
                       "Cannot mark stale when not logged in")
        // Only after logging in should marking stale be effective
        publisher.markLoggedIn()
        publisher.markCredentialsStale()
        XCTAssertEqual(publisher.authState, .credentialsStale,
                       "After logging in, markCredentialsStale must transition to credentialsStale")
    }

    // MARK: - signOut

    func testSignOut_resetsAllState() {
        publisher.markLoggedIn()

        publisher.signOut()

        XCTAssertEqual(publisher.authState, .loggedOut)
        XCTAssertFalse(publisher.hasCredentials)
        XCTAssertNil(publisher.authToken)
        XCTAssertNil(publisher.barcode)
        XCTAssertNil(publisher.patronName)
        XCTAssertTrue(publisher.isSigningOut)
    }

    func testSignOut_resetsIsSigningOutAfterDelay() async {
        publisher.signOut()
        XCTAssertTrue(publisher.isSigningOut)

        // Wait for the Task inside signOut to reset the flag
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        XCTAssertFalse(publisher.isSigningOut)
    }

    // MARK: - Publisher: credentialsDidChangePublisher

    func testCredentialsDidChangePublisher_emitsOnChange() {
        let expectation = expectation(description: "credentials changed")
        var values: [Bool] = []

        publisher.credentialsDidChangePublisher
            .dropFirst() // skip initial
            .sink { hasCredentials in
                values.append(hasCredentials)
                if values.count == 1 { expectation.fulfill() }
            }
            .store(in: &cancellables)

        publisher.markLoggedIn()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(values, [true])
    }

    // MARK: - Publisher: didSignOutPublisher

    func testDidSignOutPublisher_emitsOnSignOut() {
        let expectation = expectation(description: "signed out")
        var signOutEventCount = 0

        publisher.didSignOutPublisher
            .sink {
                signOutEventCount += 1
                expectation.fulfill()
            }
            .store(in: &cancellables)

        publisher.markLoggedIn()
        publisher.signOut()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(signOutEventCount, 1,
                       "didSignOutPublisher must emit exactly once per signOut() call")
        XCTAssertEqual(publisher.authState, .loggedOut,
                       "Auth state must be .loggedOut after the sign-out publisher fires")
    }

    // MARK: - Publisher: credentialsStalePublisher

    func testCredentialsStalePublisher_emitsWhenStale() {
        let expectation = expectation(description: "credentials stale")
        var staleEventCount = 0

        publisher.credentialsStalePublisher
            .sink {
                staleEventCount += 1
                expectation.fulfill()
            }
            .store(in: &cancellables)

        publisher.markLoggedIn()
        publisher.markCredentialsStale()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(staleEventCount, 1,
                       "credentialsStalePublisher must emit exactly once after markCredentialsStale()")
        XCTAssertEqual(publisher.authState, .credentialsStale,
                       "Auth state must be .credentialsStale after the publisher fires")
    }

    // MARK: - Publisher: authStateDidChangePublisher

    func testAuthStateDidChangePublisher_emitsStateChanges() {
        let expectation = expectation(description: "auth state changed")
        var states: [TPPAccountAuthState] = []

        publisher.authStateDidChangePublisher
            .dropFirst() // skip initial loggedOut
            .sink { state in
                states.append(state)
                if states.count == 2 { expectation.fulfill() }
            }
            .store(in: &cancellables)

        publisher.markLoggedIn()
        publisher.signOut()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(states, [.loggedIn, .loggedOut])
    }

    // MARK: - Shared instance

    func testShared_returnsSameInstance() {
        let a = UserAccountPublisher.shared
        let b = UserAccountPublisher.shared
        XCTAssertTrue(a === b)
        // A third access must also return the same instance
        let c = UserAccountPublisher.shared
        XCTAssertTrue(b === c, "sharedSession must remain the same object on every access")
        // The shared instance must not be a different type
        XCTAssertNotNil(a, "shared must never be nil")
    }
}

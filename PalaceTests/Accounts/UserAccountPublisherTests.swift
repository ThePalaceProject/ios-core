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
        // Round-trip test: signOut sets isSigningOut=true immediately, then
        // asynchronously resets it to false ~100ms later via a deferred Task.
        // We also pair-assert authState=.loggedOut throughout so a mutation
        // that resets isSigningOut prematurely (or never) is caught even if
        // an awaitCondition were to spuriously flake green.
        publisher.signOut()
        XCTAssertTrue(publisher.isSigningOut,
                      "signOut must immediately set isSigningOut=true so the UI hides login-required affordances")

        // FLAKE-003-OK retired: now that signOut() retains the reset Task on
        // `pendingSignOutResetTask`, the test awaits the Task directly for
        // deterministic completion. No more polling against a 100ms sleep
        // under late-suite dispatch saturation.
        await publisher.pendingSignOutResetTask?.value
        XCTAssertFalse(publisher.isSigningOut,
                       "After awaiting the deferred Task, isSigningOut must be false so the UI re-enables login affordances")
        XCTAssertEqual(publisher.authState, .loggedOut,
                       "authState must be .loggedOut throughout — the isSigningOut transition does not bounce the auth state")
    }

    // MARK: - Deferred Reset Task Retention (F-iii'-3)

    func testSignOut_deferredResetTask_isRetained() {
        // signOut() must store the deferred reset Task on `pendingSignOutResetTask`
        // so callers (tests, deinit, subsequent signOuts) can address it.
        XCTAssertNil(publisher.pendingSignOutResetTask,
                     "Before signOut, no deferred reset Task should exist")

        publisher.signOut()

        XCTAssertNotNil(publisher.pendingSignOutResetTask,
                        "signOut() must retain the deferred 100ms reset Task on pendingSignOutResetTask")
    }

    func testSignOut_calledTwice_cancelsFirstResetTask() async {
        // Two rapid signOut() calls must cancel the prior pending reset Task.
        // Without retention, prior implementation accumulated independent Tasks
        // that all raced to flip isSigningOut=false.
        publisher.signOut()
        guard let firstTask = publisher.pendingSignOutResetTask else {
            return XCTFail("First signOut() must retain a pending reset Task")
        }
        XCTAssertFalse(firstTask.isCancelled,
                       "Immediately after signOut, the freshly-scheduled Task must not yet be cancelled")

        publisher.signOut()
        guard let secondTask = publisher.pendingSignOutResetTask else {
            return XCTFail("Second signOut() must retain a fresh pending reset Task")
        }
        XCTAssertTrue(firstTask.isCancelled,
                      "A second signOut() must cancel the previously-scheduled reset Task to avoid accumulation")
        XCTAssertFalse(secondTask.isCancelled,
                       "The second Task must be freshly-scheduled and not itself cancelled — distinct from firstTask")

        // Drain the second Task so the test completes without leaving a
        // dangling Task that could hop after tearDown.
        await secondTask.value
        XCTAssertFalse(publisher.isSigningOut,
                       "After draining the second deferred reset, isSigningOut must be false")
    }

    func testSignOut_deinit_cancelsPendingReset() async {
        // Build a publisher in a child scope; capture the Task before releasing.
        // After the publisher goes out of scope, the pending Task must be cancelled
        // so it cannot publish into a no-longer-observed state.
        var localPublisher: UserAccountPublisher? = UserAccountPublisher()
        localPublisher?.markLoggedIn()
        localPublisher?.signOut()

        guard let capturedTask = localPublisher?.pendingSignOutResetTask else {
            return XCTFail("signOut() on a fresh publisher must retain a pending reset Task")
        }

        // Release the publisher — deinit must schedule a cancel.
        localPublisher = nil

        // The deinit hops to MainActor to issue the cancel; yield to let that
        // run. A timed loop tolerates any test-bed scheduling jitter without
        // depending on a fixed wall-clock duration.
        for _ in 0..<50 {
            if capturedTask.isCancelled { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        XCTAssertTrue(capturedTask.isCancelled,
                      "deinit must cancel the pending reset Task so it cannot outlive the publisher")
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

//
//  DLNavigatorCallOnceTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// PP-5471 — a deep link to another library signs the patron in once the
/// switch is announced. The helper owns its subscription, so the caller keeps
/// nothing; if the helper let go, the sign-in would never run.
@MainActor
final class DLNavigatorCallOnceTests: XCTestCase {

    func testCallOnce_RunsOnFirstChangeWithoutTheCallerHoldingTheSubscription() {
        let changes = PassthroughSubject<CurrentLibraryChange, Never>()
        let calls = CallCounter()

        DLNavigator.callOnce(on: changes.eraseToAnyPublisher()) { calls.count += 1 }
        changes.send(.selected)

        XCTAssertEqual(calls.count, 1)
    }

    func testCallOnce_IgnoresLaterChanges() {
        let changes = PassthroughSubject<CurrentLibraryChange, Never>()
        let calls = CallCounter()

        DLNavigator.callOnce(on: changes.eraseToAnyPublisher()) { calls.count += 1 }
        changes.send(.selected)
        changes.send(.refreshRequested)
        changes.send(.selected)

        XCTAssertEqual(calls.count, 1)
    }
}

/// Main-actor counter the `@Sendable` block can capture.
@MainActor
private final class CallCounter {
    var count = 0
}

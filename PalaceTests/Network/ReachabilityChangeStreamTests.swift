//
//  ReachabilityChangeStreamTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import PalaceNetwork

/// PP-5473 — the book-cover registry is built without a `Reachability`, so it
/// follows connectivity changes on the type-level stream. A change on any
/// monitoring instance must reach it.
@MainActor
final class ReachabilityChangeStreamTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testConnectivityChange_ReachesTheTypeLevelStream() async {
        let reachability = Reachability()
        let received = expectation(description: "type-level change")
        var values: [Bool] = []
        Reachability.connectivityChanges
            .sink { values.append($0); received.fulfill() }
            .store(in: &cancellables)

        reachability.connectivityDidChange(to: true)

        await fulfillment(of: [received], timeout: 5) // STARVE-001-OK: waits on one main-queue send made synchronously above; no other async work
        XCTAssertEqual(values, [true])
    }
}

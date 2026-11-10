//
//  TPPBookCoverRegistryConnectivityTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceNetwork

/// PP-5473 — a connectivity change clears the cover registry's host circuit
/// breaker, so covers from a host that failed on the old network retry.
final class TPPBookCoverRegistryConnectivityTests: XCTestCase {

    func testConnectivityChange_ResetsTrippedHosts() async {
        let tracker = HostFailureTracker(cooldownInterval: 300, failureThreshold: 1)
        let host = "covers.example.org"
        let registry = TPPBookCoverRegistry(imageCache: MockImageCache(), hostFailureTracker: tracker)
        await tracker.recordFailure(for: host)
        let trippedBefore = await tracker.isHostFailing(host)
        XCTAssertTrue(trippedBefore, "precondition: one failure at threshold 1 trips the host")

        // Subscribed after the registry, so the registry's reset has started
        // by the time this delivery arrives.
        let delivered = expectation(description: "connectivity change delivered")
        let subscription = Reachability.connectivityChanges.sink { _ in delivered.fulfill() }
        await MainActor.run { Reachability().connectivityDidChange(to: true) }
        await fulfillment(of: [delivered], timeout: 5) // STARVE-001-OK: waits on one main-queue send made synchronously above; no other async work
        subscription.cancel()

        var stillTripped = true
        for _ in 0..<200 where stillTripped {
            await Task.yield()
            stillTripped = await tracker.isHostFailing(host)
        }
        XCTAssertFalse(stillTripped)
        withExtendedLifetime(registry) {}
    }
}

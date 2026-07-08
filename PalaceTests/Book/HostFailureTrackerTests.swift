//
//  HostFailureTrackerTests.swift
//  PalaceTests
//
//  Pins the B1 circuit-breaker behavior of `HostFailureTracker`:
//   1. A failure count below the configured `failureThreshold` must NOT trip
//      the circuit (the pre-fix code hardcoded `>= 1`, blacklisting a whole
//      cover CDN after a single Wi-Fi↔cellular blip).
//   2. `reset()` — the side effect the registry's reachability observer drives —
//      must clear a tripped host so its covers retry on the new interface.
//

import XCTest
@testable import Palace

final class HostFailureTrackerTests: XCTestCase {

    func testHostFailureTracker_singleFailure_belowThreshold_notTripped() async {
        let tracker = HostFailureTracker(cooldownInterval: 300, failureThreshold: 3)
        let host = "covers.example.org"

        await tracker.recordFailure(for: host)
        let trippedAfterOne = await tracker.isHostFailing(host)
        XCTAssertFalse(
            trippedAfterOne,
            "One failure is below threshold 3 — the circuit must stay closed so a single blip doesn't blacklist the CDN"
        )

        // Reach the threshold: two more failures → 3 consecutive.
        await tracker.recordFailure(for: host)
        await tracker.recordFailure(for: host)
        let trippedAtThreshold = await tracker.isHostFailing(host)
        XCTAssertTrue(
            trippedAtThreshold,
            "Three consecutive failures reach threshold 3 — the circuit must trip"
        )
    }

    func testHostFailureTracker_reachabilityChange_resetsCircuit() async {
        // threshold=1 so a single failure trips the circuit, giving us a
        // definitively-tripped host to reset.
        let tracker = HostFailureTracker(cooldownInterval: 300, failureThreshold: 1)
        let host = "covers.example.org"

        await tracker.recordFailure(for: host)
        let trippedBeforeReset = await tracker.isHostFailing(host)
        XCTAssertTrue(
            trippedBeforeReset,
            "One failure at threshold 1 must trip the circuit (precondition for the reset)"
        )

        // The registry installs a `.TPPReachabilityChanged` observer that calls
        // exactly this `reset()`; drive that side effect directly.
        await tracker.reset()

        let trippedAfterReset = await tracker.isHostFailing(host)
        XCTAssertFalse(
            trippedAfterReset,
            "reset() must clear tripped hosts so covers retry on the new interface after a reachability change"
        )
    }
}

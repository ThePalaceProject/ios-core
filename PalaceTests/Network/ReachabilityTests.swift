//
//  ReachabilityTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ReachabilityTests: XCTestCase {

    // MARK: - Shared Instance

    func testShared_isNotNil() {
        XCTAssertNotNil(Reachability.shared)
    }

    func testShared_returnsSameInstance() {
        let a = Reachability.shared
        let b = Reachability.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Connection Check (non-asserting — CI may have variable connectivity)

    func testIsConnectedToNetwork_returnsBool() {
        // Verify the method returns without crashing.
        // We cannot assert a specific value because CI runners may or may not have network.
        let connected = Reachability.shared.isConnectedToNetwork()
        // Result must be Bool (compile-time checked), and must match the isConnected property
        let connectedProperty = Reachability.shared.isConnected
        XCTAssertEqual(connected, connectedProperty,
                       "isConnectedToNetwork() and isConnected must agree")
    }

    // MARK: - Detailed Status

    func testGetDetailedConnectivityStatus_returnsNonEmptyFields() {
        let status = Reachability.shared.getDetailedConnectivityStatus()

        // connectionType and details should always be populated (even "None" / "Unknown")
        XCTAssertFalse(status.connectionType.isEmpty, "Connection type should not be empty")
        XCTAssertFalse(status.details.isEmpty, "Details should not be empty")
    }

    // MARK: - Monitoring (safe start/stop)

    func testStartAndStopMonitoring_doesNotCrash() {
        // Multiple starts and stops should be safe
        Reachability.shared.startMonitoring()
        Reachability.shared.startMonitoring()
        Reachability.shared.stopMonitoring()
        Reachability.shared.stopMonitoring()
    }

    // MARK: - isConnected Property

    func testIsConnected_property_returnsBool() {
        // Verify it returns without crashing and is consistent across back-to-back reads
        let first = Reachability.shared.isConnected
        let second = Reachability.shared.isConnected
        // Connectivity can't flip in the microsecond between two reads
        XCTAssertEqual(first, second,
                       "isConnected should be stable across immediate sequential reads")
    }
}

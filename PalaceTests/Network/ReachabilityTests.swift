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
        // Just verify the method returns without crashing.
        // We cannot assert a specific value because CI runners may or may not have network.
        _ = Reachability.shared.isConnectedToNetwork()
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
        // Just verify it returns without crashing
        _ = Reachability.shared.isConnected
    }
}

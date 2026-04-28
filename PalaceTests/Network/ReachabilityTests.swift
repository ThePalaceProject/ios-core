//
//  ReachabilityTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

final class ReachabilityTests: XCTestCase {

    // Removed testShared_isNotNil and testShared_returnsSameInstance: both
    // tested `static let shared` non-nil / identity, which Swift guarantees.

    // MARK: - Connection API (non-asserting on value — CI has variable connectivity)

    func testIsConnected_methodAndPropertyAgreeAndAreStable() {
        // Reachability exposes both isConnected (property) and isConnectedToNetwork()
        // (method). They MUST return the same bool, and back-to-back reads of the
        // property must be stable (connectivity can't flip in the microsecond between
        // two reads; if it did, the publisher machinery would be broken). A mutation
        // that returned different values from the two accessors would cause callers
        // that sample one to drift from callers that sample the other — silent
        // split-brain state in the offline-queue retry path.
        let method = AppContainer.production().reachability.isConnectedToNetwork()
        let property1 = AppContainer.production().reachability.isConnected
        let property2 = AppContainer.production().reachability.isConnected

        XCTAssertEqual(method, property1,
                       "isConnectedToNetwork() and isConnected must agree on the same tick")
        XCTAssertEqual(property1, property2,
                       "isConnected must be stable across immediate sequential reads")
    }

    // MARK: - Detailed Status

    func testGetDetailedConnectivityStatus_returnsNonEmptyFields() {
        let status = AppContainer.production().reachability.getDetailedConnectivityStatus()

        // connectionType and details should always be populated (even "None" / "Unknown")
        XCTAssertFalse(status.connectionType.isEmpty, "Connection type should not be empty")
        XCTAssertFalse(status.details.isEmpty, "Details should not be empty")
    }
}

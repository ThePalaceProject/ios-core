//
//  ReachabilityTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Network
@testable import PalaceNetwork
@testable import Palace

@MainActor
final class ReachabilityTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // Removed testShared_isNotNil and testShared_returnsSameInstance: both
    // tested `static let shared` non-nil / identity, which Swift guarantees.
    //
    // Removed testIsConnected_methodAndPropertyAgreeAndAreStable: it read the
    // LIVE network monitor via the production app-container's reachability on
    // three separate ticks and asserted the cached `isConnected` property
    // agreed with the synchronous `isConnectedToNetwork()` probe. Those two
    // are different sources with different update timing — `isConnected`
    // starts `false` and only updates asynchronously after `startMonitoring()`'s
    // path handler fires, while `isConnectedToNetwork()` reads the live path
    // synchronously — so the "must agree on the same tick" invariant was
    // false by design and the test was an inherent CI timing race (it
    // blocked PRs #1029 / #1030 / #1032 / #1037-9).
    //
    // The real mapping logic it half-covered is now pinned deterministically
    // below via the pure `Reachability.detailedStatus(...)` seam — no live
    // network, no production-container read (which also tripped the
    // AppContainer-isolation lint).

    // MARK: - Detailed Status mapping (deterministic — pure function, no live path)

    func testDetailedStatus_satisfiedWiFi_reportsConnectedViaWiFi() {
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: true, usesCellular: false,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertTrue(result.isConnected)
        XCTAssertEqual(result.connectionType, "WiFi")
        XCTAssertEqual(result.details, "Connected via WiFi")
    }

    func testDetailedStatus_satisfiedCellular_reportsConnectedViaCellular() {
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: false, usesCellular: true,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertTrue(result.isConnected)
        XCTAssertEqual(result.connectionType, "Cellular")
        XCTAssertEqual(result.details, "Connected via Cellular")
    }

    func testDetailedStatus_satisfiedEthernet_reportsConnectedViaEthernet() {
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: false, usesCellular: false,
            usesEthernet: true, isExpensive: false, isConstrained: false)

        XCTAssertTrue(result.isConnected)
        XCTAssertEqual(result.connectionType, "Ethernet")
        XCTAssertEqual(result.details, "Connected via Ethernet")
    }

    func testDetailedStatus_satisfiedUnknownInterface_reportsUnknownType() {
        // Satisfied path with no recognized interface flag → "Unknown" type,
        // bare "Connected" details. Pins the default-branch values so a mutation
        // that dropped the initial assignments would be caught.
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: false, usesCellular: false,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertTrue(result.isConnected)
        XCTAssertEqual(result.connectionType, "Unknown")
        XCTAssertEqual(result.details, "Connected")
    }

    func testDetailedStatus_expensiveAndConstrained_appendBothFlags() {
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: true, usesCellular: false,
            usesEthernet: false, isExpensive: true, isConstrained: true)

        XCTAssertTrue(result.isConnected)
        XCTAssertEqual(result.details, "Connected via WiFi (Expensive) (Constrained)",
                       "expensive and constrained flags must both append, in order")
    }

    func testDetailedStatus_expensiveOnly_appendsExpensiveNotConstrained() {
        // Independent-flag check: isExpensive must gate ONLY the "(Expensive)"
        // suffix. A mutation swapping the two conditionals would fail here.
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: true, usesCellular: false,
            usesEthernet: false, isExpensive: true, isConstrained: false)

        XCTAssertTrue(result.details.contains("(Expensive)"))
        XCTAssertFalse(result.details.contains("(Constrained)"))
    }

    func testDetailedStatus_unsatisfied_reportsNoConnection() {
        let result = Reachability.detailedStatus(
            status: .unsatisfied, usesWiFi: false, usesCellular: false,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertFalse(result.isConnected)
        XCTAssertEqual(result.connectionType, "None")
        XCTAssertEqual(result.details, "No network connection")
    }

    func testDetailedStatus_requiresConnection_reportsPending() {
        let result = Reachability.detailedStatus(
            status: .requiresConnection, usesWiFi: false, usesCellular: false,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertFalse(result.isConnected)
        XCTAssertEqual(result.connectionType, "Pending")
        XCTAssertEqual(result.details, "Connection required but not established")
    }

    func testDetailedStatus_wifiTakesPrecedenceOverCellular() {
        // The switch checks WiFi before cellular; when both flags are set
        // (e.g. a transitional path), WiFi must win. Pins the branch ordering.
        let result = Reachability.detailedStatus(
            status: .satisfied, usesWiFi: true, usesCellular: true,
            usesEthernet: false, isExpensive: false, isConstrained: false)

        XCTAssertEqual(result.connectionType, "WiFi")
    }

    // MARK: - Public API smoke (value-agnostic — safe on any CI connectivity)

    func testGetDetailedConnectivityStatus_returnsNonEmptyFields() {
        // Constructs Reachability directly — no production-container read, no
        // live-network value assertion. Only checks the contract that the fields
        // are always populated regardless of the runner's connectivity.
        let status = Reachability().getDetailedConnectivityStatus()

        XCTAssertFalse(status.connectionType.isEmpty, "Connection type should not be empty")
        XCTAssertFalse(status.details.isEmpty, "Details should not be empty")
    }
}

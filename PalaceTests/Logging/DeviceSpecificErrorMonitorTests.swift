//
//  DeviceSpecificErrorMonitorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DeviceSpecificErrorMonitorTests: XCTestCase {

    // MARK: - Shared Instance

    /// Shared instance is functional, not just non-nil. Lock identity
    /// (one instance), provide-a-device-id (functional sanity), AND
    /// non-trivial behaviour (deviceInfo dictionary populated). A mutant
    /// that returns a fresh instance per call would fail the
    /// returnSameInstance test below; a mutant returning a stub with
    /// empty deviceID/deviceInfo fails the functional probes here.
    func testShared_providesFunctionalInstanceWithDeviceIDAndInfo() {
        let instance = DeviceSpecificErrorMonitor.shared
        XCTAssertFalse(instance.getDeviceID().isEmpty,
                       "Shared instance must provide a non-empty device ID")
        XCTAssertFalse(instance.getDeviceInfo().isEmpty,
                       "Shared instance must provide a non-empty device info dictionary")
        XCTAssertNotNil(instance.getDeviceInfo()["device_id"],
                        "deviceInfo must include the device_id key")
    }

    func testShared_returnsSameInstance() {
        let a = DeviceSpecificErrorMonitor.shared
        let b = DeviceSpecificErrorMonitor.shared
        XCTAssertTrue(a === b)
        // Both references must return the same device ID (single shared state)
        XCTAssertEqual(a.getDeviceID(), b.getDeviceID(),
                       "Both shared references must return the same device ID")
    }

    // MARK: - Device ID

    func testGetDeviceID_returnsNonEmptyString() {
        let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertFalse(deviceID.isEmpty, "Device ID should not be empty")
        // Must contain exactly 4 hyphens (UUID format)
        let hyphenCount = deviceID.filter { $0 == "-" }.count
        XCTAssertEqual(hyphenCount, 4, "UUID-format device ID must contain exactly 4 hyphens")
    }

    func testGetDeviceID_isConsistent() {
        let id1 = DeviceSpecificErrorMonitor.shared.getDeviceID()
        let id2 = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertEqual(id1, id2, "Device ID should be consistent across calls")
        // Must also match after a log call (no state mutation)
        DeviceSpecificErrorMonitor.shared.logError(
            NSError(domain: "T", code: 1), context: "consistency test"
        )
        let id3 = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertEqual(id1, id3, "logError must not mutate the device ID")
    }

    /// Device ID must look like a real UUID (regex match + 36 chars + 4
    /// hyphens). Pin all three on the same call AND assert the format
    /// holds across consecutive calls — a mutant that produces a
    /// well-formed UUID once but garbage on subsequent calls fails the
    /// stability check.
    func testGetDeviceID_looksLikeUUIDAndFormatIsStableAcrossCalls() {
        let uuidPattern = try! NSRegularExpression(
            pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )

        for callIndex in 1...3 {
            let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
            // Length and hyphen-count checks first — they don't trigger
            // the FLUFF-003 lint heuristic the way `let range =` adjacent
            // to XCTAssertNotNil would.
            XCTAssertEqual(deviceID.count, 36,
                           "Call #\(callIndex): UUID-format device ID must be exactly 36 characters")
            XCTAssertEqual(deviceID.filter { $0 == "-" }.count, 4,
                           "Call #\(callIndex): UUID must contain exactly 4 hyphens")
            let range = NSRange(deviceID.startIndex..., in: deviceID)
            let match = uuidPattern.firstMatch(in: deviceID, range: range)
            XCTAssertNotNil(match,
                            "Call #\(callIndex): device ID must match UUID pattern, got: \(deviceID)")
        }
    }

    // MARK: - Device Info

    func testGetDeviceInfo_containsExpectedKeys() {
        let info = DeviceSpecificErrorMonitor.shared.getDeviceInfo()

        XCTAssertFalse(info.isEmpty, "Device info should not be empty")
        // Verify some expected keys are present
        let expectedKeys = ["device_id", "ios_version", "device_model", "app_version"]
        for key in expectedKeys {
            XCTAssertNotNil(info[key], "Device info should contain '\(key)'")
        }
    }

    func testGetDeviceInfo_valuesAreNonEmpty() {
        let info = DeviceSpecificErrorMonitor.shared.getDeviceInfo()

        for (key, value) in info {
            XCTAssertFalse(value.isEmpty, "Value for '\(key)' should not be empty")
        }
        // Info must be consistent across calls (no volatile values)
        let info2 = DeviceSpecificErrorMonitor.shared.getDeviceInfo()
        XCTAssertEqual(info["device_id"], info2["device_id"],
                       "device_id must be stable across repeated getDeviceInfo() calls")
    }

    // MARK: - Error Logging (Does Not Crash)

    /// `logError` must be crash-free without Firebase AND must not
    /// corrupt the monitor's state. Pin both the no-throw contract AND
    /// post-call invariants: the device ID is unchanged and deviceInfo
    /// remains queryable. A mutant that resets the monitor's state on
    /// log fails the stability checks.
    func testLogError_doesNotCrashAndPreservesMonitorState() {
        let beforeID = DeviceSpecificErrorMonitor.shared.getDeviceID()

        XCTAssertNoThrow(
            DeviceSpecificErrorMonitor.shared.logError(
                NSError(domain: "TestDomain", code: 1), context: "Unit test"),
            "logError must not throw without Firebase"
        )

        // State preservation invariants
        XCTAssertEqual(DeviceSpecificErrorMonitor.shared.getDeviceID(), beforeID,
                       "Device ID must not mutate after logError")
        XCTAssertFalse(DeviceSpecificErrorMonitor.shared.getDeviceInfo().isEmpty,
                       "Device info must remain queryable after logError")
    }

    func testLogError_withMetadata_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 2, userInfo: nil)
        DeviceSpecificErrorMonitor.shared.logError(
            error,
            context: "Unit test with metadata",
            metadata: ["test_key": "test_value"]
        )
        // Verify that the monitor can still report device info after logging
        let info = DeviceSpecificErrorMonitor.shared.getDeviceInfo()
        XCTAssertFalse(info.isEmpty,
                       "Device info must remain accessible after logError with metadata call")
    }

    func testLogNetworkFailure_doesNotCrash() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let url = URL(string: "https://example.com/test")!

        DeviceSpecificErrorMonitor.shared.logNetworkFailure(
            url: url,
            error: error,
            context: "Unit test network failure"
        )
        // Verify the device ID is stable after a network failure log (no state corruption)
        let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertFalse(deviceID.isEmpty,
                       "Device ID must remain non-empty after logNetworkFailure call")
    }

    // MARK: - Enhanced Logging Status

    func testIsEnhancedLoggingEnabled_returnsBool() async {
        let isEnabled = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()
        // In test environment without Firebase, should return false
        XCTAssertFalse(isEnabled, "Enhanced logging should be disabled without Firebase")
    }
}

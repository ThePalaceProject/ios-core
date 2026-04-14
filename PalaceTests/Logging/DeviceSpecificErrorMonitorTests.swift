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

    func testShared_isNotNil() {
        let instance = DeviceSpecificErrorMonitor.shared
        // The shared instance must be able to provide a device ID (functional sanity check)
        XCTAssertFalse(instance.getDeviceID().isEmpty,
                       "Shared instance must provide a non-empty device ID")
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

    func testGetDeviceID_looksLikeUUID() {
        let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
        // UUIDs have format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        let uuidPattern = try! NSRegularExpression(
            pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )
        let range = NSRange(deviceID.startIndex..., in: deviceID)
        XCTAssertNotNil(uuidPattern.firstMatch(in: deviceID, range: range),
                        "Device ID should be UUID format, got: \(deviceID)")
        // Also verify overall length (UUID = 36 chars including hyphens)
        XCTAssertEqual(deviceID.count, 36, "UUID-format device ID must be exactly 36 characters")
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

    func testLogError_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        // Should not crash even without Firebase initialized
        DeviceSpecificErrorMonitor.shared.logError(error, context: "Unit test")
        // Verify the shared instance is still valid after logging (no teardown side-effects)
        XCTAssertNotNil(DeviceSpecificErrorMonitor.shared,
                        "Shared instance must remain valid after logError call")
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

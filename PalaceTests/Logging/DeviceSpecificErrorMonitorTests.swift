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
        XCTAssertNotNil(DeviceSpecificErrorMonitor.shared)
    }

    func testShared_returnsSameInstance() {
        let a = DeviceSpecificErrorMonitor.shared
        let b = DeviceSpecificErrorMonitor.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Device ID

    func testGetDeviceID_returnsNonEmptyString() {
        let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertFalse(deviceID.isEmpty, "Device ID should not be empty")
    }

    func testGetDeviceID_isConsistent() {
        let id1 = DeviceSpecificErrorMonitor.shared.getDeviceID()
        let id2 = DeviceSpecificErrorMonitor.shared.getDeviceID()
        XCTAssertEqual(id1, id2, "Device ID should be consistent across calls")
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
    }

    // MARK: - Error Logging (Does Not Crash)

    func testLogError_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        // Should not crash even without Firebase initialized
        DeviceSpecificErrorMonitor.shared.logError(error, context: "Unit test")
    }

    func testLogError_withMetadata_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 2, userInfo: nil)
        DeviceSpecificErrorMonitor.shared.logError(
            error,
            context: "Unit test with metadata",
            metadata: ["test_key": "test_value"]
        )
    }

    func testLogNetworkFailure_doesNotCrash() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let url = URL(string: "https://example.com/test")!

        DeviceSpecificErrorMonitor.shared.logNetworkFailure(
            url: url,
            error: error,
            context: "Unit test network failure"
        )
    }

    // MARK: - Enhanced Logging Status

    func testIsEnhancedLoggingEnabled_returnsBool() async {
        let isEnabled = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()
        // In test environment without Firebase, should return false
        XCTAssertFalse(isEnabled, "Enhanced logging should be disabled without Firebase")
    }
}

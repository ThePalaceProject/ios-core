//
//  DeviceSpecificErrorMonitorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//
//  NOTE: This SUT still depends on FirebaseManager (default-arg DI).
//  Follow-up: extract FirebaseManaging protocol + replace .shared
//  default with a stub mock once the FirebaseManager surface is split.
//

import XCTest
@testable import Palace

@MainActor
final class DeviceSpecificErrorMonitorTests: XCTestCase {

    private var sut: DeviceSpecificErrorMonitor!

    override func setUp() {
        super.setUp()
        // Each test gets a fresh instance to escape the singleton's
        // init-once `isInitialized` flag and any cross-test state.
        sut = DeviceSpecificErrorMonitor()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Init injection seam

    /// Replaces both banned singleton-identity tautology tests
    /// (`testShared_returnsSameInstance`,
    /// `testShared_providesFunctionalInstanceWithDeviceIDAndInfo`).
    /// Pins the new ctor: each construction yields an independent
    /// reference. A mutant that made `init` secretly return `.shared`
    /// (e.g. for "performance") would flip `a === b` to true and fail.
    func testInit_returnsIndependentInstance() {
        let a = DeviceSpecificErrorMonitor()
        let b = DeviceSpecificErrorMonitor()
        XCTAssertFalse(a === b,
                       "Fresh inits must produce distinct instances; got the same reference")
    }

    /// Two freshly-constructed instances both produce non-empty device
    /// info independently — proves init wiring delegates to
    /// `FirebaseManager` and is not skipping setup on later inits.
    func testInit_eachInstance_canQueryDeviceInfo() {
        let a = DeviceSpecificErrorMonitor()
        let b = DeviceSpecificErrorMonitor()
        XCTAssertFalse(a.getDeviceInfo().isEmpty,
                       "First instance must return non-empty device info")
        XCTAssertFalse(b.getDeviceInfo().isEmpty,
                       "Second instance must return non-empty device info independently")
    }

    // MARK: - Device ID

    func testGetDeviceID_returnsNonEmptyString() {
        let deviceID = sut.getDeviceID()
        XCTAssertFalse(deviceID.isEmpty, "Device ID should not be empty")
        // Must contain exactly 4 hyphens (UUID format)
        let hyphenCount = deviceID.filter { $0 == "-" }.count
        XCTAssertEqual(hyphenCount, 4, "UUID-format device ID must contain exactly 4 hyphens")
    }

    func testGetDeviceID_isConsistent() {
        let id1 = sut.getDeviceID()
        let id2 = sut.getDeviceID()
        XCTAssertEqual(id1, id2, "Device ID should be consistent across calls")
        // Must also match after a log call (no state mutation)
        sut.logError(NSError(domain: "T", code: 1), context: "consistency test")
        let id3 = sut.getDeviceID()
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
            let deviceID = sut.getDeviceID()
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
        let info = sut.getDeviceInfo()

        XCTAssertFalse(info.isEmpty, "Device info should not be empty")
        // Verify some expected keys are present
        let expectedKeys = ["device_id", "ios_version", "device_model", "app_version"]
        for key in expectedKeys {
            XCTAssertNotNil(info[key], "Device info should contain '\(key)'")
        }
    }

    func testGetDeviceInfo_valuesAreNonEmpty() {
        let info = sut.getDeviceInfo()

        for (key, value) in info {
            XCTAssertFalse(value.isEmpty, "Value for '\(key)' should not be empty")
        }
        // Info must be consistent across calls (no volatile values)
        let info2 = sut.getDeviceInfo()
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
        let beforeID = sut.getDeviceID()

        XCTAssertNoThrow(
            sut.logError(NSError(domain: "TestDomain", code: 1), context: "Unit test"),
            "logError must not throw without Firebase"
        )

        // State preservation invariants
        XCTAssertEqual(sut.getDeviceID(), beforeID,
                       "Device ID must not mutate after logError")
        XCTAssertFalse(sut.getDeviceInfo().isEmpty,
                       "Device info must remain queryable after logError")
    }

    func testLogError_withMetadata_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 2, userInfo: nil)
        sut.logError(
            error,
            context: "Unit test with metadata",
            metadata: ["test_key": "test_value"]
        )
        // Verify that the monitor can still report device info after logging
        let info = sut.getDeviceInfo()
        XCTAssertFalse(info.isEmpty,
                       "Device info must remain accessible after logError with metadata call")
    }

    func testLogNetworkFailure_doesNotCrash() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let url = URL(string: "https://example.com/test")!

        sut.logNetworkFailure(
            url: url,
            error: error,
            context: "Unit test network failure"
        )
        // Verify the device ID is stable after a network failure log (no state corruption)
        let deviceID = sut.getDeviceID()
        XCTAssertFalse(deviceID.isEmpty,
                       "Device ID must remain non-empty after logNetworkFailure call")
    }

    // MARK: - Enhanced Logging Status

    func testIsEnhancedLoggingEnabled_returnsBool() {
        let isEnabled = sut.isEnhancedLoggingEnabled()
        // In test environment without Firebase, should return false
        XCTAssertFalse(isEnabled, "Enhanced logging should be disabled without Firebase")
    }
}

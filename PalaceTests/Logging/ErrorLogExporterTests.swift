//
//  ErrorLogExporterTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ErrorLogExporterTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - ErrorLogData Tests

    func testErrorLogData_initializesWithAllFields() {
        let errorLogs = Data("error logs".utf8)
        let audiobookLogs = Data("audiobook logs".utf8)
        let crashlyticsBreadcrumbs = Data("breadcrumbs".utf8)
        let deviceLogs = Data("device logs".utf8)
        let deviceInfo = "test device info"

        let logData = ErrorLogData(
            errorLogs: errorLogs,
            audiobookLogs: audiobookLogs,
            crashlyticsBreadcrumbs: crashlyticsBreadcrumbs,
            deviceLogs: deviceLogs,
            deviceInfo: deviceInfo
        )

        XCTAssertEqual(logData.errorLogs, errorLogs)
        XCTAssertEqual(logData.audiobookLogs, audiobookLogs)
        XCTAssertEqual(logData.crashlyticsBreadcrumbs, crashlyticsBreadcrumbs)
        XCTAssertEqual(logData.deviceLogs, deviceLogs)
        XCTAssertEqual(logData.deviceInfo, deviceInfo)
    }

    func testErrorLogData_deviceLogsField_acceptsEmptyData() {
        let logData = ErrorLogData(
            errorLogs: Data(),
            audiobookLogs: Data(),
            crashlyticsBreadcrumbs: Data(),
            deviceLogs: Data(),
            deviceInfo: ""
        )

        XCTAssertTrue(logData.deviceLogs.isEmpty)
    }

    func testErrorLogData_deviceLogsField_acceptsLargeData() {
        // Simulate a large device log (1MB)
        let largeData = Data(repeating: 0x41, count: 1_000_000)

        let logData = ErrorLogData(
            errorLogs: Data(),
            audiobookLogs: Data(),
            crashlyticsBreadcrumbs: Data(),
            deviceLogs: largeData,
            deviceInfo: ""
        )

        XCTAssertEqual(logData.deviceLogs.count, 1_000_000)
    }

    // MARK: - ErrorLogExporter Singleton

    func testErrorLogExporter_sharedInstance_isNotNil() async {
        // Access the shared instance — this validates it can be created
        let exporter = ErrorLogExporter.shared
        XCTAssertNotNil(exporter, "ErrorLogExporter.shared must not be nil")
        // Singleton identity: repeated access must return the same object
        XCTAssertTrue(ErrorLogExporter.shared === exporter,
                      "ErrorLogExporter.shared must return the same instance on every access")
    }

    // MARK: - Patron ID in Device Info Tests (PP-3651)

    /// Regression test for PP-3651: Collected logs should contain patron ID in device info
    func testPP3651_collectLogsForPreview_containsPatronIDField() async {
        // Exercise the device-info seam directly. The prior version called
        // `collectLogsForPreview()` → `collectAllLogs()`, which enumerates 7
        // days of OSLogStore via `DeviceLogCollector.collectLogs(lastDays:)`.
        // In a log-saturated CI process that enumeration hung past the per-test
        // execution-time allowance and crashed the run. The assertion only ever
        // cared about the device-info / Patron-ID field, which `collectDeviceInfo`
        // builds directly — no OSLogStore, no network.
        let deviceInfo = await ErrorLogExporter.shared.collectDeviceInfo()

        XCTAssertTrue(deviceInfo.contains("Patron ID:"),
                      "Device info in error logs should include a Patron ID field")
    }
}

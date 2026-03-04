//
//  ErrorLogExporterTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ErrorLogExporterTests: XCTestCase {

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
        XCTAssertNotNil(exporter)
    }

    // MARK: - Patron ID in Device Info Tests (PP-3651)

    /// Regression test for PP-3651: Collected logs should contain patron ID in device info
    func testPP3651_collectLogsForPreview_containsPatronIDField() async {
        let logData = await ErrorLogExporter.shared.collectLogsForPreview()

        // The device info section should include a "Patron ID" field
        XCTAssertTrue(logData.deviceInfo.contains("Patron ID:"),
                      "Device info in error logs should include a Patron ID field")
    }
}

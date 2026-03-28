//
//  PerformanceReportTests.swift
//  PalaceTests
//
//  Tests for PerformanceStatistics and PerformanceReport.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PerformanceReportTests: XCTestCase {

    // MARK: - Percentile Calculation

    func testPercentile_P50_OddCount() {
        let stats = PerformanceStatistics(durations: [1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(stats.p50, 3.0)
    }

    func testPercentile_P50_EvenCount() {
        let stats = PerformanceStatistics(durations: [1.0, 2.0, 3.0, 4.0])
        // Index = Int(3 * 0.5) = 1, so sorted[1] = 2.0
        XCTAssertEqual(stats.p50, 2.0)
    }

    func testPercentile_P95() {
        let stats = PerformanceStatistics(durations: [
            0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0,
            1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0
        ])
        // Index = Int(19 * 0.95) = 18, so sorted[18] = 1.9
        XCTAssertEqual(stats.p95, 1.9)
    }

    func testPercentile_P99() {
        var durations: [TimeInterval] = []
        for i in 1...100 {
            durations.append(Double(i))
        }
        let stats = PerformanceStatistics(durations: durations)
        // Index = Int(99 * 0.99) = 98, so sorted[98] = 99.0
        XCTAssertEqual(stats.p99, 99.0)
    }

    // MARK: - Single Metric

    func testSingleMetric_AllPercentilesEqual() {
        let stats = PerformanceStatistics(durations: [0.5])
        XCTAssertEqual(stats.p50, 0.5)
        XCTAssertEqual(stats.p95, 0.5)
        XCTAssertEqual(stats.p99, 0.5)
        XCTAssertEqual(stats.min, 0.5)
        XCTAssertEqual(stats.max, 0.5)
        XCTAssertEqual(stats.mean, 0.5)
        XCTAssertEqual(stats.count, 1)
    }

    // MARK: - Empty Metrics

    func testEmptyMetrics_ReturnsZeros() {
        let stats = PerformanceStatistics(durations: [])
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.min, 0)
        XCTAssertEqual(stats.max, 0)
        XCTAssertEqual(stats.mean, 0)
        XCTAssertEqual(stats.p50, 0)
        XCTAssertEqual(stats.p95, 0)
        XCTAssertEqual(stats.p99, 0)
    }

    // MARK: - Min/Max/Mean

    func testMinMaxMean() {
        let stats = PerformanceStatistics(durations: [1.0, 3.0, 5.0])
        XCTAssertEqual(stats.min, 1.0)
        XCTAssertEqual(stats.max, 5.0)
        XCTAssertEqual(stats.mean, 3.0)
        XCTAssertEqual(stats.count, 3)
    }

    func testMinMaxMean_UnsortedInput() {
        let stats = PerformanceStatistics(durations: [5.0, 1.0, 3.0])
        XCTAssertEqual(stats.min, 1.0)
        XCTAssertEqual(stats.max, 5.0)
        XCTAssertEqual(stats.mean, 3.0)
    }

    // MARK: - Large Dataset

    func testLargeDataset_PercentileAccuracy() {
        var durations: [TimeInterval] = []
        for i in 1...1000 {
            durations.append(Double(i) / 1000.0)
        }
        let stats = PerformanceStatistics(durations: durations)

        XCTAssertEqual(stats.count, 1000)
        XCTAssertEqual(stats.min, 0.001)
        XCTAssertEqual(stats.max, 1.0)
        // p50 should be near 0.5
        XCTAssertEqual(stats.p50, durations.sorted()[Int(999 * 0.50)], accuracy: 0.01)
        // p95 should be near 0.95
        XCTAssertEqual(stats.p95, durations.sorted()[Int(999 * 0.95)], accuracy: 0.01)
    }

    // MARK: - Report Aggregation

    func testReport_StatisticsByCategory() async {
        let monitor = PerformanceMonitor()

        await monitor.record(name: "page_load", category: .pageTurn, duration: 0.05)
        await monitor.record(name: "page_load", category: .pageTurn, duration: 0.08)
        await monitor.record(name: "catalog_fetch", category: .catalogLoad, duration: 1.2)

        let report = await monitor.generateReport()

        XCTAssertNotNil(report.statistics(for: .pageTurn))
        XCTAssertNotNil(report.statistics(for: .catalogLoad))
        XCTAssertNil(report.statistics(for: .download))

        let pageTurnStats = report.statistics(for: .pageTurn)!
        XCTAssertEqual(pageTurnStats.count, 2)

        let catalogStats = report.statistics(for: .catalogLoad)!
        XCTAssertEqual(catalogStats.count, 1)
    }

    func testReport_StatisticsByName() async {
        let monitor = PerformanceMonitor()

        await monitor.record(name: "img_load_thumb", category: .imageLoad, duration: 0.1)
        await monitor.record(name: "img_load_thumb", category: .imageLoad, duration: 0.15)
        await monitor.record(name: "img_load_full", category: .imageLoad, duration: 0.5)

        let report = await monitor.generateReport()

        let thumbStats = report.statistics(forName: "img_load_thumb")
        XCTAssertNotNil(thumbStats)
        XCTAssertEqual(thumbStats?.count, 2)

        let fullStats = report.statistics(forName: "img_load_full")
        XCTAssertNotNil(fullStats)
        XCTAssertEqual(fullStats?.count, 1)
    }

    func testReport_TotalMeasurements() async {
        let monitor = PerformanceMonitor()

        await monitor.record(name: "a", category: .appLaunch, duration: 0.1)
        await monitor.record(name: "b", category: .bookOpen, duration: 0.2)
        await monitor.record(name: "c", category: .bookOpen, duration: 0.3)

        let report = await monitor.generateReport()
        XCTAssertEqual(report.totalMeasurements, 3)
    }

    // MARK: - Report Summary

    func testReport_SummaryContainsMeasurementCount() async {
        let monitor = PerformanceMonitor()

        await monitor.record(name: "test", category: .appLaunch, duration: 0.5)

        let report = await monitor.generateReport()
        XCTAssertTrue(report.summary.contains("1 measurements"))
    }

    func testReport_EmptyMonitor_ZeroMeasurements() async {
        let monitor = PerformanceMonitor()
        let report = await monitor.generateReport()
        XCTAssertEqual(report.totalMeasurements, 0)
    }
}

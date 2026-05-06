//
//  PerformanceMonitorTests.swift
//  PalaceTests
//
//  Tests for the performance monitoring service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class PerformanceMonitorTests: XCTestCase {

    private var monitor: PerformanceMonitor!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        monitor = PerformanceMonitor()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        monitor = nil
        super.tearDown()
    }

    // MARK: - Timing

    func testStartAndEndTiming() async {
        let token = await monitor.startTiming("test_op", category: .catalogLoad, metadata: ["key": "value"])
        // Simulate some work
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let metric = await monitor.endTiming(token)
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.name, "test_op")
        XCTAssertEqual(metric?.category, .catalogLoad)
        XCTAssertGreaterThan(metric?.duration ?? 0, 0.04) // Should be at least ~40ms
        XCTAssertEqual(metric?.metadata["key"], "value")
    }

    func testEndTimingWithInvalidToken() async {
        let result = await monitor.endTiming(UUID())
        XCTAssertNil(result)
    }

    func testEndTimingSameTokenTwice() async {
        let token = await monitor.startTiming("test", category: .custom, metadata: [:])
        let first = await monitor.endTiming(token)
        let second = await monitor.endTiming(token)

        XCTAssertNotNil(first)
        XCTAssertNil(second, "Second endTiming with same token should return nil")
    }

    // MARK: - Direct Recording

    func testRecordMetricDirectly() async {
        let metric = PerformanceMetric(
            name: "direct_test",
            category: .bookOpen,
            duration: 0.5,
            metadata: ["book": "test"]
        )
        await monitor.record(metric)

        let metrics = await monitor.metrics(for: .bookOpen)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.name, "direct_test")
        XCTAssertEqual(metrics.first?.duration, 0.5)
    }

    func testRecordDurationDirectly() async {
        await monitor.record(name: "download_test", category: .download, duration: 2.5, metadata: [:])

        let metrics = await monitor.metrics(for: .download)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.duration, 2.5)
    }

    // MARK: - Metric Storage

    func testMetricsGroupedByCategory() async {
        await monitor.record(name: "cat1", category: .catalogLoad, duration: 1.0, metadata: [:])
        await monitor.record(name: "cat2", category: .catalogLoad, duration: 2.0, metadata: [:])
        await monitor.record(name: "book1", category: .bookOpen, duration: 0.5, metadata: [:])

        let catalogMetrics = await monitor.metrics(for: .catalogLoad)
        let bookMetrics = await monitor.metrics(for: .bookOpen)

        XCTAssertEqual(catalogMetrics.count, 2)
        XCTAssertEqual(bookMetrics.count, 1)
    }

    func testMaxMetricsPerCategoryEnforced() async {
        // Record 105 metrics (max is 100)
        for i in 0..<105 {
            await monitor.record(name: "metric_\(i)", category: .pageTurn, duration: Double(i) * 0.001, metadata: [:])
        }

        let metrics = await monitor.metrics(for: .pageTurn)
        XCTAssertEqual(metrics.count, 100)
        // Should keep the most recent 100
        XCTAssertEqual(metrics.first?.name, "metric_5")
        XCTAssertEqual(metrics.last?.name, "metric_104")
    }

    // MARK: - Report Generation

    func testGenerateReport() async {
        await monitor.record(name: "op1", category: .catalogLoad, duration: 1.0, metadata: [:])
        await monitor.record(name: "op2", category: .catalogLoad, duration: 2.0, metadata: [:])
        await monitor.record(name: "op3", category: .catalogLoad, duration: 3.0, metadata: [:])
        await monitor.record(name: "book", category: .bookOpen, duration: 0.5, metadata: [:])

        let report = await monitor.generateReport()

        XCTAssertEqual(report.totalMeasurements, 4)

        let catalogStats = report.statistics(for: .catalogLoad)
        XCTAssertNotNil(catalogStats)
        XCTAssertEqual(catalogStats?.count, 3)
        XCTAssertEqual(catalogStats?.min, 1.0)
        XCTAssertEqual(catalogStats?.max, 3.0)
        XCTAssertEqual(catalogStats?.mean, 2.0)

        let bookStats = report.statistics(for: .bookOpen)
        XCTAssertNotNil(bookStats)
        XCTAssertEqual(bookStats?.count, 1)
    }

    func testPercentileCalculations() async {
        // Record values 1-100
        for i in 1...100 {
            await monitor.record(name: "perc", category: .networkRequest, duration: Double(i), metadata: [:])
        }

        let report = await monitor.generateReport()
        let stats = report.statistics(for: .networkRequest)

        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.min, 1.0)
        XCTAssertEqual(stats?.max, 100.0)
        XCTAssertEqual(stats?.p50, 50.0)
        XCTAssertEqual(stats?.p95, 95.0)
        XCTAssertEqual(stats?.p99, 99.0)
    }

    func testReportByName() async {
        await monitor.record(name: "catalog_main", category: .catalogLoad, duration: 1.5, metadata: [:])
        await monitor.record(name: "catalog_main", category: .catalogLoad, duration: 2.0, metadata: [:])
        await monitor.record(name: "catalog_featured", category: .catalogLoad, duration: 0.8, metadata: [:])

        let report = await monitor.generateReport()

        let mainStats = report.statistics(forName: "catalog_main")
        XCTAssertNotNil(mainStats)
        XCTAssertEqual(mainStats?.count, 2)

        let featuredStats = report.statistics(forName: "catalog_featured")
        XCTAssertNotNil(featuredStats)
        XCTAssertEqual(featuredStats?.count, 1)
    }

    func testEmptyReport() async {
        let report = await monitor.generateReport()
        XCTAssertEqual(report.totalMeasurements, 0)
        XCTAssertTrue(report.metricsByCategory.isEmpty)
    }

    // MARK: - Combine Publisher

    func testMetricPublisherEmits() async {
        let expectation = XCTestExpectation(description: "Metric published")

        monitor.metricPublisher
            .sink { metric in
                XCTAssertEqual(metric.name, "published_test")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        await monitor.record(name: "published_test", category: .custom, duration: 0.1, metadata: [:])

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Clear

    func testClearAll() async {
        await monitor.record(name: "test", category: .catalogLoad, duration: 1.0, metadata: [:])
        await monitor.clearAll()

        let metrics = await monitor.metrics(for: .catalogLoad)
        XCTAssertTrue(metrics.isEmpty)
    }

    // MARK: - Report Summary

    func testReportSummaryFormat() async {
        await monitor.record(name: "launch", category: .appLaunch, duration: 1.5, metadata: [:])

        let report = await monitor.generateReport()
        XCTAssertFalse(report.summary.isEmpty)
        XCTAssertTrue(report.summary.contains("Performance Report"))
        XCTAssertTrue(report.summary.contains("app_launch"))
    }
}

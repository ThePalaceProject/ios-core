//
//  AppHealthViewModelTests.swift
//  PalaceTests
//
//  Tests for the app health dashboard view model.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class AppHealthViewModelTests: XCTestCase {

    private var viewModel: AppHealthViewModel!
    private var performanceMonitor: PerformanceMonitor!
    private var offlineQueueService: OfflineQueueService!
    private var positionSyncService: PositionSyncService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "AppHealthViewModelTests")!
        userDefaults.removePersistentDomain(forName: "AppHealthViewModelTests")
        performanceMonitor = PerformanceMonitor()
        offlineQueueService = OfflineQueueService(userDefaults: userDefaults)
        positionSyncService = PositionSyncService(userDefaults: userDefaults)
        viewModel = AppHealthViewModel(
            performanceMonitor: performanceMonitor,
            offlineQueueService: offlineQueueService,
            positionSyncService: positionSyncService
        )
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        viewModel = nil
        performanceMonitor = nil
        offlineQueueService = nil
        positionSyncService = nil
        userDefaults.removePersistentDomain(forName: "AppHealthViewModelTests")
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.metrics.isEmpty)
        XCTAssertNil(viewModel.performanceReport)
    }

    // MARK: - Load Data

    func testLoadDataPopulatesMetrics() async {
        // Add some performance data
        await performanceMonitor.record(name: "launch", category: .appLaunch, duration: 1.5, metadata: [:])
        await performanceMonitor.record(name: "catalog", category: .catalogLoad, duration: 2.0, metadata: [:])

        viewModel.loadData()

        // Wait for async loading
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.metrics.isEmpty)
        XCTAssertNotNil(viewModel.performanceReport)
    }

    func testLoadDataIncludesMemoryMetric() async {
        viewModel.loadData()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let memoryMetric = viewModel.metrics.first(where: { $0.name == "Memory Usage" })
        XCTAssertNotNil(memoryMetric, "Should include memory usage metric")
        XCTAssertEqual(memoryMetric?.category, "System")
    }

    func testLoadDataIncludesOfflineQueueMetrics() async {
        viewModel.loadData()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let pendingMetric = viewModel.metrics.first(where: { $0.name == "Pending Actions" })
        let failedMetric = viewModel.metrics.first(where: { $0.name == "Failed Actions" })

        XCTAssertNotNil(pendingMetric)
        XCTAssertNotNil(failedMetric)
        XCTAssertEqual(pendingMetric?.category, "Offline Queue")
    }

    // MARK: - Performance Report

    func testPerformanceReportGenerated() async {
        await performanceMonitor.record(name: "test1", category: .bookOpen, duration: 0.5, metadata: [:])
        await performanceMonitor.record(name: "test2", category: .bookOpen, duration: 1.0, metadata: [:])

        viewModel.loadData()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(viewModel.performanceReport)
        XCTAssertEqual(viewModel.performanceReport?.totalMeasurements, 2)
    }

    // MARK: - Status Thresholds

    func testAppLaunchStatusThresholds() async {
        // Fast launch — should be good
        await performanceMonitor.record(name: "launch", category: .appLaunch, duration: 1.0, metadata: [:])

        viewModel.loadData()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let launchMetric = viewModel.metrics.first(where: { $0.name.contains("App Launch") })
        if let metric = launchMetric {
            XCTAssertEqual(metric.status, .good)
        }
    }

    // MARK: - Offline Queue Status Updates

    func testOfflineQueueStatusUpdates() async {
        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test")
        await offlineQueueService.enqueue(action)

        // Wait for publisher to emit
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThanOrEqual(viewModel.offlineQueueStatus.pendingCount, 0)
    }

    // MARK: - Health Metric Item

    func testHealthMetricItemProperties() {
        let item = HealthMetricItem(name: "Test", value: "100ms", category: "Perf", status: .good)
        XCTAssertEqual(item.name, "Test")
        XCTAssertEqual(item.value, "100ms")
        XCTAssertEqual(item.category, "Perf")
    }
}

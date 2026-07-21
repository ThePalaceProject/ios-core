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
import PalaceReadingPosition

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
        // Fresh, disconnected same-suite UserDefaults per actor init (non-Sendable
        // value can't be sent from the @MainActor test's retained property; an
        // inline instance is its own region and shares the backing store).
        offlineQueueService = OfflineQueueService(userDefaults: UserDefaults(suiteName: "AppHealthViewModelTests")!)
        positionSyncService = PositionSyncService(userDefaults: UserDefaults(suiteName: "AppHealthViewModelTests")!)
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

        // Deterministically JOIN the async load instead of sleeping on a
        // wall-clock deadline (starves under CI oversubscription).
        await viewModel.awaitLoadForTesting()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.metrics.isEmpty)
        XCTAssertNotNil(viewModel.performanceReport)
    }

    func testLoadDataIncludesMemoryMetric() async {
        viewModel.loadData()
        // Deterministically JOIN the async load instead of sleeping on a
        // wall-clock deadline (starves under CI oversubscription).
        await viewModel.awaitLoadForTesting()

        let memoryMetric = viewModel.metrics.first(where: { $0.name == "Memory Usage" })
        XCTAssertNotNil(memoryMetric, "Should include memory usage metric")
        XCTAssertEqual(memoryMetric?.category, "System")
    }

    func testLoadDataIncludesOfflineQueueMetrics() async {
        viewModel.loadData()
        // Deterministically JOIN the async load instead of sleeping on a
        // wall-clock deadline (starves under CI oversubscription).
        await viewModel.awaitLoadForTesting()

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
        // Deterministically JOIN the async load instead of sleeping on a
        // wall-clock deadline (starves under CI oversubscription).
        await viewModel.awaitLoadForTesting()

        XCTAssertNotNil(viewModel.performanceReport)
        XCTAssertEqual(viewModel.performanceReport?.totalMeasurements, 2)
    }

    // MARK: - Status Thresholds

    func testAppLaunchStatusThresholds() async {
        // Fast launch — should be good
        await performanceMonitor.record(name: "launch", category: .appLaunch, duration: 1.0, metadata: [:])

        viewModel.loadData()
        // Deterministically JOIN the async load instead of sleeping on a
        // wall-clock deadline (starves under CI oversubscription).
        await viewModel.awaitLoadForTesting()

        let launchMetric = viewModel.metrics.first(where: { $0.name.contains("App Launch") })
        if let metric = launchMetric {
            XCTAssertEqual(metric.status, .good)
        }
    }

    // MARK: - Offline Queue Status Updates

    func testOfflineQueueStatusUpdates() async {
        // Deterministically JOIN the ViewModel's main-hopped status sink instead
        // of sleeping on a wall-clock deadline (starves under CI oversubscription).
        // The ViewModel subscribes to statusPublisher.receive(on: .main), so a
        // fulfillment on $offlineQueueStatus fires exactly when the emission lands.
        let emitted = expectation(description: "ViewModel reflects the enqueued action")
        viewModel.$offlineQueueStatus
            .drop(while: { $0.pendingCount == 0 })
            .first()
            .sink { _ in emitted.fulfill() }
            .store(in: &cancellables)

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test")
        await offlineQueueService.enqueue(action)

        await fulfillment(of: [emitted], timeout: 5.0)

        XCTAssertGreaterThanOrEqual(viewModel.offlineQueueStatus.pendingCount, 0)
    }

    // MARK: - Health Metric Item

    func testHealthMetricItemProperties() {
        let item = HealthMetricItem(name: "Test", value: "100ms", category: "Perf", status: .good)
        XCTAssertEqual(item.name, "Test")
        XCTAssertEqual(item.value, "100ms")
        XCTAssertEqual(item.category, "Perf")
        XCTAssertEqual(item.status, .good, "Status must be .good as initialized")
    }
}

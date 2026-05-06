//
//  AppHealthViewModel.swift
//  Palace
//
//  ViewModel aggregating health data from all platform services.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Data for a single health metric displayed in the dashboard.
struct HealthMetricItem: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let category: String
    let status: HealthStatus

    enum HealthStatus {
        case good
        case warning
        case error
        case info
    }
}

@MainActor
final class AppHealthViewModel: ObservableObject {
    @Published var metrics: [HealthMetricItem] = []
    @Published var performanceReport: PerformanceReport?
    @Published var offlineQueueStatus: OfflineQueueStatus = .empty
    @Published var isLoading = true

    private let performanceMonitor: PerformanceMonitor
    private let offlineQueueService: OfflineQueueService
    private let positionSyncService: PositionSyncService
    private var cancellables = Set<AnyCancellable>()

    init(
        performanceMonitor: PerformanceMonitor = .shared,
        offlineQueueService: OfflineQueueService = .shared,
        positionSyncService: PositionSyncService = .shared
    ) {
        self.performanceMonitor = performanceMonitor
        self.offlineQueueService = offlineQueueService
        self.positionSyncService = positionSyncService

        offlineQueueService.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.offlineQueueStatus = status
                self?.rebuildMetrics()
            }
            .store(in: &cancellables)
    }

    func loadData() {
        isLoading = true
        Task {
            let report = await performanceMonitor.generateReport()
            let queueStatus = await offlineQueueService.currentStatus()

            self.performanceReport = report
            self.offlineQueueStatus = queueStatus
            self.rebuildMetrics()
            self.isLoading = false
        }
    }

    private func rebuildMetrics() {
        var items: [HealthMetricItem] = []

        // Performance metrics
        if let report = performanceReport {
            items.append(HealthMetricItem(
                name: "Total Measurements",
                value: "\(report.totalMeasurements)",
                category: "Performance",
                status: .info
            ))

            if let launchStats = report.statistics(for: .appLaunch) {
                let p50ms = Int(launchStats.p50 * 1000)
                items.append(HealthMetricItem(
                    name: "App Launch (p50)",
                    value: "\(p50ms)ms",
                    category: "Performance",
                    status: p50ms < 2000 ? .good : (p50ms < 5000 ? .warning : .error)
                ))
            }

            if let catalogStats = report.statistics(for: .catalogLoad) {
                let p50ms = Int(catalogStats.p50 * 1000)
                items.append(HealthMetricItem(
                    name: "Catalog Load (p50)",
                    value: "\(p50ms)ms",
                    category: "Performance",
                    status: p50ms < 3000 ? .good : (p50ms < 8000 ? .warning : .error)
                ))
            }

            if let bookStats = report.statistics(for: .bookOpen) {
                let p50ms = Int(bookStats.p50 * 1000)
                items.append(HealthMetricItem(
                    name: "Book Open (p50)",
                    value: "\(p50ms)ms",
                    category: "Performance",
                    status: p50ms < 1000 ? .good : (p50ms < 3000 ? .warning : .error)
                ))
            }
        }

        // Memory
        let memoryUsage = Self.currentMemoryUsageMB()
        items.append(HealthMetricItem(
            name: "Memory Usage",
            value: String(format: "%.1f MB", memoryUsage),
            category: "System",
            status: memoryUsage < 200 ? .good : (memoryUsage < 400 ? .warning : .error)
        ))

        // Offline queue
        items.append(HealthMetricItem(
            name: "Pending Actions",
            value: "\(offlineQueueStatus.pendingCount)",
            category: "Offline Queue",
            status: offlineQueueStatus.pendingCount == 0 ? .good : .warning
        ))

        items.append(HealthMetricItem(
            name: "Failed Actions",
            value: "\(offlineQueueStatus.failedCount)",
            category: "Offline Queue",
            status: offlineQueueStatus.failedCount == 0 ? .good : .error
        ))

        if let lastSync = offlineQueueStatus.lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            items.append(HealthMetricItem(
                name: "Last Sync",
                value: formatter.localizedString(for: lastSync, relativeTo: Date()),
                category: "Offline Queue",
                status: .info
            ))
        }

        self.metrics = items
    }

    // MARK: - Memory

    private static func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / (1024 * 1024)
        }
        return 0
    }
}

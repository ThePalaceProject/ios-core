//
//  PerformanceMonitor.swift
//  Palace
//
//  Actor-based performance monitoring with os_signpost integration.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import os.signpost

/// Actor-based performance monitor with os_signpost integration for Instruments.
actor PerformanceMonitor: PerformanceMonitorProtocol {

    // MARK: - Singleton

    static let shared = PerformanceMonitor()

    // MARK: - Configuration

    /// Maximum number of metrics stored per category.
    private let maxMetricsPerCategory = 100

    // MARK: - Storage

    private var metricsByCategory: [PerformanceCategory: [PerformanceMetric]] = [:]
    private var activeTimings: [UUID: (name: String, category: PerformanceCategory, metadata: [String: String], startTime: CFAbsoluteTime, signpostID: OSSignpostID)] = [:]

    // MARK: - Signpost

    private let signpostLog = OSLog(subsystem: "org.thepalaceproject.palace", category: "Performance")

    // MARK: - Combine

    private nonisolated(unsafe) let metricSubject = PassthroughSubject<PerformanceMetric, Never>()

    nonisolated var metricPublisher: AnyPublisher<PerformanceMetric, Never> {
        metricSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init() {}

    // MARK: - Timing

    func startTiming(
        _ name: String,
        category: PerformanceCategory,
        metadata: [String: String] = [:]
    ) async -> UUID {
        let token = UUID()
        let signpostID = OSSignpostID(log: signpostLog)

        os_signpost(.begin, log: signpostLog, name: "Measurement", signpostID: signpostID, "%{public}s", name)

        activeTimings[token] = (
            name: name,
            category: category,
            metadata: metadata,
            startTime: CFAbsoluteTimeGetCurrent(),
            signpostID: signpostID
        )

        return token
    }

    @discardableResult
    func endTiming(_ token: UUID) async -> PerformanceMetric? {
        guard let timing = activeTimings.removeValue(forKey: token) else { return nil }

        let duration = CFAbsoluteTimeGetCurrent() - timing.startTime

        os_signpost(.end, log: signpostLog, name: "Measurement", signpostID: timing.signpostID, "%{public}s: %.3fms", timing.name, duration * 1000)

        let metric = PerformanceMetric(
            name: timing.name,
            category: timing.category,
            duration: duration,
            metadata: timing.metadata
        )

        storeMetric(metric)
        return metric
    }

    // MARK: - Direct Recording

    func record(_ metric: PerformanceMetric) async {
        storeMetric(metric)
    }

    func record(
        name: String,
        category: PerformanceCategory,
        duration: TimeInterval,
        metadata: [String: String] = [:]
    ) async {
        let metric = PerformanceMetric(
            name: name,
            category: category,
            duration: duration,
            metadata: metadata
        )
        storeMetric(metric)
    }

    // MARK: - Queries

    func metrics(for category: PerformanceCategory) async -> [PerformanceMetric] {
        metricsByCategory[category] ?? []
    }

    func generateReport() async -> PerformanceReport {
        var byCategoryStats: [PerformanceCategory: PerformanceStatistics] = [:]
        var byNameStats: [String: PerformanceStatistics] = [:]
        var totalCount = 0

        // Group by category
        for (category, metrics) in metricsByCategory {
            let durations = metrics.map(\.duration)
            byCategoryStats[category] = PerformanceStatistics(durations: durations)
            totalCount += metrics.count
        }

        // Group by name
        var nameGroups: [String: [TimeInterval]] = [:]
        for metrics in metricsByCategory.values {
            for metric in metrics {
                nameGroups[metric.name, default: []].append(metric.duration)
            }
        }
        for (name, durations) in nameGroups {
            byNameStats[name] = PerformanceStatistics(durations: durations)
        }

        return PerformanceReport(
            generatedAt: Date(),
            metricsByCategory: byCategoryStats,
            metricsByName: byNameStats,
            totalMeasurements: totalCount
        )
    }

    func clearAll() async {
        metricsByCategory.removeAll()
        activeTimings.removeAll()
    }

    // MARK: - Private

    private func storeMetric(_ metric: PerformanceMetric) {
        var list = metricsByCategory[metric.category] ?? []
        list.append(metric)
        // Trim to max size, removing oldest
        if list.count > maxMetricsPerCategory {
            list = Array(list.suffix(maxMetricsPerCategory))
        }
        metricsByCategory[metric.category] = list
        metricSubject.send(metric)
    }
}

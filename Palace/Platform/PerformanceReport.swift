//
//  PerformanceReport.swift
//  Palace
//
//  Aggregated performance report with percentile calculations.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Aggregated statistics for a set of performance metrics.
struct PerformanceStatistics: Sendable {
    let count: Int
    let min: TimeInterval
    let max: TimeInterval
    let mean: TimeInterval
    let p50: TimeInterval
    let p95: TimeInterval
    let p99: TimeInterval

    init(durations: [TimeInterval]) {
        let sorted = durations.sorted()
        self.count = sorted.count

        guard !sorted.isEmpty else {
            self.min = 0
            self.max = 0
            self.mean = 0
            self.p50 = 0
            self.p95 = 0
            self.p99 = 0
            return
        }

        self.min = sorted.first!
        self.max = sorted.last!
        self.mean = sorted.reduce(0, +) / Double(sorted.count)
        self.p50 = Self.percentile(sorted, 0.50)
        self.p95 = Self.percentile(sorted, 0.95)
        self.p99 = Self.percentile(sorted, 0.99)
    }

    private static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[Swift.min(index, sorted.count - 1)]
    }
}

/// A report of aggregated performance data.
struct PerformanceReport: Sendable {
    let generatedAt: Date
    let metricsByCategory: [PerformanceCategory: PerformanceStatistics]
    let metricsByName: [String: PerformanceStatistics]
    let totalMeasurements: Int

    /// Get statistics for a specific category.
    func statistics(for category: PerformanceCategory) -> PerformanceStatistics? {
        metricsByCategory[category]
    }

    /// Get statistics for a named metric.
    func statistics(forName name: String) -> PerformanceStatistics? {
        metricsByName[name]
    }

    /// A summary string for display.
    var summary: String {
        var lines: [String] = ["Performance Report (\(totalMeasurements) measurements)"]
        for (category, stats) in metricsByCategory.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  \(category.rawValue): p50=\(formatDuration(stats.p50)) p95=\(formatDuration(stats.p95)) (n=\(stats.count))")
        }
        return lines.joined(separator: "\n")
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 {
            return String(format: "%.0fms", d * 1000)
        }
        return String(format: "%.2fs", d)
    }
}

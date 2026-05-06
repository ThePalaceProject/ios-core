//
//  PerformanceMonitorProtocol.swift
//  Palace
//
//  Protocol for performance monitoring.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Protocol for the performance monitoring service.
protocol PerformanceMonitorProtocol: Sendable {
    /// Publisher that emits each new metric as it's recorded.
    var metricPublisher: AnyPublisher<PerformanceMetric, Never> { get }

    /// Start timing an operation. Returns a token to pass to `endTiming`.
    func startTiming(_ name: String, category: PerformanceCategory, metadata: [String: String]) async -> UUID

    /// End timing an operation. Records the metric.
    func endTiming(_ token: UUID) async -> PerformanceMetric?

    /// Record a metric directly (when you already know the duration).
    func record(_ metric: PerformanceMetric) async

    /// Record a duration directly.
    func record(name: String, category: PerformanceCategory, duration: TimeInterval, metadata: [String: String]) async

    /// Get all recorded metrics for a category.
    func metrics(for category: PerformanceCategory) async -> [PerformanceMetric]

    /// Generate a performance report.
    func generateReport() async -> PerformanceReport

    /// Clear all stored metrics.
    func clearAll() async
}

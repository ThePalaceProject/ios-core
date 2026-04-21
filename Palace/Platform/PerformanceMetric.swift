//
//  PerformanceMetric.swift
//  Palace
//
//  A single performance measurement.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Categories of performance metrics.
enum PerformanceCategory: String, Codable, Sendable, CaseIterable {
    case appLaunch = "app_launch"
    case catalogLoad = "catalog_load"
    case bookOpen = "book_open"
    case pageTurn = "page_turn"
    case download = "download"
    case networkRequest = "network_request"
    case imageLoad = "image_load"
    case custom = "custom"
}

/// A single performance measurement.
struct PerformanceMetric: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let category: PerformanceCategory
    let duration: TimeInterval
    let timestamp: Date
    let metadata: [String: String]

    init(
        name: String,
        category: PerformanceCategory,
        duration: TimeInterval,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.duration = duration
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

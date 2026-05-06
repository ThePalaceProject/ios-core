//
//  OfflineQueueStatus.swift
//  Palace
//
//  Status of the offline action queue.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The overall status of the offline action queue.
struct OfflineQueueStatus: Equatable, Sendable {
    let pendingCount: Int
    let failedCount: Int
    let processingCount: Int
    let lastSyncDate: Date?

    /// Whether there are any actions requiring attention.
    var hasActions: Bool {
        pendingCount > 0 || failedCount > 0 || processingCount > 0
    }

    /// A human-readable summary.
    var summary: String {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending")
        }
        if processingCount > 0 {
            parts.append("\(processingCount) processing")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }
        if parts.isEmpty {
            return "All synced"
        }
        return parts.joined(separator: ", ")
    }

    /// Total number of actions in any non-completed state.
    var totalActive: Int {
        pendingCount + failedCount + processingCount
    }

    static let empty = OfflineQueueStatus(
        pendingCount: 0,
        failedCount: 0,
        processingCount: 0,
        lastSyncDate: nil
    )
}

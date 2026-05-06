//
//  PlatformTab.swift
//  Palace
//
//  Static helpers providing access to platform services.
//  This is not a tab — it provides shared service instances.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Provides centralized access to platform services.
/// All services are singletons gated by feature flag checks where appropriate.
enum PlatformServices {

    // MARK: - Position Sync

    /// The shared position sync service.
    static var positionSync: PositionSyncService {
        PositionSyncService.shared
    }

    // MARK: - Performance Monitoring

    /// The shared performance monitor.
    static var performanceMonitor: PerformanceMonitor {
        PerformanceMonitor.shared
    }

    // MARK: - App Launch Tracking

    /// The shared app launch tracker.
    static var launchTracker: AppLaunchTracker {
        AppLaunchTracker.shared
    }

    // MARK: - Accessibility

    /// The shared accessibility service.
    static var accessibility: AccessibilityService {
        AccessibilityService.shared
    }

    // MARK: - Offline Queue

    /// The shared offline queue service.
    static var offlineQueue: OfflineQueueService {
        OfflineQueueService.shared
    }

    // MARK: - Convenience: Performance Timing

    /// Start timing a named operation.
    static func startTiming(_ name: String, category: PerformanceCategory, metadata: [String: String] = [:]) async -> UUID {
        await performanceMonitor.startTiming(name, category: category, metadata: metadata)
    }

    /// End timing a previously started operation.
    @discardableResult
    static func endTiming(_ token: UUID) async -> PerformanceMetric? {
        await performanceMonitor.endTiming(token)
    }

    /// Record a reading position from any reader or audiobook player.
    static func recordPosition(_ position: ReadingPosition) async {
        await positionSync.recordPosition(position)
    }

    /// Check for cross-format sync opportunity.
    static func checkForSync(bookID: String, openingFormat: ReadingFormat) async -> ReadingPosition? {
        await positionSync.checkForSyncOffer(bookID: bookID, openingFormat: openingFormat)
    }
}

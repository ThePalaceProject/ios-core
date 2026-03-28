//
//  OfflineQueueServiceProtocol.swift
//  Palace
//
//  Protocol for the offline action queue service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Protocol for the offline action queue service.
protocol OfflineQueueServiceProtocol: Sendable {
    /// Publisher for queue status changes.
    var statusPublisher: AnyPublisher<OfflineQueueStatus, Never> { get }

    /// Publisher for individual action state changes.
    var actionPublisher: AnyPublisher<OfflineAction, Never> { get }

    /// Enqueue an action for later processing.
    func enqueue(_ action: OfflineAction) async

    /// Get all actions in a given state.
    func actions(withState state: OfflineActionState) async -> [OfflineAction]

    /// Get the current queue status.
    func currentStatus() async -> OfflineQueueStatus

    /// Retry a specific failed action.
    func retry(_ actionID: UUID) async

    /// Cancel a pending action.
    func cancel(_ actionID: UUID) async

    /// Clear all failed actions.
    func clearFailed() async

    /// Process the queue (called when network becomes available).
    func processQueue() async

    /// Whether the queue is currently processing.
    func isProcessing() async -> Bool
}

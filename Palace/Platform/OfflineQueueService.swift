//
//  OfflineQueueService.swift
//  Palace
//
//  Offline action queue service with retry, persistence, and network monitoring.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import Network

/// A closure that executes an offline action. Returns true on success, false on failure.
typealias OfflineActionExecutor = @Sendable (OfflineAction) async -> Bool

/// Actor-based offline queue service for user-initiated actions.
actor OfflineQueueService: OfflineQueueServiceProtocol {

    // MARK: - Singleton

    static let shared = OfflineQueueService()

    // MARK: - State

    private var queue: [OfflineAction] = []
    private var processing = false
    private let storageKey = "Palace.Platform.offlineQueue"
    private let userDefaults: UserDefaults
    private var executor: OfflineActionExecutor?

    // MARK: - Network Monitoring

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.palace.offlineQueue.network")
    private var isNetworkAvailable = true

    // MARK: - Combine

    private nonisolated(unsafe) let statusSubject = CurrentValueSubject<OfflineQueueStatus, Never>(.empty)
    private nonisolated(unsafe) let actionSubject = PassthroughSubject<OfflineAction, Never>()

    nonisolated var statusPublisher: AnyPublisher<OfflineQueueStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    nonisolated var actionPublisher: AnyPublisher<OfflineAction, Never> {
        actionSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load persisted queue
        if let data = userDefaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([OfflineAction].self, from: data) {
            // Reset any "processing" state from previous session
            self.queue = saved.map { action in
                var a = action
                if a.state == .processing {
                    a.state = .pending
                }
                return a
            }
        }

        Task { await startNetworkMonitoring() }
    }

    // MARK: - Configuration

    /// Set the executor that will process offline actions.
    func setExecutor(_ executor: @escaping OfflineActionExecutor) {
        self.executor = executor
    }

    // MARK: - Queue Operations

    func enqueue(_ action: OfflineAction) async {
        queue.append(action)
        persist()
        publishStatus()
        actionSubject.send(action)

        // If network is available, process immediately
        if isNetworkAvailable {
            await processQueue()
        }
    }

    func actions(withState state: OfflineActionState) async -> [OfflineAction] {
        queue.filter { $0.state == state }
    }

    func currentStatus() async -> OfflineQueueStatus {
        computeStatus()
    }

    func retry(_ actionID: UUID) async {
        guard let index = queue.firstIndex(where: { $0.id == actionID && $0.state == .failed }) else { return }
        queue[index].state = .pending
        queue[index].errorMessage = nil
        persist()
        publishStatus()
        actionSubject.send(queue[index])

        if isNetworkAvailable {
            await processQueue()
        }
    }

    func cancel(_ actionID: UUID) async {
        queue.removeAll { $0.id == actionID && ($0.state == .pending || $0.state == .failed) }
        persist()
        publishStatus()
    }

    func clearFailed() async {
        queue.removeAll { $0.state == .failed }
        persist()
        publishStatus()
    }

    func isProcessing() async -> Bool {
        processing
    }

    // MARK: - Processing

    func processQueue() async {
        guard !processing else { return }
        guard let executor = self.executor else { return }

        processing = true
        publishStatus()

        // Process pending actions in FIFO order
        while let index = queue.firstIndex(where: { $0.state == .pending }) {
            queue[index].state = .processing
            queue[index].lastAttemptAt = Date()
            persist()
            actionSubject.send(queue[index])

            let action = queue[index]
            let success = await executor(action)

            // Re-find the index in case the queue was modified
            guard let currentIndex = queue.firstIndex(where: { $0.id == action.id }) else { continue }

            if success {
                queue[currentIndex].state = .completed
                actionSubject.send(queue[currentIndex])
                // Remove completed actions
                queue.remove(at: currentIndex)
            } else {
                queue[currentIndex].retryCount += 1
                if queue[currentIndex].retryCount >= queue[currentIndex].maxRetries {
                    queue[currentIndex].state = .failed
                    queue[currentIndex].errorMessage = "Max retries exceeded"
                } else {
                    queue[currentIndex].state = .failed
                    queue[currentIndex].errorMessage = "Will retry"
                    // Schedule retry with exponential backoff
                    let delay = queue[currentIndex].nextRetryDelay
                    queue[currentIndex].state = .pending
                    // Wait for backoff delay
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                actionSubject.send(queue[currentIndex])
            }

            persist()
            publishStatus()
        }

        processing = false
        publishStatus()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { [weak self] in
                await self?.networkStatusChanged(isAvailable: available)
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    /// Called when network status changes. Can be called externally for testing.
    func networkStatusChanged(isAvailable: Bool) async {
        self.isNetworkAvailable = isAvailable
        if isAvailable {
            await processQueue()
        }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    // MARK: - Status

    private func computeStatus() -> OfflineQueueStatus {
        OfflineQueueStatus(
            pendingCount: queue.filter { $0.state == .pending }.count,
            failedCount: queue.filter { $0.state == .failed }.count,
            processingCount: queue.filter { $0.state == .processing }.count,
            lastSyncDate: queue
                .compactMap(\.lastAttemptAt)
                .max()
        )
    }

    private func publishStatus() {
        statusSubject.send(computeStatus())
    }
}

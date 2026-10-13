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
import PalaceLogging

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

    /// Injected retry-backoff sleep. The backoff is an inline `await` inside
    /// `processQueue()`, which every caller awaits to full drain, so tests
    /// inject `{ _ in }` to run the retry state machine with no wall-clock
    /// delay. Production uses `Task.sleep`.
    private let backoffSleep: @Sendable (TimeInterval) async -> Void

    /// Reads the current library account. Only that library's actions drain;
    /// the others keep their place and state until their library is current.
    /// Installed with the executor; until then it reports no library.
    private var currentLibraryID: @Sendable () -> String?

    /// Keeps the current-library-change subscription alive for the actor's
    /// lifetime.
    private let libraryChangeSubscription = SubscriptionHolder()

    /// The app-wide queue's entry points, used as production defaults by the
    /// services that feed and prune it.
    static let productionEnqueue: @Sendable (OfflineAction) async -> Void = { action in
        await appQueue.enqueue(action)
    }
    static let productionRemoveActions: @Sendable (String) -> Void = { libraryID in
        Task { await appQueue.removeActions(forLibrary: libraryID) }
    }
    private static var appQueue: OfflineQueueService { OfflineQueueService.shared }

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

    init(
        userDefaults: UserDefaults = .standard,
        backoffSleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        currentLibraryID: @escaping @Sendable () -> String? = { nil },
        notificationCenter: NotificationCenter = .default
    ) {
        self.userDefaults = userDefaults
        self.backoffSleep = backoffSleep
        self.currentLibraryID = currentLibraryID

        // Load persisted queue
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OfflineAction].self, from: data) {
            // Actions saved before `libraryID` existed cannot be attributed to
            // a library, and running one under the wrong library confirms a
            // return that never happened. The loan they name is still held on
            // the server and its book is still on the shelf, so dropping them
            // loses no state the patron cannot see and redo.
            let saved = decoded.filter { $0.libraryID != nil }
            if saved.count != decoded.count {
                Log.warn(#file, "Dropped \(decoded.count - saved.count) queued offline action(s) saved without a library")
                if let data = try? JSONEncoder().encode(saved) {
                    userDefaults.set(data, forKey: storageKey)
                }
            }
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

        libraryChangeSubscription.cancellable = notificationCenter
            .publisher(for: .TPPCurrentAccountDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.currentLibraryDidChange() }
            }
    }

    // MARK: - Configuration

    /// Set the executor that will process offline actions.
    func setExecutor(_ executor: @escaping OfflineActionExecutor) {
        self.executor = executor
    }

    /// Set the executor together with the current-library reader that scopes
    /// which actions it is handed.
    func setExecutor(
        _ executor: @escaping OfflineActionExecutor,
        currentLibraryID: @escaping @Sendable () -> String?
    ) {
        self.executor = executor
        self.currentLibraryID = currentLibraryID
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

    /// Removes every action made under `libraryID`, in any state. Called when
    /// that library's patron session ends, since its actions were made with
    /// that patron's loans and credentials.
    func removeActions(forLibrary libraryID: String) async {
        let before = queue.count
        queue.removeAll { $0.libraryID == libraryID }
        guard queue.count != before else { return }
        Log.info(#file, "Removed \(before - queue.count) queued offline action(s) for a signed-out library")
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

        // Process the current library's pending actions in FIFO order
        while let index = nextRunnableIndex() {
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
                    await backoffSleep(delay)
                }
                actionSubject.send(queue[currentIndex])
            }

            persist()
            publishStatus()
        }

        processing = false
        publishStatus()
    }

    /// The first pending action that belongs to the current library, read
    /// afresh on every pick so a mid-drain library switch stops the drain.
    private func nextRunnableIndex() -> Int? {
        let current = currentLibraryID()
        return queue.firstIndex { $0.state == .pending && $0.belongs(toLibrary: current) }
    }

    /// Drains the actions of the library that just became current.
    func currentLibraryDidChange() async {
        if isNetworkAvailable {
            await processQueue()
        }
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

/// Holds the current-library-change subscription. Written once in
/// `OfflineQueueService.init` and never read, so it needs no lock.
private final class SubscriptionHolder: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

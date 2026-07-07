//
//  UserRetryTracker.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Tracks user-initiated retry attempts per operation to enforce a retry limit.
/// Prevents users from endlessly retrying failed operations while still
/// allowing a reasonable number of attempts for transient errors.
///
/// `@unchecked Sendable` (Swift 6 `complete`-mode): the shared singleton is
/// captured by value into retry-alert closures and read from arbitrary
/// re-auth completion queues, so it must be `Sendable`. The conformance is
/// honest — the only mutable state (`retries`) is *always* mutated under
/// `lock` (`canRetry`, `recordRetry`, `clearRetries`, and the private
/// `cleanupStaleEntries` each take `lock.lock()`/`defer unlock`). The
/// remaining stored members (`maxRetries`, `resetInterval`) are immutable
/// `let`s. `final`, so the lock invariant can't be defeated by a subclass.
final class UserRetryTracker: @unchecked Sendable {
    static let shared = UserRetryTracker()

    private struct RetryInfo {
        var count: Int
        var firstAttempt: Date
    }

    private var retries: [String: RetryInfo] = [:]
    private let lock = NSLock()

    /// Maximum number of user-initiated retries before showing "try again later"
    private let maxRetries = 5

    /// Time interval after which retry counts reset (5 minutes)
    private let resetInterval: TimeInterval = 300

    private init() {}

    /// Returns true if retry is allowed (under the limit), false if limit exceeded.
    func canRetry(operationId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cleanupStaleEntries()
        guard let info = retries[operationId] else { return true }
        return info.count < maxRetries
    }

    /// Records a retry attempt. Returns the number of remaining retries.
    @discardableResult
    func recordRetry(operationId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        cleanupStaleEntries()
        var info = retries[operationId] ?? RetryInfo(count: 0, firstAttempt: Date())
        info.count += 1
        retries[operationId] = info
        return max(0, maxRetries - info.count)
    }

    /// Clears retry count for an operation (call on success).
    func clearRetries(operationId: String) {
        lock.lock()
        defer { lock.unlock() }
        retries.removeValue(forKey: operationId)
    }

    /// Removes entries older than `resetInterval`.
    private func cleanupStaleEntries() {
        let now = Date()
        retries = retries.filter { now.timeIntervalSince($0.value.firstAttempt) < resetInterval }
    }
}

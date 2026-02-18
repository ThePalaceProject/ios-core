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
final class UserRetryTracker {
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

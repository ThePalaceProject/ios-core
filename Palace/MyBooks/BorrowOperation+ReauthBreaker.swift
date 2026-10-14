//
//  BorrowOperation+ReauthBreaker.swift
//  Palace
//
//  The per-book re-authentication breaker for borrows, and the test-only
//  record of retries started from a sign-in modal's completion.
//

import Foundation

/// Books whose borrow has already tried re-authentication. A second auth
/// failure on the same book shows an error instead of signing in again.
/// Set and lock live in one `@unchecked Sendable` holder: a mutable static
/// guarded by a sibling lock still warns under Swift 6 complete checking.
final class BorrowReauthTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted: Set<String> = []

    func hasAttempted(_ bookId: String) -> Bool { lock.withLock { attempted.contains(bookId) } }
    func mark(_ bookId: String) { lock.withLock { _ = attempted.insert(bookId) } }
    func clear(_ bookId: String) { lock.withLock { attempted.remove(bookId) } }
    func clearAll() { lock.withLock { attempted.removeAll() } }
}

/// The sign-in modal reports back through a completion, so its retry runs in
/// a Task. Handles are kept only under XCTest so a test can join them.
final class BorrowRetryRecorder: @unchecked Sendable {
    private static let isEnabled =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func retain(_ task: Task<Void, Never>) {
        guard Self.isEnabled else { return }
        lock.withLock { tasks.append(task) }
    }

    private func snapshot() -> [Task<Void, Never>] {
        lock.withLock { tasks }
    }

    /// Awaits every retry recorded so far, including retries those retries start.
    @MainActor
    func awaitAll() async {
        var awaited = 0
        while true {
            let current = snapshot()
            if awaited >= current.count { break }
            for task in current[awaited...] { await task.value }
            awaited = current.count
        }
    }
}

extension BorrowOperation {

    static let reauthTracker = BorrowReauthTracker()

    static func hasBorrowReauthBeenAttempted(for bookId: String) -> Bool {
        reauthTracker.hasAttempted(bookId)
    }

    static func markBorrowReauthAttempted(for bookId: String) {
        reauthTracker.mark(bookId)
    }

    static func clearBorrowReauthAttempted(for bookId: String) {
        reauthTracker.clear(bookId)
    }

    /// Whether a borrow of `bookId` would show an error instead of signing in.
    static func isBorrowReauthGatedForTesting(_ bookId: String) -> Bool {
        hasBorrowReauthBeenAttempted(for: bookId)
    }

    /// Clears all re-auth tracking. Called on account switch via the
    /// MBDC forwarder so stale circuit-breaker state from the previous
    /// account can't suppress legitimate re-auth attempts.
    static func clearAllBorrowReauthState() {
        reauthTracker.clearAll()
    }

    func retainRetryForTesting(_ task: Task<Void, Never>) {
        retryRecorder.retain(task)
    }

    /// Awaits every retry started so far, including retries those retries start.
    @MainActor
    func _awaitPendingRetriesForTesting() async {
        await retryRecorder.awaitAll()
    }
}

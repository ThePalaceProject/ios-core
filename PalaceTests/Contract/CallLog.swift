//
//  CallLog.swift
//  PalaceTests
//
//  Lightweight call-recording primitive for contract-snapshot tests.
//
//  Usage in a spy:
//
//      final class SpyBorrowDelegate: BorrowDelegate {
//          let log = CallLog()
//
//          func startDownload(for book: TPPBook, withRequest req: URLRequest?) {
//              log.record("startDownload",
//                         args: ["book": book.identifier, "hasRequest": req != nil])
//          }
//      }
//
//  The CallLog produces deterministic JSON suitable for snapshot comparison.
//  Arguments are stringified through `String(describing:)` to keep the format
//  schema-light — contracts care about *which method, in what order, with what
//  shape of arguments* — not about Swift type-system correctness.
//

import Foundation

/// One recorded call: method name + flat dictionary of stringified arguments.
public struct CallRecord: Hashable, Codable {
    public let method: String
    public let args: [String: String]

    public init(method: String, args: [String: Any] = [:]) {
        self.method = method
        // Normalize Any → String so the snapshot format is JSON-friendly.
        // Sorted keys come for free at encode time (JSONEncoder.sortedKeys).
        var normalized: [String: String] = [:]
        for (k, v) in args {
            normalized[k] = "\(v)"
        }
        self.args = normalized
    }
}

/// Append-only call log used by test spies. Thread-safe via a serial queue —
/// production async/Combine paths can record from any queue without races.
public final class CallLog: @unchecked Sendable {
    private var entries: [CallRecord] = []
    private let lock = NSLock()

    public init() {}

    public func record(_ method: String, args: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(CallRecord(method: method, args: args))
    }

    /// Snapshot the current call sequence. Returned array is a copy — safe to
    /// hold across further recordings.
    public func snapshot() -> [CallRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Reset for re-use across scenarios in a single test method.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }
}

//
//  LockIsolated.swift
//  PalaceTests
//
//  Swift 6 concurrency-safe holder for test-infrastructure state that used to
//  live in a `static var`. Under Swift 6 language mode, a mutable `static var`
//  is "nonisolated global shared mutable state" and is rejected — even for the
//  serial/lock-guarded registries our test stubs rely on (HTTPStubURLProtocol
//  handlers, stubbed sessions, mock singletons, etc.).
//
//  The migration pattern (chosen over `nonisolated(unsafe)`, which would merely
//  silence the check) is:
//
//      // before — flagged as unsafe global mutable state:
//      static var requestHandlers: [String: Handler] = [:]
//
//      // after — genuinely safe, and every existing call site is unchanged:
//      private static let _requestHandlers = LockIsolated<[String: Handler]>([:])
//      static var requestHandlers: [String: Handler] {
//          get { _requestHandlers.value }
//          set { _requestHandlers.value = newValue }
//      }
//
//  The `static let` binding is immutable (safe); all mutation flows through the
//  lock. The public `static var` is *computed* — it holds no storage of its own,
//  so it is not global mutable state, and callers keep writing `Type.requestHandlers`.
//
//  `@unchecked Sendable` is sound here because every access to the wrapped value
//  goes through `lock`, which the compiler cannot see but the type guarantees.
import Foundation

final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    /// Atomically read or replace the wrapped value.
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Perform an atomic read-modify-write against the wrapped value and return
    /// a result. Use this when a compound mutation must not interleave (e.g.
    /// append-then-read), which the get/set `value` pair cannot guarantee.
    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&_value) }
    }
}

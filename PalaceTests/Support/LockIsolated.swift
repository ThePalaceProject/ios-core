//  LockIsolated.swift
//
//  Swift 6 rejects a mutable `static var` as shared global state, including the
//  lock-guarded registries test stubs rely on. Instead of `nonisolated(unsafe)`,
//  store the value in a `private static let _x = LockIsolated(...)` and expose a
//  computed `static var x { get { _x.value } set { _x.value = newValue } }`, so
//  call sites are unchanged. `@unchecked Sendable` holds because every access to
//  the wrapped value goes through `lock`.
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

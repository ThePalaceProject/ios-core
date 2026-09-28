//
//  TestLockIsolated.swift
//  PalaceUtilitiesTests
//
//  A lock-boxed value for tests whose subject takes a `@Sendable` closure, so a
//  captured `var` cannot be mutated inside it.
//
//  This duplicates `PalaceTests/Support/LockIsolated.swift` by module boundary:
//  a package test target cannot see the app test target's support code, and
//  reaching for it would mean giving PalaceUtilities a dependency it must not
//  have (see Package.swift on why this package stays a leaf). Fifteen lines of
//  NSLock is the cheaper of the two prices.
//

import Foundation

final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { self._value = value }

    /// Atomically read or replace the wrapped value.
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Atomic read-modify-write, for compound mutations the get/set pair cannot
    /// make indivisible.
    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&_value) }
    }
}

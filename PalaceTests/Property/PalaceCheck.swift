//
//  PalaceCheck.swift
//  PalaceTests
//
//  Minimal property-based testing framework. Zero external deps beyond XCTest.
//  See README_PalaceCheck.md for usage.
//

import Foundation
import XCTest

// MARK: - Seedable RNG (LCG — deterministic, reproducible)

public struct PalaceCheckRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) {
        // Avoid zero-state degenerate LCG.
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }
    public mutating func next() -> UInt64 {
        // SplitMix64 — strong enough, deterministic, single-line.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Arbitrary protocol

public protocol Arbitrary {
    static func generate(using rng: inout PalaceCheckRNG) -> Self
    /// Produce smaller candidates. Default: empty (no shrinking).
    static func shrink(_ value: Self) -> [Self]
}

public extension Arbitrary {
    static func shrink(_ value: Self) -> [Self] { [] }
}

// MARK: - Gen<T>

public struct Gen<T> {
    public let run: (inout PalaceCheckRNG) -> T
    public init(_ run: @escaping (inout PalaceCheckRNG) -> T) { self.run = run }

    public func map<U>(_ f: @escaping (T) -> U) -> Gen<U> {
        Gen<U> { rng in f(self.run(&rng)) }
    }

    public func flatMap<U>(_ f: @escaping (T) -> Gen<U>) -> Gen<U> {
        Gen<U> { rng in f(self.run(&rng)).run(&rng) }
    }

    public func array(count: Int) -> Gen<[T]> {
        Gen<[T]> { rng in
            var out: [T] = []
            out.reserveCapacity(count)
            for _ in 0..<max(0, count) { out.append(self.run(&rng)) }
            return out
        }
    }

    public func array(of countGen: Gen<Int>) -> Gen<[T]> {
        countGen.flatMap { self.array(count: $0) }
    }

    public static func oneOf(_ choices: [Gen<T>]) -> Gen<T> {
        precondition(!choices.isEmpty, "Gen.oneOf requires at least one choice")
        return Gen<T> { rng in
            let i = Int(rng.next() % UInt64(choices.count))
            return choices[i].run(&rng)
        }
    }

    public static func frequency(_ weighted: [(Int, Gen<T>)]) -> Gen<T> {
        let total = weighted.reduce(0) { $0 + max(0, $1.0) }
        precondition(total > 0, "Gen.frequency requires positive total weight")
        return Gen<T> { rng in
            var pick = Int(rng.next() % UInt64(total))
            for (w, g) in weighted {
                pick -= w
                if pick < 0 { return g.run(&rng) }
            }
            return weighted.last!.1.run(&rng)
        }
    }

    public static func pure(_ value: T) -> Gen<T> {
        Gen { _ in value }
    }
}

// MARK: - forAll

public let PalaceCheckDefaultCount = 100
public let PalaceCheckMaxShrink = 10

@discardableResult
public func forAll<T: Arbitrary>(
    _ count: Int = PalaceCheckDefaultCount,
    seed: UInt64 = 0xC0FFEE,
    name: String = "property",
    _ property: (T) -> Bool,
    file: StaticString = #file,
    line: UInt = #line
) -> Bool {
    var rng = PalaceCheckRNG(seed: seed)
    for i in 0..<count {
        let value = T.generate(using: &rng)
        if !property(value) {
            let minimal = shrinkLoop(value, property: property)
            XCTFail(
                "PalaceCheck: \(name) failed at iteration \(i) (seed=\(seed)). Minimal counterexample: \(minimal)",
                file: file, line: line
            )
            return false
        }
    }
    return true
}

@discardableResult
public func forAll<A: Arbitrary, B: Arbitrary>(
    _ count: Int = PalaceCheckDefaultCount,
    seed: UInt64 = 0xC0FFEE,
    name: String = "property",
    _ property: (A, B) -> Bool,
    file: StaticString = #file,
    line: UInt = #line
) -> Bool {
    var rng = PalaceCheckRNG(seed: seed)
    for i in 0..<count {
        let a = A.generate(using: &rng)
        let b = B.generate(using: &rng)
        if !property(a, b) {
            // Shrink each independently, holding the other fixed.
            var minA = a, minB = b
            minA = shrinkLoop(minA, property: { property($0, minB) })
            minB = shrinkLoop(minB, property: { property(minA, $0) })
            XCTFail(
                "PalaceCheck: \(name) failed at iteration \(i) (seed=\(seed)). Minimal counterexample: (\(minA), \(minB))",
                file: file, line: line
            )
            return false
        }
    }
    return true
}

// MARK: - Shrinking driver

private func shrinkLoop<T: Arbitrary>(_ value: T, property: (T) -> Bool) -> T {
    var current = value
    for _ in 0..<PalaceCheckMaxShrink {
        let candidates = T.shrink(current)
        guard let smaller = candidates.first(where: { !property($0) }) else {
            return current
        }
        current = smaller
    }
    return current
}

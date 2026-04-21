# PalaceCheck — minimal property-based testing for Palace

PalaceCheck is a tiny, dependency-free property-based testing framework built
in-house because SwiftCheck is unmaintained and breaks under Xcode 16. Pure
Swift, only `XCTest` + `Foundation`.

## Writing a property

```swift
import XCTest
@testable import Palace

final class MyPropertyTests: XCTestCase {
    func test_reverse_is_involution() {
        forAll(100, name: "reverse∘reverse == id") { (xs: [Int]) in
            return Array(xs.reversed().reversed()) == xs
        }
    }
}
```

`forAll` runs the closure `count` times (default 100) with random inputs drawn
from each parameter's `Arbitrary` instance. If the closure ever returns `false`,
PalaceCheck shrinks the failing input to a minimal counterexample and calls
`XCTFail` with the seed and the value.

Two-argument variant:

```swift
forAll(50, name: "addition is commutative") { (a: Int, b: Int) in a + b == b + a }
```

## Adding `Arbitrary` for a new type

```swift
extension MyType: Arbitrary {
    static func generate(using rng: inout PalaceCheckRNG) -> MyType {
        MyType(field: Int.generate(using: &rng))
    }
    static func shrink(_ value: MyType) -> [MyType] {
        Int.shrink(value.field).map { MyType(field: $0) }
    }
}
```

If a Palace type lacks a public initializer, wrap it in a small `Arb…` struct
(see `ArbBook` in `PalaceCheckGenerators.swift`).

## Shrinking

When a property fails, PalaceCheck repeatedly asks
`Arbitrary.shrink(currentCounterexample)` for smaller candidates and picks the
first one that still fails the property. Up to `PalaceCheckMaxShrink` (10)
iterations.

Defaults provided:

- `Int` halves toward zero.
- `String` drops the first / last character or empties out.
- `Array` drops elements from either end or empties out.
- `Optional` shrinks to `nil` then to shrinks of the wrapped value.

If you don't supply `shrink`, the default returns `[]` (no shrinking) — the
original value is reported.

## Determinism / seeding

Every `forAll` accepts an explicit `seed: UInt64` parameter (default
`0xC0FFEE`). The RNG is a SplitMix64-based `PalaceCheckRNG`, fully
deterministic. To reproduce a CI failure, copy the `seed=` value out of the
`XCTFail` message and pass it back:

```swift
forAll(100, seed: 0xDEADBEEF, name: "...") { ... }
```

## Limits

- 100 cases per property by default; tune via `forAll(N, ...)`.
- Max 10 shrink iterations per failure.
- No async / throwing properties yet — wrap manually if you need them.
- Generators are pure functions of the RNG; no global state.

## PROPERTY-GAP markers

Where a Palace type has no public surface that lets us assert the “real”
property cleanly, the test file marks `// PROPERTY-GAP: <reason>` and tests the
closest available contract. Search the test file for these to find candidates
for follow-up refactors.

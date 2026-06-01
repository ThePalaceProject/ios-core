// Palace/Fixtures/ProtocolIsolationKnownGood.swift
//
// KNOWN-GOOD fixture for check-protocol-isolation.py.
//
// Three patterns that must NOT flag:
//   1. Protocol IS @MainActor; conformers @MainActor → fine.
//   2. Protocol non-isolated; mixed conformers (one @MainActor, one not) →
//      not a single-point-of-fix candidate.
//   3. Protocol with 1 conformer → too few to imply a pattern.

import Foundation

@MainActor
protocol AlreadyIsolatedDelegate {
    func ping()
}

@MainActor
final class AlreadyA: AlreadyIsolatedDelegate {
    func ping() {}
}

@MainActor
final class AlreadyB: AlreadyIsolatedDelegate {
    func ping() {}
}

// Mixed conformers — not a candidate.
protocol MixedConformers {
    func emit()
}

@MainActor
final class MixedMainActor: MixedConformers {
    func emit() {}
}

final class MixedNonIsolated: MixedConformers {
    func emit() {}
}

// Single conformer — below the ≥2 threshold.
protocol SingleConformerOnly {
    func fire()
}

@MainActor
final class LonelyConformer: SingleConformerOnly {
    func fire() {}
}

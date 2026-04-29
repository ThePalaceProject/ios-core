//
//  PalaceCheckGenerators.swift
//  PalaceTests
//
//  Arbitrary instances for primitive types and Palace domain types.
//

import Foundation
import PalaceCatalog
@testable import Palace

// MARK: - Primitives

extension Int: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> Int {
        // Bound to a reasonable range so shrinking terminates.
        let v = Int(truncatingIfNeeded: rng.next())
        return v % 10_000
    }
    public static func shrink(_ value: Int) -> [Int] {
        if value == 0 { return [] }
        var out: [Int] = [0]
        if value > 0 { out.append(value / 2) }
        if value < 0 { out.append(value / 2); out.append(-value) }
        if value != 1 && value > 0 { out.append(value - 1) }
        return out
    }
}

extension Bool: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> Bool {
        (rng.next() & 1) == 1
    }
    public static func shrink(_ value: Bool) -> [Bool] { value ? [false] : [] }
}

extension String: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> String {
        let length = Int(rng.next() % 16)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var s = ""
        for _ in 0..<length {
            let idx = Int(rng.next() % UInt64(alphabet.count))
            s.append(alphabet[idx])
        }
        return s
    }
    public static func shrink(_ value: String) -> [String] {
        if value.isEmpty { return [] }
        var out: [String] = [""]
        // Drop characters one by one from the end.
        if value.count > 1 { out.append(String(value.dropLast())) }
        if value.count > 1 { out.append(String(value.dropFirst())) }
        return out
    }
}

extension Date: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> Date {
        // 0..2^31 seconds since epoch — keeps inside reasonable range.
        let secs = Double(rng.next() % UInt64(2_000_000_000))
        return Date(timeIntervalSince1970: secs)
    }
}

extension URL: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> URL {
        let token = String.generate(using: &rng)
            .replacingOccurrences(of: " ", with: "")
        let safe = token.isEmpty ? "x" : token
        return URL(string: "https://example.com/\(safe)") ?? URL(string: "https://example.com/x")!
    }
}

extension Optional: Arbitrary where Wrapped: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> Optional<Wrapped> {
        if (rng.next() & 3) == 0 { return nil }
        return Wrapped.generate(using: &rng)
    }
    public static func shrink(_ value: Optional<Wrapped>) -> [Optional<Wrapped>] {
        switch value {
        case .none: return []
        case .some(let w):
            var out: [Optional<Wrapped>] = [nil]
            out.append(contentsOf: Wrapped.shrink(w).map { Optional.some($0) })
            return out
        }
    }
}

extension Array: Arbitrary where Element: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> [Element] {
        let n = Int(rng.next() % 8)
        var out: [Element] = []
        for _ in 0..<n { out.append(Element.generate(using: &rng)) }
        return out
    }
    public static func shrink(_ value: [Element]) -> [[Element]] {
        if value.isEmpty { return [] }
        var out: [[Element]] = [[]]
        if value.count > 1 {
            out.append(Array(value.dropLast()))
            out.append(Array(value.dropFirst()))
        }
        return out
    }
}

// MARK: - TPPBookState

extension TPPBookState: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> TPPBookState {
        let all = TPPBookState.allCases
        let idx = Int(rng.next() % UInt64(all.count))
        return all[idx]
    }
}

// MARK: - TPPBook

/// Wrapper so we can attach Arbitrary without polluting the production type.
public struct ArbBook: Arbitrary {
    public let book: TPPBook
    public static func generate(using rng: inout PalaceCheckRNG) -> ArbBook {
        let id = "pcheck-\(rng.next())"
        let title = "Title \(rng.next() % 10_000)"
        let author = "Author \(rng.next() % 10_000)"
        return ArbBook(book: TPPBookMocker.mockBook(
            identifier: id,
            title: title,
            authors: author
        ))
    }
}

// MARK: - OPDS2Publication

extension OPDS2Publication: Arbitrary {
    public static func generate(using rng: inout PalaceCheckRNG) -> OPDS2Publication {
        let title = String.generate(using: &rng)
        let safeTitle = title.isEmpty ? "Untitled" : title
        let id = "urn:uuid:\(rng.next())"
        // Round-trip-safe Date: encode/decode through JSON loses sub-second precision.
        // Use whole-second epoch dates so equality survives.
        let secs = Double(rng.next() % UInt64(2_000_000_000))
        let updated: Date? = ((rng.next() & 1) == 0) ? Date(timeIntervalSince1970: secs) : nil
        let metadata = OPDS2Publication.Metadata(
            updated: updated,
            description: ((rng.next() & 1) == 0) ? "desc \(rng.next() % 1000)" : nil,
            id: id,
            title: safeTitle
        )
        // Keep links empty — OPDS2Link generation is out of scope for this initial pass.
        return OPDS2Publication(links: [], metadata: metadata, images: nil)
    }
}

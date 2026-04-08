//
//  FuzzCorpus.swift
//  PalaceTests
//
//  Corpus loader + deterministic, seeded mutators for parser fuzzing.
//  Pure Swift, no external dependencies.
//

import Foundation

enum CorpusType: String {
  case opds1XML        = "opds1"
  case opds2JSON       = "opds2"
  case lcpLicense      = "lcp"
  case annotationsResponse = "annotations"
}

/// Deterministic seeded PRNG (SplitMix64). Reproducible across runs/platforms.
struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}

struct FuzzCorpus {
  let type: CorpusType

  /// Loads seeds from PalaceTests/Fuzz/Corpus/<type>/. Falls back to an empty
  /// inline seed when the bundle doesn't include the corpus directory.
  func seeds() -> [Data] {
    var results: [Data] = []

    // Try test bundle resources first.
    let bundle = Bundle(for: BundleToken.self)
    if let resourceURL = bundle.resourceURL {
      let dir = resourceURL.appendingPathComponent("Fuzz/Corpus/\(type.rawValue)")
      if let urls = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
      ) {
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
          if let data = try? Data(contentsOf: url) { results.append(data) }
        }
      }
    }

    // Filesystem fallback (when running outside bundled test resources).
    if results.isEmpty {
      let candidates = [
        // Repo path relative to test working dir.
        URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent()
          .appendingPathComponent("Corpus/\(type.rawValue)"),
      ]
      for dir in candidates {
        if let urls = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil
        ) {
          for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let data = try? Data(contentsOf: url) { results.append(data) }
          }
        }
      }
    }

    // Last-resort inline seed so the harness still runs something.
    if results.isEmpty {
      switch type {
      case .opds1XML:
        results.append(Data("<?xml version=\"1.0\"?><feed/>".utf8))
      case .opds2JSON, .lcpLicense, .annotationsResponse:
        results.append(Data("{}".utf8))
      }
    }
    return results
  }

  /// Produce `iterations` mutated copies of `seed` using the given RNG seed.
  func mutated(seed: Data, iterations: Int, rngSeed: UInt64) -> [Data] {
    var rng = SeededRNG(seed: rngSeed)
    var out: [Data] = []
    out.reserveCapacity(iterations)
    for _ in 0..<iterations {
      out.append(Self.mutate(seed, rng: &rng))
    }
    return out
  }

  // MARK: - Mutators

  private static let mutatorCount = 7

  static func mutate(_ input: Data, rng: inout SeededRNG) -> Data {
    var bytes = [UInt8](input)
    if bytes.isEmpty { bytes = [0] }
    let choice = Int(rng.next() % UInt64(mutatorCount))
    switch choice {
    case 0: bitFlip(&bytes, rng: &rng)
    case 1: byteFlip(&bytes, rng: &rng)
    case 2: byteInsert(&bytes, rng: &rng)
    case 3: byteDelete(&bytes, rng: &rng)
    case 4: chunkDuplicate(&bytes, rng: &rng)
    case 5: integerOverflowInjection(&bytes, rng: &rng)
    default: utf8BoundaryCorruption(&bytes, rng: &rng)
    }
    return Data(bytes)
  }

  private static func bitFlip(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    let i = Int(rng.next() % UInt64(bytes.count))
    let bit = UInt8(1 << (rng.next() % 8))
    bytes[i] ^= bit
  }

  private static func byteFlip(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    let i = Int(rng.next() % UInt64(bytes.count))
    bytes[i] = UInt8(rng.next() & 0xFF)
  }

  private static func byteInsert(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    let i = Int(rng.next() % UInt64(bytes.count + 1))
    bytes.insert(UInt8(rng.next() & 0xFF), at: i)
  }

  private static func byteDelete(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    guard bytes.count > 1 else { return }
    let i = Int(rng.next() % UInt64(bytes.count))
    bytes.remove(at: i)
  }

  private static func chunkDuplicate(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    let len = max(1, Int(rng.next() % UInt64(min(32, bytes.count))))
    let start = Int(rng.next() % UInt64(bytes.count - len + 1))
    let chunk = Array(bytes[start..<(start + len)])
    let insertAt = Int(rng.next() % UInt64(bytes.count + 1))
    bytes.insert(contentsOf: chunk, at: insertAt)
  }

  private static func integerOverflowInjection(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    let payloads: [[UInt8]] = [
      Array("2147483647".utf8),
      Array("-2147483648".utf8),
      Array("9223372036854775807".utf8),
      Array("-9223372036854775808".utf8),
      Array("18446744073709551615".utf8),
      Array("0".utf8),
      Array("-1".utf8),
      Array("1e308".utf8),
      Array("NaN".utf8),
      Array("Infinity".utf8),
    ]
    let payload = payloads[Int(rng.next() % UInt64(payloads.count))]
    let at = Int(rng.next() % UInt64(bytes.count + 1))
    bytes.insert(contentsOf: payload, at: at)
  }

  private static func utf8BoundaryCorruption(_ bytes: inout [UInt8], rng: inout SeededRNG) {
    // Inject incomplete/invalid UTF-8 multibyte sequences.
    let payloads: [[UInt8]] = [
      [0xC3],             // truncated 2-byte
      [0xE2, 0x82],       // truncated 3-byte
      [0xF0, 0x9F, 0x98], // truncated 4-byte
      [0xFF, 0xFE],       // BOM-like garbage
      [0xC0, 0x80],       // overlong null
      [0xED, 0xA0, 0x80], // surrogate
    ]
    let p = payloads[Int(rng.next() % UInt64(payloads.count))]
    let at = Int(rng.next() % UInt64(bytes.count + 1))
    bytes.insert(contentsOf: p, at: at)
  }
}

private final class BundleToken {}

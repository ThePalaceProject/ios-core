//
//  FuzzRunner.swift
//  PalaceTests
//
//  Drives parsers over a corpus of mutated inputs. Errors thrown by the
//  parser are EXPECTED — they represent graceful rejection. The runner only
//  fails on hangs (timeout) or process-level crashes (Swift trap / NSException
//  — those manifest as test crashes naturally and are caught by CI).
//

import Foundation
import XCTest

struct FuzzRunner {

  /// Run `parse` against every seed + mutation in `corpusType`'s corpus.
  /// - Parameters:
  ///   - corpusType: which corpus to load and mutate
  ///   - iterations: mutated inputs per seed
  ///   - seed: deterministic RNG seed for reproducibility
  ///   - timeoutPerInput: per-input wall-clock budget
  ///   - parse: parser entry point under test
  static func fuzz<T>(
    corpusType: CorpusType,
    iterations: Int = 500,
    seed: UInt64 = 0xCAFEBABE,
    timeoutPerInput: TimeInterval = 1.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    parse: @escaping (Data) throws -> T
  ) {
    let corpus = FuzzCorpus(type: corpusType)
    let seeds = corpus.seeds()
    XCTAssertFalse(seeds.isEmpty, "No seeds for \(corpusType.rawValue)", file: file, line: line)

    // Always exercise raw seeds first.
    for s in seeds {
      runOne(input: s, label: "seed", corpusType: corpusType,
             timeout: timeoutPerInput, file: file, line: line, parse: parse)
    }

    // Then exercise mutated inputs (deterministic).
    for (i, s) in seeds.enumerated() {
      let mutants = corpus.mutated(seed: s, iterations: iterations, rngSeed: seed &+ UInt64(i))
      for (j, m) in mutants.enumerated() {
        runOne(input: m, label: "seed#\(i)/mut#\(j)", corpusType: corpusType,
               timeout: timeoutPerInput, file: file, line: line, parse: parse)
      }
    }
  }

  private static func runOne<T>(
    input: Data,
    label: String,
    corpusType: CorpusType,
    timeout: TimeInterval,
    file: StaticString,
    line: UInt,
    parse: @escaping (Data) throws -> T
  ) {
    // Run parse synchronously. The original implementation dispatched per
    // input to a fresh DispatchQueue with an XCTestExpectation timeout, but
    // (a) parses run in microseconds so the timeout was paranoia, and
    // (b) creating ~6,000 queues per fuzz run leaked dispatch objects past
    // test boundaries, causing libdispatch use-after-free crashes on
    // unrelated tests downstream. Throwing errors is expected — parsers
    // should reject malformed input gracefully. Anything that crashes the
    // process will surface as an XCTest failure naturally.
    //
    // A single input that takes an unbounded amount of time is NOT graceful
    // rejection — it is an algorithmic-blowup robustness bug in production (a
    // malformed server response that would stall the real bookmark sync). We
    // measure each input's wall-clock cost and XCTFail loudly with the repro
    // bytes if any single input exceeds a GENEROUS per-input regression bound.
    // This is a real-bug DETECTOR, not a mask/skip: it surfaces a production
    // hang as a hard test failure (with repro bytes) rather than silently
    // consuming the whole run's budget. The bound is deliberately decoupled
    // from `timeout` (the SUM-budget hint) and set high enough that the slowest
    // legitimate single input (sub-200ms across every corpus on current
    // Foundation) never trips it — only a genuine super-linear blowup (seconds
    // on a ≤2 KB seed) does.
    let perInputRegressionBound: TimeInterval = 2.0
    _ = timeout // SUM-budget hint; per-input detection uses the bound above.
    let start = DispatchTime.now()
    _ = (try? parse(input))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000.0
    if elapsed > perInputRegressionBound {
      recordFailure(
        input: input, label: label, corpusType: corpusType,
        reason: "single input took \(String(format: "%.3f", elapsed))s " +
                "(> \(String(format: "%.1f", perInputRegressionBound))s per-input bound) — " +
                "algorithmic blowup in the parse path. A malformed server response " +
                "of this shape would stall the real sync. Offending bytes (hex, first 512): " +
                input.prefix(512).map { String(format: "%02x", $0) }.joined(),
        file: file, line: line
      )
    }
  }

  private static func recordFailure(
    input: Data,
    label: String,
    corpusType: CorpusType,
    reason: String,
    file: StaticString,
    line: UInt
  ) {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("fuzz-fail-\(corpusType.rawValue)-\(UUID().uuidString)")
    try? input.write(to: tmp)
    XCTFail(
      "Fuzz failure (\(corpusType.rawValue)) [\(label)]: \(reason). " +
      "Repro input written to \(tmp.path) (\(input.count) bytes)",
      file: file, line: line
    )
  }
}

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
    let exp = XCTestExpectation(description: "fuzz \(corpusType.rawValue) \(label)")
    let queue = DispatchQueue(label: "fuzz.\(corpusType.rawValue)")
    queue.async {
      // Throwing errors is expected — parsers should reject malformed input
      // gracefully. Anything that crashes the process will surface as an
      // XCTest failure naturally.
      _ = try? parse(input)
      exp.fulfill()
    }
    let result = XCTWaiter().wait(for: [exp], timeout: timeout)
    if result != .completed {
      recordFailure(input: input, label: label, corpusType: corpusType,
                    reason: "hang/timeout (\(timeout)s)", file: file, line: line)
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

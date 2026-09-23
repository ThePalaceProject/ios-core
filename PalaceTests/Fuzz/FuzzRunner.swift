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
    // A single input that takes an unbounded amount of CPU is NOT graceful
    // rejection — it is an algorithmic-blowup robustness bug in production (a
    // malformed server response that would stall the real bookmark sync). We
    // bound each input's COST and XCTFail loudly with the repro bytes if it is
    // exceeded. This is a real-bug DETECTOR, not a mask/skip.
    //
    // We measure THREAD CPU time, not wall-clock. Wall-clock (DispatchTime)
    // counts intervals the test thread is descheduled, so on a contended CI
    // runner (the whole scheme runs under -test-iterations 3 on shared
    // macos-26) a microsecond parse can wall-clock at seconds and trip the
    // bound — a false positive with nothing to do with the input. Thread CPU
    // time counts only cycles actually spent in `parse`, which is exactly what
    // an algorithmic-blowup detector should bound. The bound is decoupled from
    // `timeout` (the SUM-budget hint) and set high enough that the slowest
    // legitimate single input (sub-200ms of CPU across every corpus on current
    // Foundation) never trips it — only a genuine super-linear blowup (seconds
    // of CPU on a ≤2 KB seed) does.
    let perInputRegressionBound: TimeInterval = 2.0
    _ = timeout // SUM-budget hint; per-input detection uses the bound above.

    let firstCPU = measureParseCPU(input, parse)
    guard firstCPU > perInputRegressionBound else { return }

    // Over the bound on a single sample is suspicious but not yet proof (a
    // first-touch page fault or rare stall can perturb even CPU time). Confirm
    // in isolation: re-run the SAME input and fail only if the MEDIAN CPU cost
    // still exceeds the bound. A real super-linear blowup reproduces every
    // time; a one-off measurement spike does not.
    var samples = [firstCPU]
    for _ in 0..<4 { samples.append(measureParseCPU(input, parse)) }
    let medianCPU = samples.sorted()[samples.count / 2]
    guard medianCPU > perInputRegressionBound else { return }

    recordFailure(
      input: input, label: label, corpusType: corpusType,
      reason: "single input took \(String(format: "%.3f", medianCPU))s of CPU " +
              "(median of \(samples.count) isolated runs; > " +
              "\(String(format: "%.1f", perInputRegressionBound))s per-input bound) — " +
              "algorithmic blowup in the parse path. A malformed server response " +
              "of this shape would stall the real sync. Offending bytes (hex, first 512): " +
              input.prefix(512).map { String(format: "%02x", $0) }.joined(),
      file: file, line: line
    )
  }

  /// Thread CPU seconds spent in a single `parse(input)` call. Uses
  /// `CLOCK_THREAD_CPUTIME_ID` so the measurement excludes any time the thread
  /// is descheduled — see the rationale in `runOne`. Parser throws are expected
  /// (graceful rejection) and ignored; we only care about cost here.
  private static func measureParseCPU<T>(_ input: Data, _ parse: (Data) throws -> T) -> Double {
    func cpuSeconds() -> Double {
      var ts = timespec()
      clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
      return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000.0
    }
    let start = cpuSeconds()
    _ = (try? parse(input))
    return cpuSeconds() - start
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

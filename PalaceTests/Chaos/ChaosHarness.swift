//
//  ChaosHarness.swift
//  PalaceTests
//
//  Reusable fault injection harness for chaos / fault-injection tests.
//  Provides URLProtocol-based network fault injection, file-system write
//  rejection, simulated memory warnings, and token-expiry helpers.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import XCTest
@testable import Palace

// MARK: - FaultInjector Protocol

/// A unit of chaos. Activate before exercising the system under test,
/// deactivate during tearDown.
protocol FaultInjector {
  func activate()
  func deactivate()
}

// MARK: - ChaosURLProtocol

/// A URLProtocol that can simulate a variety of network faults:
///   * drop connection after N bytes have been delivered
///   * fail outright with a specified NSError after N bytes
///   * return HTTP 401 on the Nth matching request (token expiry)
///
/// Configuration is global (process-wide) so this protocol can be installed
/// into any URLSession via `URLSessionConfiguration.protocolClasses`.
final class ChaosURLProtocol: URLProtocol {

  struct Plan {
    /// Total payload to deliver if no fault triggers.
    var fullBody: Data = Data(repeating: 0x41, count: 1024)
    /// If non-nil, after delivering this many bytes, drop the connection.
    var dropAfterBytes: Int? = nil
    /// If non-nil, after delivering this many bytes, fail with this error.
    var failAfterBytes: Int? = nil
    var failError: NSError = NSError(domain: NSURLErrorDomain,
                                     code: NSURLErrorNetworkConnectionLost,
                                     userInfo: nil)
    /// 1-based index: the Nth request matched will return HTTP 401.
    var unauthorizedOnRequest: Int? = nil
    /// HTTP status to return when no fault triggers.
    var statusCode: Int = 200
    /// Optional response headers.
    var headers: [String: String]? = nil
  }

  private static let queue = DispatchQueue(label: "ChaosURLProtocol.queue")
  private static var _plan = Plan()
  private static var _requestCount: Int = 0

  static func setPlan(_ plan: Plan) {
    queue.sync {
      _plan = plan
      _requestCount = 0
    }
  }

  static func reset() {
    queue.sync {
      _plan = Plan()
      _requestCount = 0
    }
  }

  static func currentRequestCount() -> Int {
    queue.sync { _requestCount }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    let (plan, requestNumber): (Plan, Int) = Self.queue.sync {
      Self._requestCount += 1
      return (Self._plan, Self._requestCount)
    }

    let url = request.url ?? URL(string: "about:blank")!

    // Token expiry: return 401 on the configured request index.
    if let nthUnauthorized = plan.unauthorizedOnRequest, requestNumber == nthUnauthorized {
      let response = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: "HTTP/1.1",
        headerFields: plan.headers
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: plan.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: plan.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    // Stream the body in chunks so we can interrupt mid-flight.
    let body = plan.fullBody
    let chunkSize = max(1, body.count / 8)
    var delivered = 0

    while delivered < body.count {
      let end = min(delivered + chunkSize, body.count)
      let chunk = body.subdata(in: delivered..<end)
      client?.urlProtocol(self, didLoad: chunk)
      delivered = end

      if let dropAt = plan.dropAfterBytes, delivered >= dropAt {
        let err = NSError(domain: NSURLErrorDomain,
                          code: NSURLErrorNetworkConnectionLost,
                          userInfo: nil)
        client?.urlProtocol(self, didFailWithError: err)
        return
      }
      if let failAt = plan.failAfterBytes, delivered >= failAt {
        client?.urlProtocol(self, didFailWithError: plan.failError)
        return
      }
    }

    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { }
}

// MARK: - Concrete FaultInjectors

/// Drops the connection after N bytes have been streamed.
final class NetworkDropInjector: FaultInjector {
  let afterBytes: Int
  let totalBytes: Int

  init(afterBytes: Int, totalBytes: Int = 4096) {
    self.afterBytes = afterBytes
    self.totalBytes = totalBytes
  }

  func activate() {
    var plan = ChaosURLProtocol.Plan()
    plan.fullBody = Data(repeating: 0x42, count: totalBytes)
    plan.dropAfterBytes = afterBytes
    ChaosURLProtocol.setPlan(plan)
  }

  func deactivate() {
    ChaosURLProtocol.reset()
  }
}

/// Returns HTTP 401 on the Nth matching request, then 200 thereafter.
final class TokenExpiryInjector: FaultInjector {
  let onRequestIndex: Int

  init(onRequestIndex: Int = 1) {
    self.onRequestIndex = onRequestIndex
  }

  func activate() {
    var plan = ChaosURLProtocol.Plan()
    plan.unauthorizedOnRequest = onRequestIndex
    ChaosURLProtocol.setPlan(plan)
  }

  func deactivate() {
    ChaosURLProtocol.reset()
  }
}

/// Posts a UIApplication memory warning notification on activation.
final class MemoryWarningInjector: FaultInjector {
  func activate() {
    NotificationCenter.default.post(
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }
  func deactivate() { }
}

/// Backed by `FailingFileManager`, raises an IO failure when more than
/// `failAfterBytes` would be written to a single file.
final class DiskFullInjector: FaultInjector {
  let failAfterBytes: Int
  private(set) var fileManager: FailingFileManager

  init(failAfterBytes: Int) {
    self.failAfterBytes = failAfterBytes
    self.fileManager = FailingFileManager(failAfterBytes: failAfterBytes)
  }

  func activate() {
    fileManager.enabled = true
  }
  func deactivate() {
    fileManager.enabled = false
    fileManager.cleanup()
  }
}

// MARK: - FailingFileManager

/// A FileManager-style helper that rejects writes once a per-test byte
/// budget has been exceeded. This is NOT a global FileManager swap — call
/// sites must use it explicitly. It scopes all writes to a unique
/// subdirectory under `FileManager.default.temporaryDirectory` so tests
/// remain hermetic.
final class FailingFileManager {
  let failAfterBytes: Int
  var enabled: Bool = false
  let scratchDir: URL

  init(failAfterBytes: Int) {
    self.failAfterBytes = failAfterBytes
    self.scratchDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChaosScratch-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratchDir,
                                             withIntermediateDirectories: true)
  }

  enum FailingFileError: Error {
    case diskFull(bytesAttempted: Int, budget: Int)
  }

  /// Attempt to write `data` to `url`. Throws `diskFull` if injection is
  /// active and the data exceeds the configured budget.
  func write(_ data: Data, to url: URL) throws {
    if enabled && data.count > failAfterBytes {
      // Simulate a partial write so callers can verify cleanup.
      let partial = data.prefix(failAfterBytes)
      try? partial.write(to: url, options: .atomic)
      throw FailingFileError.diskFull(bytesAttempted: data.count,
                                      budget: failAfterBytes)
    }
    try data.write(to: url, options: .atomic)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: scratchDir)
  }
}

// MARK: - Helpers

enum ChaosHarness {

  /// Install ChaosURLProtocol into a fresh URLSession for hermetic use.
  static func chaosSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChaosURLProtocol.self]
    return URLSession(configuration: config)
  }

  /// Run a block while a memory warning is broadcast in the middle.
  static func withMemoryWarning(_ block: () throws -> Void) rethrows {
    let injector = MemoryWarningInjector()
    injector.activate()
    defer { injector.deactivate() }
    try block()
  }

  /// Run a block with a FailingFileManager scoped to a byte budget.
  static func withFailingDisk(afterBytes bytes: Int,
                              _ block: (FailingFileManager) throws -> Void) rethrows {
    let injector = DiskFullInjector(failAfterBytes: bytes)
    injector.activate()
    defer { injector.deactivate() }
    try block(injector.fileManager)
  }

  /// Run a block with the network protocol set to drop the connection
  /// after N bytes. Tests must use `chaosSession()` to observe the fault.
  static func withDroppedConnection(afterBytes bytes: Int,
                                    totalBytes: Int = 4096,
                                    _ block: () throws -> Void) rethrows {
    let injector = NetworkDropInjector(afterBytes: bytes, totalBytes: totalBytes)
    injector.activate()
    defer { injector.deactivate() }
    try block()
  }
}

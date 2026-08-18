//
//  ErrorLoggerSpy.swift
//  PalaceTests
//
//  Records what production code reports to error logging, so tests can assert
//  on it (PP-4965). Whether a failure is reported AT ALL — and with what
//  underlying error attached — is behaviour, not a side effect: reporting a
//  write that was safely queued for retry is what made "Error posting
//  annotation" the largest error in the app.
//

import Foundation
@testable import Palace

/// `@unchecked Sendable`: all mutable state is guarded by `lock`, mirroring
/// `TPPBookRegistryMock`. Reports can arrive from whatever queue the network
/// completion ran on, so an unsynchronized array here is a data race that
/// would surface as a flake rather than a failure.
final class ErrorLoggerSpy: ErrorLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _loggedSummaries: [String] = []
    private var _loggedErrors: [Error?] = []
    private var _loggedMetadata: [[String: Any]] = []
    private var _loggedCodes: [TPPErrorCode] = []

    var loggedSummaries: [String] { lock.withLock { _loggedSummaries } }
    var loggedErrors: [Error?] { lock.withLock { _loggedErrors } }
    var loggedMetadata: [[String: Any]] { lock.withLock { _loggedMetadata } }

    /// The TPPErrorCode each report was filed under. `.apiCall` (902) is the
    /// annotation bucket; a change that moves off it is a telemetry regression.
    var loggedCodes: [TPPErrorCode] { lock.withLock { _loggedCodes } }

    private func record(summary: String, error: Error?, metadata: [String: Any]?) {
        lock.withLock {
            _loggedSummaries.append(summary)
            _loggedErrors.append(error)
            _loggedMetadata.append(metadata ?? [:])
        }
    }

    /// The underlying error of the first report, flattened and bridged.
    /// `loggedErrors` is `[Error?]`, so `.first` is doubly optional — reading
    /// it without flattening silently compares against nil.
    var firstReportedNSError: NSError? {
        (loggedErrors.first ?? nil) as NSError?
    }

    /// The Crashlytics code the first report would carry. Asserting this is how
    /// the suite catches a reporting change that silently moves the bucket —
    /// the defect review caught on this branch (PP-4965).
    var firstReportedCode: Int? { firstReportedNSError?.code }

    func logError(_ error: Error?, summary: String, metadata: [String: Any]?) {
        record(summary: summary, error: error, metadata: metadata)
    }

    func logError(withCode code: TPPErrorCode, summary: String, metadata: [String: Any]?) {
        record(summary: summary, error: nil, metadata: metadata)
        lock.withLock { _loggedCodes.append(code) }
    }

    func logNetworkError(_ originalError: Error?,
                         code: TPPErrorCode,
                         summary: String?,
                         request: URLRequest?,
                         response: URLResponse?,
                         metadata: [String: Any]?) {
        record(summary: summary ?? "", error: originalError, metadata: metadata)
        lock.withLock { _loggedCodes.append(code) }
    }
}

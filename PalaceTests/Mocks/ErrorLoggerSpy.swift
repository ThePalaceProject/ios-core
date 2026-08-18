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

final class ErrorLoggerSpy: ErrorLogging {
    private(set) var loggedSummaries: [String] = []
    private(set) var loggedErrors: [Error?] = []
    private(set) var loggedMetadata: [[String: Any]] = []

    /// The underlying error of the first report, flattened and bridged.
    /// `loggedErrors` is `[Error?]`, so `.first` is doubly optional — reading
    /// it without flattening silently compares against nil.
    var firstReportedNSError: NSError? {
        (loggedErrors.first ?? nil) as NSError?
    }

    func logError(_ error: Error?, summary: String, metadata: [String: Any]?) {
        loggedSummaries.append(summary)
        loggedErrors.append(error)
        loggedMetadata.append(metadata ?? [:])
    }

    func logError(withCode code: TPPErrorCode, summary: String, metadata: [String: Any]?) {
        loggedSummaries.append(summary)
        loggedErrors.append(nil)
        loggedMetadata.append(metadata ?? [:])
    }

    func logNetworkError(_ originalError: Error?,
                         code: TPPErrorCode,
                         summary: String?,
                         request: URLRequest?,
                         response: URLResponse?,
                         metadata: [String: Any]?) {
        loggedSummaries.append(summary ?? "")
        loggedErrors.append(originalError)
        loggedMetadata.append(metadata ?? [:])
    }
}

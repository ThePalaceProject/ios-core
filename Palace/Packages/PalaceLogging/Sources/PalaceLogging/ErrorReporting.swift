//
//  ErrorReporting.swift
//  PalaceLogging
//
//  Error-reporting seam so domain code never names the app-target
//  TPPErrorLogger. Same pattern as CrashlyticsLogBridge: the protocol lives
//  here and the host app supplies the witness.
//

import Foundation

public protocol ErrorReporting: Sendable {
    /// Report a caught error.
    func report(_ error: any Error, summary: String, metadata: [String: Any]?)
    /// Report a coded condition with no underlying Error. `code` is the raw
    /// TPPErrorCode value app-side; the app witness maps it back. TPPErrorCode
    /// stays in the app target because every logError(withCode:) site uses it.
    func report(code: Int, summary: String, metadata: [String: Any]?)
}

public extension ErrorReporting {
    func report(_ error: any Error, summary: String) {
        report(error, summary: summary, metadata: nil)
    }
}

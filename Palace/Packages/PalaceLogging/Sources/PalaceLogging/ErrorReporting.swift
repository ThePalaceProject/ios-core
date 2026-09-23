//
//  ErrorReporting.swift
//  PalaceLogging
//
//  Wave 1c (god-class decomposition, cycle 2): error-reporting seam so domain
//  code (Accounts today; PalaceAccounts in Wave 3) never names the app-target
//  TPPErrorLogger. Mirrors the CrashlyticsLogBridge pattern: protocol lives
//  package-side, the host app supplies the witness.
//

import Foundation

public protocol ErrorReporting: Sendable {
    /// Report a caught error.
    func report(_ error: any Error, summary: String, metadata: [String: Any]?)
    /// Report a coded condition with no underlying Error. `code` is the raw
    /// TPPErrorCode value app-side; the app witness maps it back. (TPPErrorCode
    /// itself stays app-target this wave — moving it is member-import churn
    /// across every logError(withCode:) call site; revisit in Wave 3.)
    func report(code: Int, summary: String, metadata: [String: Any]?)
}

public extension ErrorReporting {
    func report(_ error: any Error, summary: String) {
        report(error, summary: summary, metadata: nil)
    }
}

//
//  TPPErrorReporter.swift
//  Palace
//
//  Wave 1c (cycle 2): app-target ErrorReporting witness — forwards to the
//  TPPErrorLogger class funcs (Crashlytics-backed).
//

import Foundation
import PalaceLogging

struct TPPErrorReporter: ErrorReporting {
    func report(_ error: any Error, summary: String, metadata: [String: Any]?) {
        TPPErrorLogger.logError(error, summary: summary, metadata: metadata)
    }

    func report(code: Int, summary: String, metadata: [String: Any]?) {
        TPPErrorLogger.logError(withCode: TPPErrorCode(rawValue: code) ?? .ignore,
                                summary: summary,
                                metadata: metadata)
    }
}

/// Typed convenience so app-side call sites keep TPPErrorCode ergonomics.
/// Lives app-side because TPPErrorCode is app-target (`TPPErrorLogger.swift:128`,
/// `@objc enum TPPErrorCode: Int` — `case ignore = 0` is the mapping fallback).
extension ErrorReporting {
    func report(code: TPPErrorCode, summary: String, metadata: [String: Any]? = nil) {
        report(code: code.rawValue, summary: summary, metadata: metadata)
    }
}

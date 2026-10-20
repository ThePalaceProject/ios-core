//
//  SupportReportContext.swift
//  Palace
//
//  Account context that support emails and exported diagnostics carry. The
//  patron's authorization identifier (usually the library card barcode) is
//  hashed when the context is built, so no report path can send it raw
//  (PP-4818).
//

import TriageBotCore

struct SupportReportContext: Equatable {
    /// A stable token for the patron, the same one the triage bot attaches, so
    /// support can match a legacy report to bot tickets. An 8-character hash
    /// over an enumerable barcode space is pseudonymization for lookup, not
    /// anonymity.
    let patronReference: String?
    let libraryName: String?
    let libraryUUID: String?

    init(rawPatronIdentifier: String?, libraryName: String?, libraryUUID: String?) {
        patronReference = rawPatronIdentifier
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { ContextRedactor().hashIdentifier($0) }
        self.libraryName = libraryName
        self.libraryUUID = libraryUUID
    }

    /// The body line both report formats print, or nil when no patron is
    /// signed in.
    var patronReferenceLine: String? {
        patronReference.map { "Patron reference: \($0)" }
    }
}

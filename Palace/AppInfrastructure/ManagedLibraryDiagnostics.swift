//
//  ManagedLibraryDiagnostics.swift
//  Palace
//
//  PP-5221 — making a mistyped library configuration diagnosable.
//
//  ## The problem this solves
//
//  A library identifier is a long string of hexadecimal that an administrator
//  pastes into a form. Sooner or later one will be wrong. Today the app writes
//  a line to its own log and carries on showing the picker, so the ticket we
//  receive says "we set it up and nothing happened" and there is no way to tell
//  the administrator whether they mistyped the value, put it in the wrong
//  field, or named a library we genuinely cannot reach. That is a support
//  conversation measured in days for a problem measured in one character.
//
//  ## Two rules
//
//  **Distinguish the cases that call for different answers.** "Not a UUID",
//  "a UUID we cannot find", and "we are still looking" lead to three different
//  replies to the school, and collapsing them into one report would make the
//  report useless.
//
//  **Stay quiet when nothing is wrong.** Two ways this could become noise
//  nobody reads, both avoided here:
//
//  - Reporting `.unresolved` before the wait expires would fire on every slow
//    launch, because on a cold start the configured library is legitimately
//    absent until the network registry lands. Only an expired wait is news.
//  - Reporting on every launch would mean one misconfigured device files a
//    report a day forever. Reporting is keyed on the configuration VALUE, the
//    same discipline as applying it: a value already reported is not reported
//    again until it changes.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A configuration problem worth telling ourselves about.
struct ManagedLibraryDiagnostic: Equatable {

    enum Kind: String, Equatable {
        /// The MDM supplied a value that is not a usable identifier or URL —
        /// a typo, or the right value in the wrong field. The administrator can
        /// fix this themselves once told which key is wrong.
        case unusableValue
        /// The value is well-formed but names no library the app can find, even
        /// after waiting for the current registry. Either the identifier is for
        /// a different library, or that library is not in the feed we read —
        /// and those need different answers from us.
        case libraryNotFound
    }

    let kind: Kind
    /// Human-readable detail. Carries configuration keys and library
    /// identifiers only: both are values an administrator typed from a document
    /// we wrote, and neither identifies a person.
    let detail: String

    var summary: String {
        switch kind {
        case .unusableValue:  return "Managed library configuration is unusable"
        case .libraryNotFound: return "Managed library configuration names an unknown library"
        }
    }
}

enum ManagedLibraryDiagnostics {

    /// `UserDefaults` key recording the configuration value last reported, so a
    /// device that stays misconfigured reports once rather than daily.
    static let lastReportedFingerprintKey = "TPPManagedLibraryLastReportedFingerprint"

    /// Decides what, if anything, is worth reporting. Pure.
    ///
    /// - Parameters:
    ///   - decision: what the preconfigurator concluded.
    ///   - warnings: anything the parser could not use. Present only when the
    ///     administrator's payload was itself malformed.
    ///   - waitHasExpired: whether the bounded wait for the registry is over.
    ///     Before it is, an unresolved configuration is normal and not news.
    ///   - fingerprint: the current configuration value, or nil if none.
    ///   - lastReportedFingerprint: the value last reported from this device.
    static func diagnostic(
        for decision: ManagedLibraryDecision,
        warnings: [String],
        waitHasExpired: Bool,
        fingerprint: String?,
        lastReportedFingerprint: String?
    ) -> ManagedLibraryDiagnostic? {
        // Already told someone about this exact value. Saying it again every
        // launch is how a signal becomes noise.
        guard fingerprint != lastReportedFingerprint else { return nil }

        // A malformed payload is reportable immediately: no amount of waiting
        // turns a typo into a library.
        if !warnings.isEmpty {
            return ManagedLibraryDiagnostic(
                kind: .unusableValue,
                detail: warnings.joined(separator: "; ")
            )
        }

        switch decision {
        case .unresolved:
            // Two conditions, both load-bearing. The wait, because before it
            // expires this is the ordinary cold-launch state and not a fault.
            // And a value to name, because a report that cannot say WHICH
            // configuration failed is not actionable by the administrator it
            // is written for — better silent than unhelpful.
            guard waitHasExpired, let fingerprint else { return nil }
            return ManagedLibraryDiagnostic(
                kind: .libraryNotFound,
                detail: "configuration \(fingerprint) resolved to no library in the loaded registry"
            )
        case .noConfiguration, .alreadyApplied, .registryNotLoaded, .apply:
            // Nothing wrong, still working, or it worked.
            return nil
        }
    }
}

/// Where a diagnostic goes. A protocol so the decision can be tested without
/// reaching Crashlytics.
protocol ManagedLibraryDiagnosticReporting {
    func report(_ diagnostic: ManagedLibraryDiagnostic)
}

/// Production reporter: forwards to the app's error logger, which is what a
/// support engineer can actually search.
struct ManagedLibraryCrashlyticsReporter: ManagedLibraryDiagnosticReporting {
    func report(_ diagnostic: ManagedLibraryDiagnostic) {
        TPPErrorLogger.logError(
            withCode: .appLogicInconsistency,
            summary: diagnostic.summary,
            metadata: [
                "kind": diagnostic.kind.rawValue,
                "detail": diagnostic.detail
            ]
        )
    }
}

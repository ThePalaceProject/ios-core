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
    /// Human-readable detail, and the only field that leaves the device.
    ///
    /// It may carry our own configuration keys and the values an administrator
    /// typed under them, because those come from a document we wrote. It may
    /// NOT carry the managed payload itself: that dictionary belongs to the
    /// school's MDM and may hold unrelated settings today and sensitive ones
    /// tomorrow. An earlier version of this file embedded the whole payload
    /// here while this very comment claimed it did not — which is why the
    /// reportable value and the comparison value are now separate parameters
    /// with separate names, rather than one value and a promise.
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
    /// - Parameters:
    ///   - configuredValue: the library identifier or catalog URL the
    ///     administrator asked for. Reportable: it is a value typed under one
    ///     of OUR keys, from a document we wrote.
    ///   - identity: an opaque digest of the whole managed payload, used only
    ///     to tell one configuration from another. NOT reportable, and never
    ///     placed in `detail` — see `ManagedAppConfiguration.configurationIdentity`.
    static func diagnostic(
        for decision: ManagedLibraryDecision,
        warnings: [String],
        waitHasExpired: Bool,
        configuredValue: String?,
        identity: String?,
        lastReportedIdentity: String?
    ) -> ManagedLibraryDiagnostic? {
        // Already told someone about this exact configuration. Saying it again
        // every launch is how a signal becomes noise.
        guard identity != lastReportedIdentity else { return nil }

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
            // library failed is not actionable by the administrator it is
            // written for — better silent than unhelpful.
            //
            // The value named is the one the administrator asked for, not the
            // payload it arrived in.
            guard waitHasExpired, let configuredValue else { return nil }
            return ManagedLibraryDiagnostic(
                kind: .libraryNotFound,
                detail: "configured library \(configuredValue) is not in the loaded registry"
            )
        case .noConfiguration, .alreadyApplied, .registryNotLoaded, .apply:
            // Nothing wrong, still working, or it worked.
            return nil
        }
    }
}

extension ManagedLibraryDiagnostics {

    /// Reports a configuration problem at most once per configuration VALUE,
    /// and records that it did.
    ///
    /// This is a function rather than two lines at the call site because of the
    /// order: the record is written ONLY when something was actually reported.
    /// Writing it on every evaluation would mark a value as already-spoken-for
    /// during the pre-expiry window where the answer is deliberately nil, and
    /// the fault would then never be reported at all — a silent failure of the
    /// whole mechanism, on the launch where it matters most.
    ///
    /// The record is keyed on the RAW payload, not the parsed configuration,
    /// so a payload too malformed to parse still reports exactly once. See
    /// `ManagedAppConfiguration.configurationIdentity(managedDictionary:)`.
    @discardableResult
    static func reportIfNeeded(
        decision: ManagedLibraryDecision,
        waitHasExpired: Bool,
        defaults: UserDefaults,
        reporter: any ManagedLibraryDiagnosticReporting
    ) -> ManagedLibraryDiagnostic? {
        let parse = ManagedAppConfiguration.parse(defaults: defaults)
        let identity = ManagedAppConfiguration.configurationIdentity(defaults: defaults)
        // Reportable by construction: whatever the administrator put under our
        // own keys, never the payload that carried it.
        let configuredValue = parse.configuration.flatMap {
            $0.libraryId ?? $0.catalogURL?.absoluteString
        }

        guard let diagnostic = diagnostic(
            for: decision,
            warnings: parse.warnings,
            waitHasExpired: waitHasExpired,
            configuredValue: configuredValue,
            identity: identity,
            lastReportedIdentity: defaults.string(forKey: lastReportedFingerprintKey)
        ) else { return nil }

        reporter.report(diagnostic)
        defaults.set(identity, forKey: lastReportedFingerprintKey)
        return diagnostic
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

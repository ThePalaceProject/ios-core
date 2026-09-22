//
//  ManagedLibraryDebugOverride.swift
//  Palace
//
//  PP-5070 — lets the Testing screen stand in for an MDM.
//
//  ## Why this writes the REAL key
//
//  The obvious shortcut is a separate debug key that the preconfigurator also
//  consults. That would be worse than useless: it would exercise a branch
//  production never takes, and leave the one path that matters — reading a
//  dictionary out of `com.apple.configuration.managed` — untested on a device.
//  So this writes the SAME key an MDM writes, and everything downstream (parse,
//  normalize, decide, resolve, apply, bounded wait) is the production path
//  byte-for-byte. The only thing simulated is WHO wrote the dictionary, which is
//  the one part no amount of app-side code can test anyway.
//
//  ## Why this is not `#if DEBUG`
//
//  It is gated by the Testing screen's `showEngineeringTools`, which is true on
//  DEBUG, simulator AND TestFlight. `#if DEBUG` would compile it out of exactly
//  the build QA uses to exercise this on real hardware.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Writes and clears a stand-in Managed App Configuration for testing.
///
/// Every method is scoped to the one `UserDefaults` key an MDM owns, plus a
/// marker recording that we were the author.
enum ManagedLibraryDebugOverride {

    /// Set when this type writes the managed dictionary, so `clear()` can refuse
    /// to delete a configuration a real MDM supplied.
    ///
    /// On a genuinely managed device iOS owns `com.apple.configuration.managed`,
    /// and we cannot tell from the dictionary alone who wrote it. Deleting a
    /// real one during a test would silently un-configure a school's device, so
    /// the marker is the difference between "mine to remove" and "not mine".
    static let debugAuthoredMarkerKey = "TPPManagedLibraryConfigurationWasDebugAuthored"

    /// Where the configuration came from, as far as the app can tell.
    enum Provenance: Equatable {
        /// No dictionary under the managed key.
        case absent
        /// Written by this type, so safe to clear.
        case debugAuthored
        /// Present with no marker — assume a real MDM wrote it and leave it be.
        case external
    }

    static func provenance(defaults: UserDefaults) -> Provenance {
        guard defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey) != nil else {
            return .absent
        }
        return defaults.bool(forKey: debugAuthoredMarkerKey) ? .debugAuthored : .external
    }

    /// Result of a write attempt, so the caller can report it rather than guess.
    enum WriteOutcome: Equatable {
        /// The raw text parsed to neither an identifier nor an https catalog URL.
        case rejected(reason: String)
        /// Written, and the value the preconfigurator will now see. `warnings`
        /// carries anything that was dropped on the way — a list shortened in
        /// silence is how a device ends up missing a library with nothing to
        /// show for it.
        case written(ManagedLibraryPreconfiguration, warnings: [String])
        /// A real MDM already supplied a configuration; we did not overwrite it.
        case refusedExternal
    }

    /// Writes `raw` as if an MDM had pushed it.
    ///
    /// Accepts exactly what the published specification accepts — a registry
    /// identifier in any of its spellings, or an `https` catalog URL — because
    /// the point of the screen is to try what an administrator will type. A
    /// value this rejects is a value the MDM payload would also reject, which
    /// makes the rejection the useful answer rather than a failure of the tool.
    @discardableResult
    static func write(raw: String, defaults: UserDefaults) -> WriteOutcome {
        if provenance(defaults: defaults) == .external {
            return .refusedExternal
        }

        let entries = splitEntries(raw)
        guard let first = entries.first else {
            return .rejected(reason: "Enter a registry identifier or an https catalog URL.")
        }

        let selectorKey = first.lowercased().hasPrefix("http")
            ? ManagedAppConfiguration.Key.libraryCatalogURL
            : ManagedAppConfiguration.Key.libraryId
        var payload: [String: Any] = [selectorKey: first]
        let rest = Array(entries.dropFirst())
        if !rest.isEmpty {
            payload[ManagedAppConfiguration.Key.additionalLibraryIds] = rest
        }

        let parse = ManagedAppConfiguration.parse(managedDictionary: payload)
        guard let parsed = parse.configuration else {
            // Prefer the parser's own warning: it names which value it could not
            // use, which matters once more than one was supplied.
            return .rejected(
                reason: parse.warnings.first
                    ?? (selectorKey == ManagedAppConfiguration.Key.libraryId
                        ? "Not a UUID. An MDM payload would reject this too."
                        : "Not an https URL. An MDM payload would reject this too.")
            )
        }

        defaults.set(payload, forKey: ManagedAppConfiguration.userDefaultsKey)
        defaults.set(true, forKey: debugAuthoredMarkerKey)
        Log.info(#file, "Debug-authored managed configuration written: \(parsed.fingerprint)")
        return .written(parsed, warnings: parse.warnings)
    }

    /// Splits typed input into entries on commas, newlines or spaces.
    ///
    /// The FIRST entry is the library to select and the rest are added, which
    /// mirrors the payload shape exactly: `defaultLibraryId` plus
    /// `additionalLibraryIds`. Order carries meaning here — unlike in the MDM
    /// payload, where the two roles get their own keys — because a single text
    /// field has nowhere else to put it, and the row's own label says so.
    static func splitEntries(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Removes a debug-authored configuration. Leaves an externally supplied one
    /// alone and says so.
    @discardableResult
    static func clear(defaults: UserDefaults) -> Bool {
        guard provenance(defaults: defaults) != .external else { return false }
        defaults.removeObject(forKey: ManagedAppConfiguration.userDefaultsKey)
        defaults.removeObject(forKey: debugAuthoredMarkerKey)
        return true
    }

    /// Forgets that any configuration was already applied, so the next attempt
    /// re-applies instead of reporting `.alreadyApplied`.
    ///
    /// This is the affordance that makes the screen usable more than once.
    /// Without it, the apply-once-per-value rule means the second test of a
    /// given identifier can only be run by deleting and reinstalling the app —
    /// which is precisely the round trip a Testing screen exists to avoid.
    static func forgetAppliedFingerprint(defaults: UserDefaults) {
        defaults.removeObject(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey)
    }

    /// One-line human summary of what the app currently sees, for the read-out.
    static func statusDescription(preconfigurator: ManagedLibraryPreconfigurator,
                                  defaults: UserDefaults) -> String {
        let source: String
        switch provenance(defaults: defaults) {
        case .absent:       source = "none"
        case .debugAuthored: source = "set here"
        case .external:     source = "set by MDM"
        }
        return "\(source) · \(describe(preconfigurator.inspect()))"
    }

    /// Plain-language rendering of a decision. Says what the app will DO, not
    /// which enum case it picked.
    static func describe(_ decision: ManagedLibraryDecision) -> String {
        switch decision {
        case .noConfiguration:
            return "nothing configured"
        case .alreadyApplied:
            return "already applied — use Forget to re-test"
        case .registryNotLoaded:
            return "waiting for the library registry"
        case .unresolved:
            return "not found in the loaded registry"
        case .apply(let uuid):
            return "will select \(uuid)"
        }
    }
}

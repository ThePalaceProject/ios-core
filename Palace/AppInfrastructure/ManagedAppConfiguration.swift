//
//  ManagedAppConfiguration.swift
//  Palace
//
//  PP-5070 spike — read a library pre-selection out of Apple's Managed App
//  Configuration so an MDM can point a managed install at the right library
//  before the student ever opens Settings.
//
//  MDM writes its configuration dictionary into the app's own NSUserDefaults
//  under `com.apple.configuration.managed` at install time. There is no SDK,
//  no entitlement and no Info.plist key involved — reading that one key is the
//  whole channel. The dictionary is REPLACED wholesale whenever the MDM pushes
//  a new configuration, and is absent entirely on an unmanaged install.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import CryptoKit

/// The library pre-selection an MDM asked for, in canonical form.
///
/// A configuration ALWAYS names a library to select — `libraryId` or
/// `catalogURL`. `additionalLibraryIds` are added to the user's library list
/// without changing which one is current; a payload carrying only those is
/// incomplete and parses to nil, so callers never have to distinguish "empty
/// configuration" from "no configuration".
struct ManagedLibraryPreconfiguration: Equatable {
    /// Registry identifier of the library to SELECT, in the canonical
    /// `urn:uuid:<lowercase>` form that `Account.uuid` uses. Nil when the MDM
    /// supplied no identifier, or supplied one that is not a UUID.
    let libraryId: String?

    /// Catalog root URL of the library to SELECT, as supplied and parsed. Nil
    /// when the MDM supplied none, or supplied something that is not an `https`
    /// URL.
    let catalogURL: URL?

    /// Further libraries to ADD without selecting, canonicalized and
    /// de-duplicated, in the order the administrator listed them.
    ///
    /// Deliberately a separate key from `libraryId` rather than "a list whose
    /// first entry wins": positional meaning in a hand-typed plist is a trap,
    /// where swapping two lines silently changes which catalog a student lands
    /// in. Each key has one job.
    let additionalLibraryIds: [String]

    init(libraryId: String?, catalogURL: URL?, additionalLibraryIds: [String] = []) {
        self.libraryId = libraryId
        self.catalogURL = catalogURL
        self.additionalLibraryIds = additionalLibraryIds
    }

    /// Stable identity of this configuration VALUE, used for the apply-once
    /// bookkeeping. Two pushes with the same meaning fingerprint identically;
    /// changing ANY field changes the fingerprint, which is what lets an
    /// administrator re-point a device that has already been configured — and
    /// what makes adding a library to the list re-apply rather than sit inert.
    var fingerprint: String {
        "id=\(libraryId ?? "")|url=\(catalogURL?.absoluteString ?? "")"
            + "|add=\(additionalLibraryIds.joined(separator: ","))"
    }
}

/// What a parse made of the payload: the usable configuration, plus anything
/// the administrator wrote that could not be used.
///
/// The warnings exist because the failure they describe is otherwise silent. An
/// array under `defaultLibraryId` does not throw and does not configure — it
/// reads as an absent key, so a payload that looks right to whoever typed it
/// does nothing at all and says nothing about why.
struct ManagedLibraryParse: Equatable {
    let configuration: ManagedLibraryPreconfiguration?
    let warnings: [String]

    static let none = ManagedLibraryParse(configuration: nil, warnings: [])
}

/// Reader for Apple Managed App Configuration.
///
/// Every member is pure or reads one injected `UserDefaults`, so the whole
/// parse surface is unit-testable without an MDM.
enum ManagedAppConfiguration {

    /// The `UserDefaults` key Apple reserves for MDM-supplied configuration.
    static let userDefaultsKey = "com.apple.configuration.managed"

    /// Keys an administrator types into their MDM. Deliberately legible rather
    /// than namespaced: these appear in a configuration document a school IT
    /// administrator fills in by hand, and a mistyped key fails silently.
    enum Key {
        /// Registry identifier of the library to pre-select. Accepted with or
        /// without the `urn:uuid:` prefix, in any case.
        static let libraryId = "defaultLibraryId"
        /// Catalog root URL of the library to pre-select. Used when no
        /// identifier is supplied, and as a cross-check when one is.
        static let libraryCatalogURL = "defaultLibraryCatalogUrl"
        /// Further registry identifiers to ADD without selecting. An array of
        /// strings; a single string is accepted too, since an administrator
        /// adding one extra library will reasonably write one.
        static let additionalLibraryIds = "additionalLibraryIds"
    }

    /// Reads and normalizes the library pre-selection, if any.
    ///
    /// Returns nil when the app is unmanaged, when the MDM sent a dictionary
    /// with neither key, or when both supplied values were unusable — all of
    /// which mean the same thing to a caller: nothing to apply.
    static func libraryPreconfiguration(defaults: UserDefaults) -> ManagedLibraryPreconfiguration? {
        parse(defaults: defaults).configuration
    }

    /// Full parse from `UserDefaults`, including unusable values.
    static func parse(defaults: UserDefaults) -> ManagedLibraryParse {
        guard let managed = defaults.dictionary(forKey: userDefaultsKey) else { return .none }
        return parse(managedDictionary: managed)
    }

    /// Splits an administrator's typed list into entries on commas, newlines or
    /// spaces.
    ///
    /// Deliberately generous about separators and not at all generous about
    /// content: a value that is not a UUID after splitting is still dropped and
    /// still reported. Trading a visible failure for an invisible one would be
    /// the wrong direction, and the point here is only that "a, b" and "a\nb"
    /// are things people type into a single text box.
    ///
    /// Applied to `additionalLibraryIds` and never to `defaultLibraryId`, which
    /// is singular: splitting that one would mean quietly picking one of two
    /// libraries an administrator named, which is worse than refusing.
    ///
    /// The Testing screen splits typed input the same way through this function,
    /// so an engineer reproducing a school's report parses it as the school
    /// sent it.
    static func splitEntries(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A stable, NON-REVERSIBLE identity for what the administrator wrote,
    /// covering the whole managed payload including keys we do not understand.
    ///
    /// ## This is for comparing, never for reporting
    ///
    /// The distinction is the whole point, and getting it wrong is not
    /// hypothetical — an earlier version of this returned the payload itself,
    /// and the diagnostics path embedded that in a Crashlytics report. The
    /// managed dictionary belongs to the school's MDM, not to us: it may carry
    /// unrelated settings today and sensitive ones tomorrow, and neither is
    /// ours to send anywhere.
    ///
    /// So the content never leaves this function. What comes out is a digest:
    /// enough to answer "is this the same configuration as last time?" and
    /// useless for anything else. A caller that wants something a human can
    /// read must build it from `ManagedLibraryPreconfiguration`, whose values
    /// are ours by construction.
    ///
    /// Covers every key rather than only ours, because the question it answers
    /// is "did the administrator change anything?" — and a change under a key
    /// we do not parse today is still a change, still worth re-evaluating, and
    /// still worth reporting separately from the previous attempt.
    ///
    /// Keys are sorted before hashing because `[String: Any]` has no order, and
    /// an unordered digest would change between launches on its own.
    static func configurationIdentity(managedDictionary: [String: Any]) -> String? {
        guard !managedDictionary.isEmpty else { return nil }
        let canonical = managedDictionary.keys.sorted()
            .map { "\($0)=\(String(describing: managedDictionary[$0] ?? ""))" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// `configurationIdentity(managedDictionary:)` read from `UserDefaults`.
    /// Nil when the app is unmanaged — there is nothing to compare.
    static func configurationIdentity(defaults: UserDefaults) -> String? {
        guard let managed = defaults.dictionary(forKey: userDefaultsKey) else { return nil }
        return configurationIdentity(managedDictionary: managed)
    }

    /// Pure form of `libraryPreconfiguration(defaults:)`.
    static func libraryPreconfiguration(managedDictionary: [String: Any]) -> ManagedLibraryPreconfiguration? {
        parse(managedDictionary: managedDictionary).configuration
    }

    /// Full parse, including what could not be used.
    static func parse(managedDictionary: [String: Any]) -> ManagedLibraryParse {
        var warnings: [String] = []

        let id = canonicalSelector(
            managedDictionary[Key.libraryId], key: Key.libraryId, warnings: &warnings
        )
        let url = normalizedSelectorURL(
            managedDictionary[Key.libraryCatalogURL], key: Key.libraryCatalogURL, warnings: &warnings
        )
        var additional = canonicalAdditionalIds(
            managedDictionary[Key.additionalLibraryIds], warnings: &warnings
        )

        // The selected library is already accounted for; listing it again in
        // the additions is harmless and common, so absorb it rather than
        // reporting it.
        if let id { additional.removeAll { $0 == id } }

        guard id != nil || url != nil else {
            if !additional.isEmpty {
                warnings.append(
                    "'\(Key.additionalLibraryIds)' names libraries to add but no library to select — "
                    + "add '\(Key.libraryId)'. Nothing was configured."
                )
            }
            return ManagedLibraryParse(configuration: nil, warnings: warnings)
        }

        return ManagedLibraryParse(
            configuration: ManagedLibraryPreconfiguration(
                libraryId: id, catalogURL: url, additionalLibraryIds: additional
            ),
            warnings: warnings
        )
    }

    /// Reads a selector identifier, reporting a present-but-unusable value
    /// rather than letting it read as an absent key.
    private static func canonicalSelector(
        _ raw: Any?, key: String, warnings: inout [String]
    ) -> String? {
        guard let raw else { return nil }
        guard let text = raw as? String else {
            warnings.append(
                "'\(key)' must be a single string. Several libraries go in "
                + "'\(Key.additionalLibraryIds)'."
            )
            return nil
        }
        guard let canonical = canonicalLibraryId(text) else {
            warnings.append("'\(key)' is not a UUID: \(text)")
            return nil
        }
        return canonical
    }

    /// Reads the catalog-URL selector, reporting unusable values.
    private static func normalizedSelectorURL(
        _ raw: Any?, key: String, warnings: inout [String]
    ) -> URL? {
        guard let raw else { return nil }
        guard let text = raw as? String else {
            warnings.append("'\(key)' must be a single string.")
            return nil
        }
        guard let url = normalizedCatalogURL(text) else {
            warnings.append("'\(key)' is not an https URL: \(text)")
            return nil
        }
        return url
    }

    /// Reads the add-without-selecting list. Accepts an array of strings, or a
    /// lone string, and reports every entry it had to drop — a silently
    /// shortened list is how a device ends up missing one division's library
    /// with nothing to show for it.
    private static func canonicalAdditionalIds(
        _ raw: Any?, warnings: inout [String]
    ) -> [String] {
        guard let raw else { return [] }

        let entries: [String]
        switch raw {
        case let list as [String]:
            entries = list
        case let single as String:
            // A single string is not necessarily a single library. An MDM whose
            // admin UI takes a plist sends an array, as documented — but one
            // with a plain text box sends whatever the administrator typed, as
            // one string. Treating that as one identifier failed the UUID check
            // and dropped EVERY extra library: a school that configured three
            // divisions would have got one, with the rest visible only in a
            // warning nobody had asked to read.
            entries = splitEntries(single)
        default:
            warnings.append(
                "'\(Key.additionalLibraryIds)' must be an array of strings."
            )
            return []
        }

        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            guard let canonical = canonicalLibraryId(entry) else {
                warnings.append("'\(Key.additionalLibraryIds)' entry is not a UUID: \(entry)")
                continue
            }
            if seen.insert(canonical).inserted { result.append(canonical) }
        }
        return result
    }

    /// Normalizes an administrator-typed registry identifier to the
    /// `urn:uuid:<lowercase>` form `Account.uuid` carries.
    ///
    /// A registry UUID is the single value in this feature most likely to be
    /// pasted wrong, so all four plausible spellings are accepted: bare or
    /// `urn:uuid:`-prefixed, upper or lower case, with surrounding whitespace.
    /// Anything that is not a UUID is rejected rather than passed through —
    /// a bad identifier must read as "no configuration", never as a library
    /// nothing can resolve.
    static func canonicalLibraryId(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "urn:uuid:"
        if value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let uuid = UUID(uuidString: value) else { return nil }
        return prefix + uuid.uuidString.lowercased()
    }

    /// Parses an administrator-typed catalog URL.
    ///
    /// `https` is required: this URL becomes the feed the app fetches, and an
    /// MDM payload is not a place to accept a downgrade to cleartext.
    static func normalizedCatalogURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }

    /// True when `candidate` (a registry `Account.catalogUrl`) addresses the
    /// same catalog as `configured`.
    ///
    /// Host is compared case-insensitively and trailing slashes are ignored,
    /// because `https://host/00351977/` and `https://host/00351977` are the
    /// same catalog and an administrator will type either. Scheme is NOT
    /// compared — the configured value is already known to be `https`, and a
    /// registry entry served over `http` still names the same catalog.
    static func catalogURL(_ candidate: String?, matches configured: URL) -> Bool {
        guard let candidate,
              let candidateURL = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)),
              let candidateHost = candidateURL.host?.lowercased(),
              let configuredHost = configured.host?.lowercased()
        else { return false }
        return candidateHost == configuredHost
            && trimmingTrailingSlashes(candidateURL.path) == trimmingTrailingSlashes(configured.path)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

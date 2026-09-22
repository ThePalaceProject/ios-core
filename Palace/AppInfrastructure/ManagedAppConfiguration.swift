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

/// The library pre-selection an MDM asked for, in canonical form.
///
/// Either field may be nil, but a configuration with BOTH nil does not exist —
/// `ManagedAppConfiguration.libraryPreconfiguration` returns nil instead, so
/// callers never have to distinguish "empty configuration" from "no
/// configuration".
struct ManagedLibraryPreconfiguration: Equatable {
    /// Registry identifier in the canonical `urn:uuid:<lowercase>` form that
    /// `Account.uuid` uses. Nil when the MDM supplied no identifier, or
    /// supplied one that is not a UUID.
    let libraryId: String?

    /// Catalog root URL as supplied, parsed. Nil when the MDM supplied none,
    /// or supplied something that is not an `https` URL.
    let catalogURL: URL?

    /// Stable identity of this configuration VALUE, used for the apply-once
    /// bookkeeping. Two pushes with the same meaning fingerprint identically;
    /// changing either field changes the fingerprint, which is what lets an
    /// administrator re-point a device that has already been configured.
    var fingerprint: String {
        "id=\(libraryId ?? "")|url=\(catalogURL?.absoluteString ?? "")"
    }
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
    }

    /// Reads and normalizes the library pre-selection, if any.
    ///
    /// Returns nil when the app is unmanaged, when the MDM sent a dictionary
    /// with neither key, or when both supplied values were unusable — all of
    /// which mean the same thing to a caller: nothing to apply.
    static func libraryPreconfiguration(defaults: UserDefaults) -> ManagedLibraryPreconfiguration? {
        guard let managed = defaults.dictionary(forKey: userDefaultsKey) else { return nil }
        return libraryPreconfiguration(managedDictionary: managed)
    }

    /// Pure form of `libraryPreconfiguration(defaults:)`.
    static func libraryPreconfiguration(managedDictionary: [String: Any]) -> ManagedLibraryPreconfiguration? {
        let id = (managedDictionary[Key.libraryId] as? String).flatMap(canonicalLibraryId)
        let url = (managedDictionary[Key.libraryCatalogURL] as? String).flatMap(normalizedCatalogURL)
        guard id != nil || url != nil else { return nil }
        return ManagedLibraryPreconfiguration(libraryId: id, catalogURL: url)
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

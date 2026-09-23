//
//  ManagedLibraryTestingGuide.swift
//  Palace
//
//  PP-5070 — the in-app explanation of what the Testing screen's MDM row does
//  and what an administrator would type to get the same result.
//
//  ## Why the example is a dictionary and not a string
//
//  `exampleConfiguration` is the value the PARSER reads; `examplePayloadXML` is
//  that same value rendered for display. They cannot disagree, because one is
//  generated from the other. A guide whose example has quietly stopped being
//  valid is worse than no guide — someone copies it into an MDM, nothing
//  happens, and the app looks broken rather than the document being stale.
//  `ManagedLibraryTestingGuideTests` parses this example and fails if it ever
//  stops producing a usable configuration.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

enum ManagedLibraryTestingGuide {

    struct Section: Identifiable {
        let id: String
        let title: String
        let paragraphs: [String]

        init(_ title: String, _ paragraphs: [String]) {
            self.id = title
            self.title = title
            self.paragraphs = paragraphs
        }
    }

    /// Placeholder identifiers. Deliberately not a real partner's libraries:
    /// this string ships in the app binary, and a library's registry identifier
    /// belongs in the configuration document we hand an administrator, not
    /// baked into a build.
    static let placeholderSelected = "urn:uuid:00000000-1111-2222-3333-444444444444"
    static let placeholderAdditional = "urn:uuid:55555555-6666-7777-8888-999999999999"

    /// The example configuration, in the shape the app actually reads.
    ///
    /// Computed rather than a stored `static let`: `[String: Any]` is not
    /// `Sendable`, so a stored one is a concurrency error under Swift 6. Built
    /// fresh per access, it has no shared state to race over.
    static var exampleConfiguration: [String: Any] {
        [
            ManagedAppConfiguration.Key.libraryId: placeholderSelected,
            ManagedAppConfiguration.Key.additionalLibraryIds: [placeholderAdditional]
        ]
    }

    /// The same configuration rendered as the plist an MDM takes, generated
    /// from `exampleConfiguration` so the two cannot drift apart.
    static var examplePayloadXML: String {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: exampleConfiguration, format: .xml, options: 0
        ), let xml = String(data: data, encoding: .utf8) else {
            // Unreachable for a dictionary of strings and string arrays; the
            // fallback keeps the guide readable rather than blank if it ever is.
            return "<dict>\n  <key>\(ManagedAppConfiguration.Key.libraryId)</key>\n"
                + "  <string>\(placeholderSelected)</string>\n</dict>"
        }
        return xml
    }

    static var sections: [Section] {
        [
            Section("What this does", [
                "An MDM can tell a managed install which library to use before anyone opens the app. The device arrives already pointed at the right catalog, so a student never meets the library picker.",
                "This screen stands in for the MDM. It writes the same UserDefaults key an MDM writes — com.apple.configuration.managed — so everything downstream is the real path, not a test-only shortcut."
            ]),
            Section("What the administrator types", [
                "\(ManagedAppConfiguration.Key.libraryId) — the registry identifier of the library to SELECT. Accepted with or without the urn:uuid: prefix, in any case, with surrounding whitespace.",
                "\(ManagedAppConfiguration.Key.libraryCatalogURL) — an https catalog root URL, as an alternative to the identifier.",
                "\(ManagedAppConfiguration.Key.additionalLibraryIds) — further identifiers to ADD without selecting. An array, or a single string.",
                "A value that is not a UUID is refused rather than stored, so a typo reads as 'nothing configured' instead of as a library nothing can resolve. Find a library's identifier in the Palace registry feed."
            ]),
            Section("Example", [
                examplePayloadXML,
                "Replace the identifiers with the real ones. Three device groups with a different \(ManagedAppConfiguration.Key.libraryId) in each is how one app serves three divisions of a school."
            ]),
            Section("Using this screen", [
                "Type one identifier, or several separated by commas, spaces or new lines — the FIRST is selected and the rest are added.",
                "Apply runs the real pre-selection immediately and reports what it decided. Relaunching the app instead exercises the cold-start ordering, where the built-in library snapshot loads before the network one.",
                "Forget clears the record of what was already applied, so the same value can be applied again. Without it a second Apply reports 'already applied', because the app deliberately applies each configuration value only once.",
                "Clear removes a configuration this screen wrote. It will not touch one a real MDM supplied."
            ]),
            Section("Rules worth knowing", [
                "A configuration applies once per VALUE. An app update does not re-apply it; a student who removes the library is not overruled; a changed value re-points the device; a reinstalled device applies it again.",
                "If the library to select is not in the registry the app has loaded, the app waits briefly for the network registry rather than showing the picker, then gives up and shows it. On a first launch the built-in snapshot can be months old and may not contain a recently added library.",
                "An additional library that cannot be found is skipped and the selection still happens. The library to SELECT not being found configures nothing at all."
            ])
        ]
    }
}

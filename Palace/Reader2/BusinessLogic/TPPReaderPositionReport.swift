//
//  TPPReaderPositionReport.swift
//  The Palace Project
//
//  Pure composer for the DAISY nav-310 "Where am I?" position announcement
//  (PP-4527). Assembles a spoken VoiceOver string from the patron's current
//  section, print page, and percentage read — omitting any component that is
//  unavailable so a title with no page-list still reports section + percentage
//  without erroring.
//

import Foundation

/// Builds the spoken "Where am I?" position report.
///
/// The report concatenates, in reading-order of usefulness, the components that
/// are available for the current position: section, print page, percentage read.
/// Components that are nil or blank are dropped; when nothing is available the
/// fallback "current position unavailable" string is returned (never an error).
enum TPPReaderPositionReport {

    /// Compose the position announcement.
    ///
    /// - Parameters:
    ///   - section: the current section/chapter title, or nil/blank when unknown.
    ///   - pageLabel: the current print page label, or nil when the title has no
    ///     page-list or no preceding page boundary.
    ///   - totalProgression: book progress in `0...1`, or nil when unavailable.
    ///     Rendered as a whole-percent value clamped to `0...100`.
    static func announcement(section: String?, pageLabel: String?, totalProgression: Double?) -> String {
        var parts: [String] = []

        if let section = section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty {
            parts.append(section)
        }

        if let pageLabel = pageLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !pageLabel.isEmpty {
            parts.append(String(format: Strings.TPPBaseReaderViewController.navigatedToPage, pageLabel))
        }

        if let totalProgression {
            let clamped = min(max(totalProgression, 0), 1)
            let percent = Int((clamped * 100).rounded())
            parts.append(String(format: Strings.TPPBaseReaderViewController.percentRead, percent))
        }

        guard !parts.isEmpty else {
            return Strings.TPPBaseReaderViewController.positionUnavailable
        }

        return parts.joined(separator: ", ")
    }
}

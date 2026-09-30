//
//  LogArchiveExporting.swift
//  PalaceLogging
//
//  The dev-tools log email reads the archive through this seam rather than a
//  concrete logger, so the audiobook file logger can move without touching
//  Settings, and the export is testable.
//

import Foundation

public protocol LogArchiveExporting: Sendable {
    /// Directory containing the exportable log files, or nil when none exists.
    func logArchiveDirectoryURL() -> URL?
}

//
//  LogArchiveExporting.swift
//  PalaceLogging
//
//  Wave 1c (god-class decomposition, cycle 6 follow-through): the dev-tools
//  log-email consumes this seam instead of a concrete logger type, so the
//  audiobook file logger can relocate into the audiobook stack (Wave 6)
//  without touching Settings. NOTE: the plan's original premise (Settings
//  imported audiobook types for this path) was already dissolved when
//  AudiobookFileLogger moved to Palace/Logging/ — this protocol is seam prep
//  + testability, not a cycle kill.
//

import Foundation

public protocol LogArchiveExporting: Sendable {
    /// Directory containing the exportable log files, or nil when none exists.
    func logArchiveDirectoryURL() -> URL?
}

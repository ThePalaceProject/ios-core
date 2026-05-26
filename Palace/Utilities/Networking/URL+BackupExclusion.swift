//
//  URL+BackupExclusion.swift
//  The Palace Project
//
//  Sets `isExcludedFromBackup = true` so files written by Palace do not
//  replicate into the patron's iCloud quota. Required by Apple for
//  re-downloadable content (HelpSpot 17517 / PP-4179: patron reported
//  1.2 GB iCloud backup footprint from accumulated borrows).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

extension URL {
    /// Sets `isExcludedFromBackup = true` on the receiver. No-op if the
    /// path does not exist. Logs and returns false if the file system
    /// rejects the resource-value write (e.g. a read-only mount).
    @discardableResult
    func excludeFromBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var mutableURL = self
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try mutableURL.setResourceValues(resourceValues)
            return true
        } catch {
            Log.error(#file, "Failed to set isExcludedFromBackup on \(path): \(error.localizedDescription)")
            return false
        }
    }
}

//
//  URL+RegistryBackupExclusion.swift
//  PalaceBookRegistry
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

extension URL {
    /// Sets `isExcludedFromBackup = true` on the receiver so the registry files the
    /// engine writes don't replicate into the patron's iCloud quota (PP-4179).
    ///
    /// Package-INTERNAL twin of the app-target `URL.excludeFromBackup()` (in
    /// `URL+BackupExclusion.swift`, used by ~12 app sites + its own tests). The app
    /// extension can't cross into the package and duplicating its public name would
    /// collide cross-module, so this carries a distinct name with byte-identical
    /// behavior. No-op if the path does not exist; logs + returns false on failure.
    @discardableResult
    func registryExcludeFromBackup() -> Bool {
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

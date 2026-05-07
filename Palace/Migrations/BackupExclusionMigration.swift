//
//  BackupExclusionMigration.swift
//  The Palace Project
//
//  PP-4179 — one-shot upgrade pass that walks Application Support and
//  Documents on first 3.1.0 launch and flags every existing entry as
//  excluded from iCloud backup. Forward-fix at directory-creation sites
//  uses `URL.excludeFromBackup()` directly.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

enum BackupExclusionMigration {

    /// Walks Application Support and Documents for the running app, and
    /// flags every file/directory inside as excluded from iCloud backup.
    /// Used by the 3.1.0 upgrade pass.
    static func run() {
        run(directories: defaultDirectories(fileManager: .default))
    }

    /// Walks each root in `directories` and flags every entry inside.
    /// The roots themselves are also flagged.
    static func run(directories: [URL], fileManager: FileManager = .default) {
        for root in directories {
            walkAndExclude(root, fileManager: fileManager)
        }
    }

    // MARK: - Private

    private static func walkAndExclude(_ root: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        root.excludeFromBackup()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                Log.error(#file, "Enumeration error at \(url.path): \(error.localizedDescription)")
                return true
            }
        ) else { return }
        for case let url as URL in enumerator {
            url.excludeFromBackup()
        }
    }

    private static func defaultDirectories(fileManager: FileManager) -> [URL] {
        var roots: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupport)
        }
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documents)
        }
        return roots
    }
}

//
//  BackupExclusionMigration.swift
//  The Palace Project
//
//  PP-4179 — exclude downloaded books, audiobook chapters, logs, network
//  queue, and accounts state from iCloud backup so the app does not
//  replicate re-downloadable content into the patron's iCloud quota.
//
//  Two surfaces:
//    • `excludeFromBackup(_:)` / `makeDirectoryExcluded(at:)` are forward-fix
//      helpers called wherever the app creates a writable directory.
//    • `run()` is the one-shot upgrade pass: it walks Application Support
//      and Documents and flags every existing entry. Wired into the 3.1.0
//      `migrate3_1_0` block in SEMigrations.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

@objcMembers final class BackupExclusionMigration: NSObject {

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

    /// Sets `isExcludedFromBackup = true` on a single URL. Returns true on
    /// success, false if the URL does not exist or the system rejects the
    /// resource value (e.g. a non-writable mount).
    @discardableResult
    static func excludeFromBackup(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try mutableURL.setResourceValues(resourceValues)
            return true
        } catch {
            Log.error(#file, "Failed to set isExcludedFromBackup on \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Forward-fix helper for every site that creates a writable directory.
    /// Creates the directory (with intermediates) if missing, then sets the
    /// backup-exclusion flag. Returns false if the path is blocked by an
    /// existing non-directory entry.
    @discardableResult
    static func makeDirectoryExcluded(at url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue {
            Log.error(#file, "Cannot make directory: a file already exists at \(url.path)")
            return false
        }
        if !exists {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                Log.error(#file, "Failed to create directory at \(url.path): \(error.localizedDescription)")
                return false
            }
        }
        return excludeFromBackup(url)
    }

    // MARK: - Private

    private static func walkAndExclude(_ root: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        excludeFromBackup(root)
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
            excludeFromBackup(url)
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

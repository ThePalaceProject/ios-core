//
//  PerBookRegistrySession.swift
//  PalaceBookRegistry
//
//  Which account's per-book files this launch uses, and whether that account's
//  `registry.json` is behind its position files (PP-5507).
//  See docs/architecture/per-book-registry-storage.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceBookModel

/// `@unchecked Sendable`: `active` and `behind` are read and written only
/// under `lock`. The file work runs on `BookRegistrySync`'s disk-write queue.
final class PerBookRegistrySession: @unchecked Sendable {
  private let lock = NSLock()
  private var active: (account: String, files: PerBookRegistryFiles)?
  private var behind: Set<String> = []

  /// The per-book files `account` uses this launch, or nil when it uses only
  /// `registry.json`.
  func files(for account: String) -> PerBookRegistryFiles? {
    lock.withLock { active?.account == account ? active?.files : nil }
  }

  /// Stops using per-book files for `account`, or for any account when nil.
  func deactivate(account: String?) {
    lock.withLock {
      if account == nil || active?.account == account { active = nil }
    }
  }

  /// Forgets everything about a signed-out account.
  func forget(_ account: String) {
    lock.withLock {
      if active?.account == account { active = nil }
      behind.remove(account)
    }
  }

  func isSingleFileBehind(_ account: String) -> Bool {
    lock.withLock { behind.contains(account) }
  }

  /// True when an app event has to bring `account`'s `registry.json` up to
  /// date. Always false when the flag was off at load.
  func needsSingleFileWrites(for account: String) -> Bool {
    isSingleFileBehind(account)
  }

  /// Marks `registry.json` as behind before a position write is queued, so an
  /// app event that runs before the queued write still brings it up to date.
  func markSingleFileBehind(_ account: String) {
    setSingleFileBehind(true, for: account)
  }

  private func activate(_ account: String, _ files: PerBookRegistryFiles) {
    lock.withLock { active = (account, files) }
  }

  private func setSingleFileBehind(_ isBehind: Bool, for account: String) {
    lock.withLock {
      if isBehind { behind.insert(account) } else { behind.remove(account) }
    }
  }

  // MARK: - Load

  /// Decides at load which files hold `account`'s shelf and returns the
  /// records to parse. Trusted per-book files are merged over `primaryRecords`;
  /// otherwise a valid `registry.json` is moved to the per-book layout and
  /// `primaryRecords` are returned unchanged. Runs on the disk-write queue.
  func prepare(
    account: String,
    registryURL: URL,
    primaryRecords: [TPPBookRegistryData]?,
    primaryData: Data?,
    primaryIsValid: Bool,
    appVersion: String,
    beforeWrite: @escaping PerBookRegistryFiles.BeforeWrite
  ) -> [TPPBookRegistryData]? {
    let files = PerBookRegistryFiles(registryURL: registryURL, beforeWrite: beforeWrite)
    setSingleFileBehind(false, for: account)
    if files.isTrusted(primaryData: primaryData) {
      activate(account, files)
      Log.info(#file, "  Reading the shelf from per-book files")
      return files.loadTrusted(primaryRecords: primaryRecords ?? [])
    }
    deactivate(account: nil)
    guard primaryIsValid, let primaryData else {
      Log.info(#file, "  Per-book layout not used: registry.json is absent or was recovered")
      return primaryRecords
    }
    switch files.migrate(primaryRecords: primaryRecords ?? [], primaryData: primaryData, appVersion: appVersion) {
    case .migrated:
      activate(account, files)
      Log.info(#file, "  Moved the shelf to per-book files")
    case .skipped(let reason):
      Log.info(#file, "  Per-book layout not used: \(reason)")
    case .failed(let mismatched):
      Log.error(#file, "  Per-book migration failed; keeping registry.json. Books that differed: \(mismatched.joined(separator: ", "))")
    }
    return primaryRecords
  }

  // MARK: - Saves (on the disk-write queue)

  /// Brings `files` in line with a shelf save's records. Returns true when they
  /// now match. On an error the account stops using per-book files for this
  /// launch, so later positions go to `registry.json`.
  func writeShelf(_ files: PerBookRegistryFiles?, records: Any?, account: String) -> Bool {
    guard let files else { return false }
    do {
      try files.write(shelf: records as? [TPPBookRegistryData] ?? [])
      return true
    } catch {
      Log.error(#file, "Per-book registry write failed; using registry.json for this launch: \(error.localizedDescription)")
      deactivate(account: account)
      return false
    }
  }

  /// After `registry.json` was written: it is no longer behind, and when
  /// `files` were written with it, they are recorded as matching these bytes.
  func singleFileWritten(account: String, registryData: Data, files: PerBookRegistryFiles?, appVersion: String) {
    setSingleFileBehind(false, for: account)
    guard let files else { return }
    do {
      try files.recordTrust(registryData: registryData, appVersion: appVersion)
    } catch {
      // Without the trust record the next launch reads registry.json, so later
      // positions must go there too.
      Log.error(#file, "Per-book trust record not written; using registry.json for this launch: \(error.localizedDescription)")
      deactivate(account: account)
    }
  }

  /// Writes position files. When a write fails, or the account stopped using
  /// the files after this save was queued, the position stays in memory and
  /// `registry.json` stays marked as behind until an app event or the next
  /// save writes it.
  func writePositions(_ positions: [(identifier: String, location: [String: Any]?)], files: PerBookRegistryFiles, account: String) {
    setSingleFileBehind(true, for: account)
    guard self.files(for: account) === files else { return }
    do {
      for position in positions {
        try files.writePosition(identifier: position.identifier, location: position.location)
      }
    } catch {
      Log.error(#file, "Per-book position write failed; using registry.json for this launch: \(error.localizedDescription)")
      deactivate(account: account)
    }
  }
}

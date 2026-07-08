//
//  RegistryFileRecovery.swift
//  Palace
//
//  Reliability initiative — Workstream B (Registry Resilience).
//
//  Pure classification + on-disk quarantine/backup helpers for the book
//  registry file. Extracted so the corrupt/empty/valid decision is a
//  side-effect-free function that can be unit- and mutation-tested without
//  standing up the full `BookRegistrySync` disk pipeline.
//
//  The shelf (`TPPBookRegistry`) is the source of truth for a patron's books.
//  A single truncated write or OS-level corruption of `registry.json` must
//  NEVER cause the shelf to be silently zeroed and then overwritten with an
//  empty-but-valid file. This helper encodes the "never destroy, always
//  quarantine, prefer last-good backup" policy behind INV-1.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Stateless registry-file recovery policy. All members are `static` and pure
/// over their inputs (`Data`, `URL`) except the explicitly-named I/O helpers
/// (`quarantine`, `writeBackup`), which perform copy/rename filesystem work and
/// are documented as such.
enum RegistryFileRecovery {

  /// Current on-disk schema version. Version 1 == the historical shape
  /// (`{ "records": [ … ] }`); v1 files additionally carry `schemaVersion: 1`.
  /// Old files written before this field existed are "unversioned" and are
  /// treated as v1 on load, then migrated (gain the field) on the next save.
  static let currentSchemaVersion = 1

  /// The JSON key under which the schema version is persisted. Defined here
  /// (not on `TPPBookRegistryKey`, which lives in a file this workstream does
  /// not own) so the change is fully contained to WS-B's files.
  static let schemaVersionKey = "schemaVersion"

  /// The result of classifying the bytes of a registry file.
  ///
  /// - `valid`: parseable object carrying a `records` array (possibly empty —
  ///   an authoritatively-empty shelf is still valid).
  /// - `corrupt`: bytes are present but are not a JSON object, or are a JSON
  ///   object missing the `records` array (truncated / wrong shape). RECOVERABLE
  ///   — quarantine, then try the `.bak` backup.
  /// - `empty`: no bytes at all (nil or zero-length) — a genuinely absent file,
  ///   e.g. first launch. Nothing to recover.
  enum Classification {
    case valid(records: [TPPBookRegistryData])
    case corrupt
    case empty
  }

  /// Pure classification of raw registry-file bytes.
  ///
  /// Passing `nil` (file does not exist) or empty `Data` yields `.empty`.
  /// Non-empty bytes that fail JSON parsing, or parse to something without a
  /// `records` array, yield `.corrupt`. Well-formed bytes yield `.valid`.
  static func classify(data: Data?) -> Classification {
    guard let data = data, !data.isEmpty else {
      return .empty
    }
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let json = object as? TPPBookRegistryData else {
      // Present but not a JSON object → corrupt (recoverable via quarantine/bak).
      return .corrupt
    }
    guard let records = json.array(for: .records) else {
      // Parseable JSON but the registry shape is wrong (no records array) →
      // treat as corrupt so the file is quarantined rather than silently
      // replaced by an empty registry.
      return .corrupt
    }
    return .valid(records: records)
  }

  /// The persisted schema version of the given bytes, or `nil` when the bytes
  /// are unparseable or carry no `schemaVersion` field (a legacy/unversioned
  /// file). A returned `nil` on otherwise-valid bytes means "migrate on next save".
  static func schemaVersion(from data: Data?) -> Int? {
    guard let data = data,
          let object = try? JSONSerialization.jsonObject(with: data),
          let json = object as? TPPBookRegistryData else {
      return nil
    }
    return json[schemaVersionKey] as? Int
  }

  /// True when the bytes are a valid registry that lacks a `schemaVersion`
  /// field — i.e. a legacy file that will be migrated to the current version
  /// on the next save. False for corrupt/empty bytes and for already-versioned
  /// files.
  static func needsMigration(data: Data?) -> Bool {
    if case .valid = classify(data: data) {
      return schemaVersion(from: data) == nil
    }
    return false
  }

  // MARK: - File-path derivation (pure over URL)

  /// The last-good backup sidecar: `registry.json` → `registry.json.bak`.
  static func backupURL(for registryURL: URL) -> URL {
    registryURL.appendingPathExtension("bak")
  }

  /// The quarantine destination for a corrupt file:
  /// `registry.json` → `registry.json.corrupt-<unix-timestamp>`.
  static func quarantineURL(for registryURL: URL, timestamp: Date = Date()) -> URL {
    let seconds = Int(timestamp.timeIntervalSince1970)
    return registryURL.appendingPathExtension("corrupt-\(seconds)")
  }

  // MARK: - I/O helpers (side-effecting — copy / write / rename)

  /// Copies a corrupt registry file aside to its quarantine path. NEVER moves
  /// or deletes the original — the corrupt bytes are preserved both in place
  /// (until a later authoritative save replaces them) and in the quarantine
  /// copy for forensic/manual recovery.
  ///
  /// - Returns: the quarantine URL on success, `nil` if the source is absent or
  ///   the copy failed.
  @discardableResult
  static func quarantine(corruptFileAt registryURL: URL, timestamp: Date = Date()) -> URL? {
    guard FileManager.default.fileExists(atPath: registryURL.path) else {
      return nil
    }
    let destination = quarantineURL(for: registryURL, timestamp: timestamp)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: registryURL, to: destination)
      return destination
    } catch {
      Log.error(#file, "Failed to quarantine corrupt registry file: \(error.localizedDescription)")
      return nil
    }
  }

  /// Persists `data` as the last-good `.bak` sidecar using a durable
  /// write-new → fsync → rename sequence: the bytes are written to a temporary
  /// file, flushed to stable storage with `fsync`, then atomically renamed over
  /// the existing backup. A crash mid-write can never leave a half-written
  /// `.bak` (the rename is atomic; the temp file is discarded).
  static func writeBackup(data: Data, for registryURL: URL) throws {
    let backup = backupURL(for: registryURL)
    let tempURL = backup.appendingPathExtension("tmp")

    // Ensure the containing directory exists (mirrors save()'s own directory
    // creation) so writing the sidecar cannot fail on a not-yet-created folder.
    let directory = backup.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    try data.write(to: tempURL, options: .atomic)

    // fsync the temp file so its bytes are durable before we rename it into
    // place — otherwise a power loss after the rename could expose an empty
    // inode as the "backup".
    let handle = try FileHandle(forWritingTo: tempURL)
    try handle.synchronize()
    try handle.close()

    if FileManager.default.fileExists(atPath: backup.path) {
      try FileManager.default.removeItem(at: backup)
    }
    try FileManager.default.moveItem(at: tempURL, to: backup)
  }

  /// The records recoverable from the `.bak` backup, or `nil` when there is no
  /// backup, it is unreadable, corrupt, or valid-but-empty. Only a NON-empty
  /// valid backup is a usable recovery source.
  static func recoverFromBackup(for registryURL: URL) -> [TPPBookRegistryData]? {
    let backup = backupURL(for: registryURL)
    guard let data = try? Data(contentsOf: backup) else { return nil }
    if case .valid(let records) = classify(data: data), !records.isEmpty {
      return records
    }
    return nil
  }

  /// True when a non-empty last-good `.bak` backup exists for the registry —
  /// the precondition that makes an empty, non-authoritative save destructive
  /// (INV-1). Cheap wrapper over `recoverFromBackup`.
  static func backupHasRecords(for registryURL: URL) -> Bool {
    return recoverFromBackup(for: registryURL) != nil
  }
}

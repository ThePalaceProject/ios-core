//
//  PerBookRegistryFiles.swift
//  PalaceBookRegistry
//
//  One account's shelf as a record file and a position file per book, kept
//  next to `registry.json` while `per_book_registry_storage` is on (PP-5507).
//  Layout, trust rule and migration: docs/architecture/per-book-registry-storage.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import CryptoKit
import PalaceLogging
import PalaceBookModel

/// The per-book files of one account's registry folder.
///
/// Every file carries the sequence number of the save that wrote it, and the
/// trust record carries the sequence `registry.json` was written at. For each
/// book the newest of the three sources wins, so a crash between two files
/// leaves each book as it was before or after the save.
///
/// Sequences are allocated by the caller, under `sequenceLock`: a shelf save
/// before it takes its snapshot, a position save after it reads the position.
/// So a snapshot that misses a position change always has the lower number.
///
/// Everything else is not thread-safe: `BookRegistrySync` calls it only on its
/// disk-write queue. `@unchecked Sendable` so the queue's closures can capture it.
final class PerBookRegistryFiles: @unchecked Sendable {
  typealias BeforeWrite = (RegistryWriteStep, URL) throws -> Void

  /// Failed migrations allowed for one app version before the shelf stays on
  /// `registry.json` until the next version.
  static let maxMigrationAttempts = 3

  static let booksFolderName = "books"
  static let stagingFolderName = "books.migrating"
  static let stateFileName = "books-state.json"
  private static let identifierKey = "identifier"
  private static let recordKey = "record"
  private static let sequenceKey = "sequence"
  private static let locationKey = TPPBookRegistryKey.location.rawValue

  /// The migration and trust record in `books-state.json`.
  struct State: Equatable {
    var appVersion: String
    var attempts: Int
    var verified: Bool
    /// SHA-256 of the `registry.json` bytes written with these files. When the
    /// file on disk has other bytes, something else wrote it after them (an
    /// older app, or a launch with the flag off), and these files are not trusted.
    var registryDigest: String?
    /// The highest file sequence `registry.json` already reflects.
    var registrySequence: Int = 0
  }

  /// Per-book files read back, each with the sequence of the save that wrote it.
  /// A position file without a location has `location == nil`.
  struct Contents {
    var records: [String: (record: TPPBookRegistryData, sequence: Int)] = [:]
    var positions: [String: (location: Any?, sequence: Int)] = [:]
  }

  let registryURL: URL
  let booksDirectory: URL
  let stagingDirectory: URL
  let stateURL: URL
  private let beforeWrite: BeforeWrite

  /// Content of each book's files as on disk, so a save writes only what changed.
  private var recordContent: [String: Data] = [:]
  private var positionContent: [String: Data] = [:]
  private let sequenceLock = NSLock()
  /// Guarded by `sequenceLock`.
  private var nextSequence = 1

  init(registryURL: URL, beforeWrite: @escaping BeforeWrite) {
    let folder = registryURL.deletingLastPathComponent()
    self.registryURL = registryURL
    self.booksDirectory = folder.appendingPathComponent(Self.booksFolderName, isDirectory: true)
    self.stagingDirectory = folder.appendingPathComponent(Self.stagingFolderName, isDirectory: true)
    self.stateURL = folder.appendingPathComponent(Self.stateFileName)
    self.beforeWrite = beforeWrite
  }

  /// Removes every per-book file of the account. Sign-out runs it whatever the
  /// flag says, so a shelf written under the flag does not outlive the patron.
  static func purge(for registryURL: URL) {
    let folder = registryURL.deletingLastPathComponent()
    for name in [booksFolderName, stagingFolderName, stateFileName] {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  // MARK: - Naming and encoding

  /// A file-name-safe stem for an identifier (identifiers are URLs and URNs).
  static func fileStem(for identifier: String) -> String {
    SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func identifier(of record: TPPBookRegistryData) -> String? {
    (record[TPPBookRegistryKey.book.rawValue] as? [String: Any])?["id"] as? String
  }

  private static func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
  }

  private static func recordObject(_ identifier: String, _ record: TPPBookRegistryData) -> [String: Any] {
    [identifierKey: identifier, recordKey: record]
  }

  /// Keeps the location value exactly, `NSNull` included, so a record read
  /// back equals the one written.
  private static func positionObject(_ identifier: String, _ location: Any?) -> [String: Any] {
    var object: [String: Any] = [identifierKey: identifier]
    if let location { object[locationKey] = location }
    return object
  }

  private func recordURL(_ identifier: String, in folder: URL) -> URL {
    folder.appendingPathComponent(Self.fileStem(for: identifier) + ".record.json")
  }

  private func positionURL(_ identifier: String, in folder: URL) -> URL {
    folder.appendingPathComponent(Self.fileStem(for: identifier) + ".position.json")
  }

  // MARK: - State

  static func readState(at url: URL) -> State? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let appVersion = object["appVersion"] as? String,
          let attempts = object["attempts"] as? Int,
          let verified = object["verified"] as? Bool
    else { return nil }
    return State(appVersion: appVersion, attempts: attempts, verified: verified,
                 registryDigest: object["registryDigest"] as? String,
                 registrySequence: object["registrySequence"] as? Int ?? 0)
  }

  func readState() -> State? { Self.readState(at: stateURL) }

  func writeState(_ state: State) throws {
    var object: [String: Any] = [
      "appVersion": state.appVersion, "attempts": state.attempts,
      "verified": state.verified, "registrySequence": state.registrySequence
    ]
    object["registryDigest"] = state.registryDigest
    try beforeWrite(.perBookState, stateURL)
    try Self.encode(object).write(to: stateURL, options: .atomic)
  }

  /// The trust record when these files hold the newest shelf: verified, and
  /// written together with the `registry.json` bytes now on disk.
  static func trustedState(at stateURL: URL, primaryData: Data?) -> State? {
    guard let state = readState(at: stateURL), state.verified, let recorded = state.registryDigest,
          let primaryData, recorded == digest(of: primaryData) else { return nil }
    return state
  }

  /// A new sequence number for a save.
  func allocateSequence() -> Int {
    sequenceLock.withLock {
      defer { nextSequence += 1 }
      return nextSequence
    }
  }

  private func continueSequence(after highest: Int) {
    sequenceLock.withLock { nextSequence = highest + 1 }
  }

  /// Records that `registryData`, just written to `registry.json` from a
  /// snapshot taken at `sequence`, reflects every file with a lower number.
  func recordTrust(registryData: Data, sequence: Int, appVersion: String) throws {
    try writeState(State(appVersion: appVersion, attempts: 0, verified: true,
                         registryDigest: Self.digest(of: registryData),
                         registrySequence: sequence))
  }

  // MARK: - Reading

  static func read(from folder: URL) -> Contents {
    var contents = Contents()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names {
      let isRecord = name.hasSuffix(".record.json")
      guard isRecord || name.hasSuffix(".position.json"),
            let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = object[identifierKey] as? String
      else {
        Log.warn(#file, "Skipping unreadable per-book registry file \(name)")
        continue
      }
      let sequence = object[sequenceKey] as? Int ?? 0
      if isRecord {
        guard let record = object[recordKey] as? TPPBookRegistryData else { continue }
        contents.records[identifier] = (record, sequence)
      } else {
        contents.positions[identifier] = (object[locationKey], sequence)
      }
    }
    return contents
  }

  /// The trusted shelf and whether any file is newer than `registry.json`.
  /// Remembers what is on disk and continues the sequence after it.
  func loadTrusted(primaryRecords: [TPPBookRegistryData], state: State) -> (records: [TPPBookRegistryData], singleFileBehind: Bool) {
    let contents = Self.read(from: booksDirectory)
    recordContent = [:]
    positionContent = [:]
    var highest = state.registrySequence
    for (identifier, entry) in contents.records {
      recordContent[identifier] = try? Self.encode(Self.recordObject(identifier, entry.record))
      highest = max(highest, entry.sequence)
    }
    for (identifier, entry) in contents.positions {
      positionContent[identifier] = try? Self.encode(Self.positionObject(identifier, entry.location))
      highest = max(highest, entry.sequence)
    }
    continueSequence(after: highest)
    let merged = Self.merge(primary: primaryRecords, contents: contents,
                            registrySequence: state.registrySequence, includeRecords: true)
    return (merged.records, merged.newer)
  }

  /// For each book, the newest of `registry.json` (at `registrySequence`), its
  /// record file and its position file. A record file older than
  /// `registry.json` for a book `registry.json` lacks is a removal that already
  /// reached `registry.json`. `newer` is true when any file won over it.
  ///
  /// - Parameter includeRecords: false for a launch with the flag off, which
  ///   takes only positions from the per-book files.
  static func merge(
    primary: [TPPBookRegistryData],
    contents: Contents,
    registrySequence: Int,
    includeRecords: Bool
  ) -> (records: [TPPBookRegistryData], newer: Bool) {
    var byIdentifier: [String: TPPBookRegistryData] = [:]
    var locationSequence: [String: Int] = [:]
    var order: [String] = []
    var newer = false
    for record in primary {
      guard let identifier = identifier(of: record) else { continue }
      if byIdentifier[identifier] == nil { order.append(identifier) }
      byIdentifier[identifier] = record
      locationSequence[identifier] = registrySequence
    }
    if includeRecords {
      for (identifier, entry) in contents.records where entry.sequence > registrySequence {
        if byIdentifier[identifier] == nil { order.append(identifier) }
        byIdentifier[identifier] = entry.record
        locationSequence[identifier] = entry.sequence
        newer = true
      }
    }
    for (identifier, entry) in contents.positions {
      guard byIdentifier[identifier] != nil, entry.sequence > locationSequence[identifier] ?? .max else { continue }
      byIdentifier[identifier]?[locationKey] = entry.location
      newer = true
    }
    return (order.compactMap { byIdentifier[$0] }, newer)
  }

  /// Positions saved after `registry.json` was last written, applied to its
  /// records, for a launch with the flag off. Nil when the per-book files are
  /// not trusted against these bytes or hold nothing newer. Writes nothing.
  static func newerPositions(registryURL: URL, primaryRecords: [TPPBookRegistryData], primaryData: Data?) -> [TPPBookRegistryData]? {
    let folder = registryURL.deletingLastPathComponent()
    guard let state = trustedState(at: folder.appendingPathComponent(stateFileName), primaryData: primaryData) else { return nil }
    let contents = read(from: folder.appendingPathComponent(booksFolderName, isDirectory: true))
    let merged = merge(primary: primaryRecords, contents: contents,
                       registrySequence: state.registrySequence, includeRecords: false)
    return merged.newer ? merged.records : nil
  }

  // MARK: - Writing

  /// Brings the record files in line with `records`, the whole in-memory shelf
  /// as snapshotted at `sequence`:
  /// one file per changed book, holding its whole record and position, then
  /// removes the files of books no longer on it. One file per book keeps each
  /// book's change atomic.
  func write(shelf records: [TPPBookRegistryData], sequence: Int) throws {
    try ensureFolder(booksDirectory)
    var present = Set<String>()
    for record in records {
      guard let identifier = Self.identifier(of: record) else { continue }
      present.insert(identifier)
      var object = Self.recordObject(identifier, record)
      let content = try Self.encode(object)
      guard recordContent[identifier] != content else { continue }
      object[Self.sequenceKey] = sequence
      try writeFile(Self.encode(object), to: recordURL(identifier, in: booksDirectory), step: .bookRecord)
      recordContent[identifier] = content
    }
    for identifier in Set(recordContent.keys).union(positionContent.keys).subtracting(present) {
      try removeFile(recordURL(identifier, in: booksDirectory))
      recordContent[identifier] = nil
      try removeFile(positionURL(identifier, in: booksDirectory))
      positionContent[identifier] = nil
    }
  }

  /// Writes one book's position file if it changed. `location` is the
  /// location dictionary, or nil for a book without a position.
  func writePosition(identifier: String, location: [String: Any]?, sequence: Int) throws {
    var object = Self.positionObject(identifier, location)
    let content = try Self.encode(object)
    guard positionContent[identifier] != content else { return }
    try ensureFolder(booksDirectory)
    object[Self.sequenceKey] = sequence
    try writeFile(Self.encode(object), to: positionURL(identifier, in: booksDirectory), step: .bookPosition)
    positionContent[identifier] = content
  }

  /// True when any record file exists, so an empty save would remove books.
  func hasRecordFiles() -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? []
    return names.contains { $0.hasSuffix(".record.json") }
  }

  private func writeFile(_ data: Data, to url: URL, step: RegistryWriteStep) throws {
    try beforeWrite(step, url)
    try data.write(to: url, options: .atomic)
  }

  private func removeFile(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try beforeWrite(.bookRemoval, url)
    try FileManager.default.removeItem(at: url)
  }

  /// Removes the staging folder through the write hook, so a crash there
  /// leaves it in place as a real crash would.
  private func removeStaging() {
    guard FileManager.default.fileExists(atPath: stagingDirectory.path),
          (try? beforeWrite(.migrationCleanup, stagingDirectory)) != nil else { return }
    try? FileManager.default.removeItem(at: stagingDirectory)
  }

  private func ensureFolder(_ folder: URL) throws {
    if !FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  // MARK: - Migration

  enum MigrationResult: Equatable {
    case migrated
    /// Not tried: the old file is empty while per-book files hold books, or the
    /// tries for this app version are used up.
    case skipped(reason: String)
    /// Tried and abandoned; the old file stays in use.
    case failed(mismatched: [String])
  }

  /// Moves `primaryRecords`, read from the valid `registry.json` bytes
  /// `primaryData`, into the per-book layout: stage every record file, read the
  /// staged files back, compare every record with the old file, and only then
  /// put them in place and mark them trusted. Any difference or error leaves
  /// the old file in use and the attempt counted.
  func migrate(primaryRecords: [TPPBookRegistryData], primaryData: Data, appVersion: String) -> MigrationResult {
    var expected: [String: TPPBookRegistryData] = [:]
    for record in primaryRecords {
      guard let identifier = Self.identifier(of: record) else { continue }
      expected[identifier] = record
    }
    if expected.isEmpty, hasRecordFiles() {
      return .skipped(reason: "the old file is empty and per-book files hold books")
    }
    let previous = readState()
    let attempts = previous?.appVersion == appVersion ? previous?.attempts ?? 0 : 0
    guard attempts < Self.maxMigrationAttempts else {
      return .skipped(reason: "\(attempts) failed tries for \(appVersion)")
    }

    do {
      try writeState(State(appVersion: appVersion, attempts: attempts + 1, verified: false, registryDigest: nil))
      removeStaging()
      try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
      for (identifier, record) in expected {
        var object = Self.recordObject(identifier, record)
        object[Self.sequenceKey] = 0
        try writeFile(Self.encode(object), to: recordURL(identifier, in: stagingDirectory), step: .migrationStaging)
      }

      try beforeWrite(.migrationVerify, stagingDirectory)
      let staged = Self.read(from: stagingDirectory)
      let mismatched = Self.mismatchedIdentifiers(expected: expected, staged: staged)
      guard mismatched.isEmpty else {
        removeStaging()
        return .failed(mismatched: mismatched)
      }

      if FileManager.default.fileExists(atPath: booksDirectory.path) {
        try beforeWrite(.migrationSwap, booksDirectory)
        try FileManager.default.removeItem(at: booksDirectory)
      }
      try beforeWrite(.migrationSwap, stagingDirectory)
      try FileManager.default.moveItem(at: stagingDirectory, to: booksDirectory)
      recordContent = [:]
      positionContent = [:]
      for (identifier, entry) in staged.records {
        recordContent[identifier] = try? Self.encode(Self.recordObject(identifier, entry.record))
      }
      continueSequence(after: 0)
      try recordTrust(registryData: primaryData, sequence: 0, appVersion: appVersion)
      return .migrated
    } catch {
      Log.error(#file, "Per-book registry migration stopped: \(error.localizedDescription)")
      removeStaging()
      return .failed(mismatched: [])
    }
  }

  /// Identifiers whose staged record does not read back as the old file's
  /// record, including books missing from either side.
  static func mismatchedIdentifiers(expected: [String: TPPBookRegistryData], staged: Contents) -> [String] {
    var mismatched = Set(staged.records.keys).symmetricDifference(expected.keys)
    for (identifier, record) in expected {
      guard let readBack = staged.records[identifier]?.record else { continue }
      if !NSDictionary(dictionary: readBack).isEqual(NSDictionary(dictionary: record)) {
        mismatched.insert(identifier)
      }
    }
    return mismatched.sorted()
  }
}

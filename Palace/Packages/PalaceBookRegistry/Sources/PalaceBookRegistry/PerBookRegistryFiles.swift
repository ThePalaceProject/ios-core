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
/// Not thread-safe: `BookRegistrySync` calls it only on its disk-write queue.
/// `@unchecked Sendable` so the queue's closures can capture it.
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
  }

  /// Per-book files read back: records without their location, and the
  /// position file of each book. A position file without a location is
  /// `.some(nil)`; a book without a position file is absent.
  struct Contents {
    var records: [String: TPPBookRegistryData] = [:]
    var positions: [String: Any?] = [:]
  }

  let registryURL: URL
  let booksDirectory: URL
  let stagingDirectory: URL
  let stateURL: URL
  private let beforeWrite: BeforeWrite

  /// Bytes of each book's files as on disk, so a save writes only what changed.
  private var recordBytes: [String: Data] = [:]
  private var positionBytes: [String: Data] = [:]

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

  private static func encodeRecord(_ identifier: String, _ record: TPPBookRegistryData) throws -> Data {
    var withoutLocation = record
    withoutLocation.removeValue(forKey: locationKey)
    return try encode([identifierKey: identifier, recordKey: withoutLocation])
  }

  /// Keeps the location value exactly, `NSNull` included, so a record read
  /// back equals the one written.
  private static func encodePosition(_ identifier: String, _ record: TPPBookRegistryData) throws -> Data {
    var object: [String: Any] = [identifierKey: identifier]
    if let location = record[locationKey] { object[locationKey] = location }
    return try encode(object)
  }

  private func recordURL(_ identifier: String, in folder: URL) -> URL {
    folder.appendingPathComponent(Self.fileStem(for: identifier) + ".record.json")
  }

  private func positionURL(_ identifier: String, in folder: URL) -> URL {
    folder.appendingPathComponent(Self.fileStem(for: identifier) + ".position.json")
  }

  // MARK: - State

  func readState() -> State? {
    guard let data = try? Data(contentsOf: stateURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let appVersion = object["appVersion"] as? String,
          let attempts = object["attempts"] as? Int,
          let verified = object["verified"] as? Bool
    else { return nil }
    return State(appVersion: appVersion, attempts: attempts, verified: verified,
                 registryDigest: object["registryDigest"] as? String)
  }

  func writeState(_ state: State) throws {
    var object: [String: Any] = ["appVersion": state.appVersion, "attempts": state.attempts, "verified": state.verified]
    object["registryDigest"] = state.registryDigest
    try beforeWrite(.perBookState, stateURL)
    try Self.encode(object).write(to: stateURL, options: .atomic)
  }

  /// Whether these files hold the newest shelf: verified, and written together
  /// with the `registry.json` bytes now on disk.
  func isTrusted(primaryData: Data?) -> Bool {
    guard let state = readState(), state.verified, let digest = state.registryDigest,
          let primaryData else { return false }
    return digest == Self.digest(of: primaryData)
  }

  /// Records that the files match `registryData`, just written to `registry.json`.
  func recordTrust(registryData: Data, appVersion: String) throws {
    try writeState(State(appVersion: appVersion, attempts: 0, verified: true,
                         registryDigest: Self.digest(of: registryData)))
  }

  // MARK: - Reading

  func read(from folder: URL) -> Contents {
    var contents = Contents()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names {
      let isRecord = name.hasSuffix(".record.json")
      guard isRecord || name.hasSuffix(".position.json"),
            let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = object[Self.identifierKey] as? String
      else {
        Log.warn(#file, "Skipping unreadable per-book registry file \(name)")
        continue
      }
      if isRecord {
        guard let record = object[Self.recordKey] as? TPPBookRegistryData else { continue }
        contents.records[identifier] = record
      } else {
        contents.positions[identifier] = .some(object[Self.locationKey])
      }
    }
    return contents
  }

  /// The trusted shelf: every per-book record, every `registry.json` record the
  /// per-book files lack (never fewer books than the old file), and each
  /// position file over the location it covers. Remembers what is on disk.
  func loadTrusted(primaryRecords: [TPPBookRegistryData]) -> [TPPBookRegistryData] {
    let contents = read(from: booksDirectory)
    rememberOnDisk(contents)
    return Self.merge(primary: primaryRecords, contents: contents)
  }

  static func merge(primary: [TPPBookRegistryData], contents: Contents) -> [TPPBookRegistryData] {
    var byIdentifier: [String: TPPBookRegistryData] = [:]
    var order: [String] = []
    func put(_ identifier: String, _ record: TPPBookRegistryData) {
      if byIdentifier[identifier] == nil { order.append(identifier) }
      byIdentifier[identifier] = record
    }
    for record in primary {
      guard let identifier = identifier(of: record) else { continue }
      put(identifier, record)
    }
    for (identifier, record) in contents.records {
      var merged = record
      merged[locationKey] = byIdentifier[identifier]?[locationKey]
      put(identifier, merged)
    }
    for (identifier, position) in contents.positions where byIdentifier[identifier] != nil {
      byIdentifier[identifier]?[locationKey] = position
    }
    return order.compactMap { byIdentifier[$0] }
  }

  private func rememberOnDisk(_ contents: Contents) {
    recordBytes = [:]
    positionBytes = [:]
    for (identifier, record) in contents.records {
      recordBytes[identifier] = try? Self.encodeRecord(identifier, record)
    }
    for (identifier, position) in contents.positions {
      var record: TPPBookRegistryData = [:]
      if case .some(let location) = position { record[Self.locationKey] = location }
      positionBytes[identifier] = try? Self.encodePosition(identifier, record)
    }
  }

  // MARK: - Writing

  /// Brings the files in line with `records`, the whole in-memory shelf: writes
  /// each changed position file, then each changed record file, then removes
  /// the files of books no longer on it. The position goes first so a crash
  /// between the two never leaves a new book without the position it was saved with.
  func write(shelf records: [TPPBookRegistryData]) throws {
    try ensureFolder(booksDirectory)
    var present = Set<String>()
    for record in records {
      guard let identifier = Self.identifier(of: record) else { continue }
      present.insert(identifier)
      let position = try Self.encodePosition(identifier, record)
      if positionBytes[identifier] != position {
        try writeFile(position, to: positionURL(identifier, in: booksDirectory), step: .bookPosition)
        positionBytes[identifier] = position
      }
      let encoded = try Self.encodeRecord(identifier, record)
      if recordBytes[identifier] != encoded {
        try writeFile(encoded, to: recordURL(identifier, in: booksDirectory), step: .bookRecord)
        recordBytes[identifier] = encoded
      }
    }
    for identifier in Set(recordBytes.keys).union(positionBytes.keys).subtracting(present) {
      try beforeWrite(.bookRemoval, recordURL(identifier, in: booksDirectory))
      try removeIfPresent(recordURL(identifier, in: booksDirectory))
      recordBytes[identifier] = nil
      try removeIfPresent(positionURL(identifier, in: booksDirectory))
      positionBytes[identifier] = nil
    }
  }

  /// Writes one book's position file if it changed. `location` is the
  /// location dictionary, or nil for a book without a position.
  func writePosition(identifier: String, location: [String: Any]?) throws {
    var record: TPPBookRegistryData = [:]
    record[Self.locationKey] = location
    let encoded = try Self.encodePosition(identifier, record)
    guard positionBytes[identifier] != encoded else { return }
    try ensureFolder(booksDirectory)
    try writeFile(encoded, to: positionURL(identifier, in: booksDirectory), step: .bookPosition)
    positionBytes[identifier] = encoded
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

  private func removeIfPresent(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private func ensureFolder(_ folder: URL) throws {
    if !FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  // MARK: - Migration

  enum MigrationResult: Equatable {
    case migrated
    /// Not tried: the old file is not a clean, non-empty source, or the tries
    /// for this app version are used up.
    case skipped(reason: String)
    /// Tried and abandoned; the old file stays in use.
    case failed(mismatched: [String])
  }

  /// Moves `primaryRecords`, read from the valid `registry.json` bytes
  /// `primaryData`, into the per-book layout: stage every file, read the staged
  /// files back, compare every record with the old file, and only then put
  /// them in place and mark them trusted. Any difference or error leaves the
  /// old file in use and the attempt counted.
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
      try? FileManager.default.removeItem(at: stagingDirectory)
      try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
      for (identifier, record) in expected {
        let position = try Self.encodePosition(identifier, record)
        try writeFile(position, to: positionURL(identifier, in: stagingDirectory), step: .migrationStaging)
        let encoded = try Self.encodeRecord(identifier, record)
        try writeFile(encoded, to: recordURL(identifier, in: stagingDirectory), step: .migrationStaging)
      }

      try beforeWrite(.migrationVerify, stagingDirectory)
      let staged = read(from: stagingDirectory)
      let mismatched = Self.mismatchedIdentifiers(expected: expected, staged: staged)
      guard mismatched.isEmpty else {
        try? FileManager.default.removeItem(at: stagingDirectory)
        return .failed(mismatched: mismatched)
      }

      try beforeWrite(.migrationSwap, booksDirectory)
      try removeIfPresent(booksDirectory)
      try FileManager.default.moveItem(at: stagingDirectory, to: booksDirectory)
      rememberOnDisk(staged)
      try recordTrust(registryData: primaryData, appVersion: appVersion)
      return .migrated
    } catch {
      Log.error(#file, "Per-book registry migration stopped: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: stagingDirectory)
      return .failed(mismatched: [])
    }
  }

  /// Identifiers whose staged files do not read back as the old file's record,
  /// including books missing from either side.
  static func mismatchedIdentifiers(expected: [String: TPPBookRegistryData], staged: Contents) -> [String] {
    var mismatched = Set(staged.records.keys).symmetricDifference(expected.keys)
    for (identifier, record) in expected where staged.records[identifier] != nil {
      guard case .some(let location) = staged.positions[identifier] else {
        mismatched.insert(identifier)
        continue
      }
      var readBack = staged.records[identifier] ?? [:]
      readBack[locationKey] = location
      if !NSDictionary(dictionary: readBack).isEqual(to: record) {
        mismatched.insert(identifier)
      }
    }
    return mismatched.sorted()
  }
}

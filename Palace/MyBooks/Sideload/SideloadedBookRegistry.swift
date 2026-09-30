//
//  SideloadedBookRegistry.swift
//  Palace
//
//  Local-only persistence for side-loaded books (PP-2678), a test-only
//  capability (docs/architecture/sideloading-plan.md). The second book-state
//  owner, scoped to side-loaded content; loan state stays in `TPPBookRegistry`
//  and is never set here (docs/architecture/state-management-doctrine.md).
//
//  `BookRegistrySync.sync()` subtracts `identifiers` from its delete set on the
//  main actor, so a loans feed that never lists a side-loaded book does not
//  evict it; that read must stay cheap and synchronous. The manifest is a
//  private JSON file under Application Support, not account-scoped or synced.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

/// Local-only registry of side-loaded books.
///
/// Concurrency: `@unchecked Sendable`. Every access to `entriesByIdentifier`
/// and `order` goes through `lock`, and the manifest is rewritten while the
/// lock is held, so readers never see a half-applied change and writers never
/// race the file. Read from both the main-actor sync path and the off-main
/// import path, so it cannot be `@MainActor`.
final class SideloadedBookRegistry: @unchecked Sendable {

  /// Fixed account the side-loaded content directory is pinned to. Side-loaded
  /// books are account-agnostic, but `BookFileManager.fileUrl` resolves a
  /// per-account path. The import copy and `BookFileManager` both use this
  /// constant, so a library switch cannot orphan a side-loaded file.
  /// `TPPAccountUUIDs[0]` gets no sub-path, giving the stable
  /// `<AppSupport>/<bundleID>/content/` directory.
  static let sideloadContentAccountID = AccountsManager.TPPAccountUUIDs[0]

  /// One persisted side-loaded book: the `TPPBook` plus the original imported
  /// filename (shown in the manage-list UI).
  private struct Entry {
    let book: TPPBook
    let originalFilename: String
  }

  private let lock = NSLock()
  private let fileManager: FileManager
  /// Manifest file URL. Optional because directory resolution can fail (no
  /// Application Support path / missing bundle id) — in that degraded state
  /// the registry works in-memory and simply cannot persist.
  private let manifestURL: URL?

  private var entriesByIdentifier: [String: Entry] = [:]
  /// Insertion order of identifiers, so `allBooks` is stable across reloads.
  private var order: [String] = []

  // MARK: - JSON keys

  private enum ManifestKey {
    static let books = "books"
    static let book = "book"
    static let filename = "filename"
  }

  // MARK: - Init

  /// - Parameters:
  ///   - fileManager: injectable for tests; production uses `.default`.
  ///   - manifestDirectory: test seam. When non-nil, the manifest lives at
  ///     `<manifestDirectory>/sideloaded.json`; when nil (production) it
  ///     resolves under Application Support at
  ///     `<AppSupport>/<bundleID>/sideloaded/sideloaded.json`.
  init(fileManager: FileManager = .default, manifestDirectory: URL? = nil) {
    self.fileManager = fileManager
    if let manifestDirectory {
      self.manifestURL = manifestDirectory.appendingPathComponent("sideloaded.json")
    } else {
      self.manifestURL = TPPBookContentMetadataFilesHelper
        .directory(for: Self.sideloadContentAccountID)?
        .appendingPathComponent("sideloaded")
        .appendingPathComponent("sideloaded.json")
    }
    loadFromDisk()
  }

  // MARK: - Public read surface

  /// Identifiers of every side-loaded book. Cheap synchronous read — this is
  /// what `BookRegistrySync.sync()` subtracts from its delete set.
  var identifiers: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return Set(entriesByIdentifier.keys)
  }

  /// Every side-loaded book, in import order. Drives the side-loaded lane.
  var allBooks: [TPPBook] {
    lock.lock()
    defer { lock.unlock() }
    return order.compactMap { entriesByIdentifier[$0]?.book }
  }

  /// Original imported filename for a side-loaded book, if known.
  func originalFilename(for identifier: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return entriesByIdentifier[identifier]?.originalFilename
  }

  /// This owner's `BookStateReading` view of `bookIdentifier`. Side-loaded books
  /// are copied locally and registered into the main registry as
  /// `.downloadSuccessful`, so a book THIS owner holds reports
  /// `.downloadSuccessful`; any identifier it does not own, including every
  /// loaned book, reports `.unregistered`. Not a loan-state authority.
  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier else { return .unregistered }
    lock.lock()
    defer { lock.unlock() }
    return entriesByIdentifier[bookIdentifier] != nil ? .downloadSuccessful : .unregistered
  }

  // MARK: - Public mutation surface

  /// Record (or overwrite) a side-loaded book plus the file it was imported
  /// from. A repeat `add` for the same identifier updates in place — it does
  /// not create a duplicate lane entry.
  /// Record (or overwrite) a side-loaded book plus its imported file, then
  /// persist. THROWS if the manifest write fails, rolling the in-memory
  /// mutation back first so the failure is atomic — the caller (import) can
  /// then abort before registering into the main registry. A repeat `add` for
  /// the same identifier updates in place; it does not create a duplicate.
  func add(book: TPPBook, fileURL: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    let previousEntry = entriesByIdentifier[book.identifier]
    let wasPresent = previousEntry != nil
    if !wasPresent {
      order.append(book.identifier)
    }
    entriesByIdentifier[book.identifier] = Entry(
      book: book,
      originalFilename: fileURL.lastPathComponent
    )
    do {
      try persistLocked()
    } catch {
      // Roll the mutation back so a persist failure leaves the registry
      // exactly as it was — the add is all-or-nothing.
      if wasPresent {
        entriesByIdentifier[book.identifier] = previousEntry
      } else {
        entriesByIdentifier[book.identifier] = nil
        order.removeAll { $0 == book.identifier }
      }
      throw error
    }
  }

  /// Forget a side-loaded book. No-op if the identifier is unknown. Persist is
  /// best-effort: a failed remove-persist leaves a stale manifest entry (the
  /// book reappears next launch pointing at a deleted file), which is a
  /// self-healing nuisance, not the silent data loss `add` guards against — so
  /// this path logs (inside `persistLocked`) and swallows rather than throws.
  func remove(identifier: String) {
    lock.lock()
    defer { lock.unlock() }
    guard entriesByIdentifier[identifier] != nil else { return }
    entriesByIdentifier[identifier] = nil
    order.removeAll { $0 == identifier }
    try? persistLocked()
  }

  /// Rename a side-loaded book's display title. No-op if unknown. Replaces the
  /// stored `TPPBook` with a copy carrying the new title rather than mutating
  /// the shared instance in place: that same `TPPBook` reference was handed to
  /// the main `TPPBookRegistry` at import, so an in-place `title` write could
  /// race main-registry / Catalog readers (only this registry's lock guards
  /// the write). Persist is best-effort (see `remove`).
  func rename(identifier: String, to newTitle: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entriesByIdentifier[identifier] else { return }
    // `bookWithMetadata(from:)` returns a fresh, distinct `TPPBook` (a full
    // copy of `entry.book`). Mutating THAT copy's title is safe — it is not the
    // instance the main registry holds — whereas mutating `entry.book.title`
    // directly would race the shared reference.
    let renamed = entry.book.bookWithMetadata(from: entry.book)
    renamed.title = newTitle
    entriesByIdentifier[identifier] = Entry(
      book: renamed,
      originalFilename: entry.originalFilename
    )
    try? persistLocked()
  }

  /// Replace the persisted book for an identifier (e.g. after re-minting
  /// metadata) while preserving the original imported filename. No-op if the
  /// identifier is unknown — `update` never inserts. Persist is best-effort
  /// (see `remove`).
  func update(book: TPPBook) {
    lock.lock()
    defer { lock.unlock() }
    guard let existing = entriesByIdentifier[book.identifier] else { return }
    entriesByIdentifier[book.identifier] = Entry(
      book: book,
      originalFilename: existing.originalFilename
    )
    try? persistLocked()
  }

  // MARK: - Persistence (lock held by caller)

  /// Writes the manifest to disk. Throws on any write failure so callers on
  /// the atomicity-critical import path (`add`) can abort loudly instead of
  /// silently proceeding to register a book the manifest doesn't record — a
  /// book present in the main registry but absent from the side-load manifest
  /// is not in the sync-exemption set and would be evicted (silent data loss).
  /// The nil-`manifestURL` degraded mode (no Application Support path) is NOT a
  /// write failure: it is the documented in-memory-only fallback, so it returns
  /// without throwing.
  private func persistLocked() throws {
    guard let manifestURL else {
      Log.warn(#file, "SideloadedBookRegistry: no manifest URL — side-loaded state will not persist")
      return
    }
    let records: [[String: Any]] = order.compactMap { identifier in
      guard let entry = entriesByIdentifier[identifier] else { return nil }
      return [
        ManifestKey.book: entry.book.dictionaryRepresentation(),
        ManifestKey.filename: entry.originalFilename
      ]
    }
    let manifest: [String: Any] = [ManifestKey.books: records]
    do {
      let directoryURL = manifestURL.deletingLastPathComponent()
      if !fileManager.fileExists(atPath: directoryURL.path) {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      }
      directoryURL.excludeFromBackup()
      let data = try JSONSerialization.data(withJSONObject: manifest, options: .fragmentsAllowed)
      try data.write(to: manifestURL, options: .atomic)
    } catch {
      Log.error(#file, "SideloadedBookRegistry: failed to persist manifest: \(error.localizedDescription)")
      throw error
    }
  }

  private func loadFromDisk() {
    guard let manifestURL,
          fileManager.fileExists(atPath: manifestURL.path),
          let data = try? Data(contentsOf: manifestURL),
          let json = try? JSONSerialization.jsonObject(with: data),
          let dict = json as? [String: Any],
          let records = dict[ManifestKey.books] as? [[String: Any]]
    else {
      // Missing / corrupt / empty / wrong-shape manifest: start empty. Never
      // throw — a bad manifest must not crash launch.
      return
    }

    for record in records {
      guard let bookDict = record[ManifestKey.book] as? [String: Any],
            let book = TPPBook(dictionary: bookDict)
      else {
        Log.warn(#file, "SideloadedBookRegistry: dropping unreadable manifest record")
        continue
      }
      let filename = record[ManifestKey.filename] as? String ?? ""
      if entriesByIdentifier[book.identifier] == nil {
        order.append(book.identifier)
      }
      entriesByIdentifier[book.identifier] = Entry(book: book, originalFilename: filename)
    }
  }
}

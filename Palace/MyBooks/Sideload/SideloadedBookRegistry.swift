//
//  SideloadedBookRegistry.swift
//  Palace
//
//  Dedicated, local-only persistence for side-loaded books (PP-2678).
//
//  Side-loading is a test-only capability (see
//  `docs/architecture/sideloading-plan.md`): a user imports a local
//  EPUB / PDF / audiobook file and it is registered into the main
//  `TPPBookRegistry` as `.downloadSuccessful` so the real reader + DRM
//  stack opens it with no OPDS feed involved.
//
//  This registry is the *source of truth* for "what is side-loaded". It
//  serves two consumers:
//    1. The main registry's server `sync()` reconciliation subtracts
//       `identifiers` from its delete set so a loans feed that (of course)
//       never lists a side-loaded book does not evict it + delete its file.
//       This read happens INSIDE `BookRegistrySync.sync()` on the main
//       actor, so it MUST be a cheap synchronous read.
//    2. The side-loaded catalog lane (Module D) renders `allBooks`.
//
//  Persistence is a private JSON manifest, separate from `registry.json`,
//  under Application Support (backup-excluded, consistent with the main
//  registry — the ticket's "Documents folder" wording is illustrative; see
//  the plan's persistence-location open item). It is NOT account-scoped or
//  server-synced: side-loaded content is account-agnostic.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Local-only registry of side-loaded books.
///
/// Concurrency: `@unchecked Sendable`. INVARIANT — every access to the two
/// mutable stores (`entriesByIdentifier`, `order`) is serialised through
/// `lock`; the manifest is (re)written synchronously while the lock is held,
/// so a reader never observes a half-applied mutation and two writers never
/// race the file. `fileManager` and `manifestURL` are immutable `let`s. This
/// follows the module-3 playbook (prefer `NSLock` + documented invariant over
/// `nonisolated(unsafe)`). `identifiers`/`allBooks` are read from BOTH the
/// main-actor sync path and the (off-main) import path, so the type cannot be
/// `@MainActor`-only.
final class SideloadedBookRegistry: @unchecked Sendable {

  /// Fixed account the side-loaded content directory is pinned to. Side-loaded
  /// books are account-agnostic, but `BookFileManager.fileUrl` resolves a
  /// per-account path. Pinning BOTH the write (Module C's import copy) AND the
  /// read (`BookFileManager` Component 4) to this one account means a library
  /// switch cannot orphan a side-loaded file. `TPPAccountUUIDs[0]` is the
  /// primary/no-subpath account — `TPPBookContentMetadataFilesHelper.directory`
  /// appends no sub-path for it, giving the stable
  /// `<AppSupport>/<bundleID>/content/` directory. Both sides consume THIS
  /// constant so they can never pick the account independently.
  static let sideloadContentAccountID = AccountsManager.TPPAccountUUIDs[0]

  /// One persisted side-loaded book: the `TPPBook` plus the original imported
  /// filename (surfaced in the manage-list UI, Module C).
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

  // MARK: - Public mutation surface

  /// Record (or overwrite) a side-loaded book plus the file it was imported
  /// from. A repeat `add` for the same identifier updates in place — it does
  /// not create a duplicate lane entry.
  func add(book: TPPBook, fileURL: URL) {
    lock.lock()
    defer { lock.unlock() }
    if entriesByIdentifier[book.identifier] == nil {
      order.append(book.identifier)
    }
    entriesByIdentifier[book.identifier] = Entry(
      book: book,
      originalFilename: fileURL.lastPathComponent
    )
    persistLocked()
  }

  /// Forget a side-loaded book. No-op if the identifier is unknown.
  func remove(identifier: String) {
    lock.lock()
    defer { lock.unlock() }
    guard entriesByIdentifier[identifier] != nil else { return }
    entriesByIdentifier[identifier] = nil
    order.removeAll { $0 == identifier }
    persistLocked()
  }

  /// Rename a side-loaded book's display title in place. No-op if unknown.
  func rename(identifier: String, to newTitle: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entriesByIdentifier[identifier] else { return }
    // `TPPBook.title` is a mutable `var`; the book is a reference type, so
    // mutating the stored instance's title is the rename.
    entry.book.title = newTitle
    persistLocked()
  }

  /// Replace the persisted book for an identifier (e.g. after re-minting
  /// metadata) while preserving the original imported filename. No-op if the
  /// identifier is unknown — `update` never inserts.
  func update(book: TPPBook) {
    lock.lock()
    defer { lock.unlock() }
    guard let existing = entriesByIdentifier[book.identifier] else { return }
    entriesByIdentifier[book.identifier] = Entry(
      book: book,
      originalFilename: existing.originalFilename
    )
    persistLocked()
  }

  // MARK: - Persistence (lock held by caller)

  private func persistLocked() {
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

//
//  SideloadedBookManager.swift
//  Palace
//
//  Orchestrates the side-loading import flow (PP-2677).
//
//  Classifies the file (rejecting unsupported types before writing), mints a
//  synthetic open-access `TPPBook` whose acquisition MIME matches the content
//  type, copies the file to the fixed side-load account's content path, and
//  registers the book in `SideloadedBookRegistry` (which is the sync
//  exemption) and in the main registry as `.downloadSuccessful`. `remove`
//  reverses this; `rehydrateAtLaunch` re-registers after a cold launch. See
//  docs/architecture/sideloading-plan.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import CryptoKit
import PalaceCatalog
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - Seams

/// The slice of `SideloadedBookRegistry` this manager depends on, so it can
/// be tested against a spy.
protocol SideloadedBookRegistering: AnyObject {
  var allBooks: [TPPBook] { get }
  var identifiers: Set<String> { get }
  func add(book: TPPBook, fileURL: URL) throws
  func remove(identifier: String)
  /// The original imported filename, shown in the Settings manage list instead
  /// of the content-hash identifier.
  func originalFilename(for identifier: String) -> String?
}

extension SideloadedBookRegistry: SideloadedBookRegistering {}

/// Result of classifying an import candidate.
struct SideloadClassification: Equatable {
  let contentType: TPPBookContentType
  /// The acquisition MIME to mint the synthetic book with. Must round-trip
  /// through `TPPBookContentType.from(mimeType:)` back to `contentType`.
  let mimeType: String
}

/// Classifies an import candidate by file type. A seam so the contract test can
/// record the classify step and the unit test can force error paths.
protocol SideloadContentClassifier {
  func classify(fileURL: URL) throws -> SideloadClassification
}

/// The file operations the import/remove flow needs. A seam so tests can record
/// the copy step (contract snapshot) and drive copy failures.
protocol SideloadFileManaging {
  func copyFile(from source: URL, to destination: URL) throws
  func removeFile(at url: URL) throws
}

// MARK: - Errors

enum SideloadImportError: Error, Equatable, CustomStringConvertible {
  /// The file extension / MIME did not resolve to EPUB, PDF or audiobook.
  case unsupportedFileType(String)
  /// The source file could not be read (missing / unreadable).
  case unreadableFile(URL)
  /// `BookFileManager` could not resolve a destination path.
  case destinationUnavailable
  /// The side-load manifest could not be persisted; the import was aborted
  /// before registering into the main registry to avoid a book that the
  /// sync-exemption set won't cover (which would be silently evicted).
  case persistenceFailed

  var description: String {
    switch self {
    case let .unsupportedFileType(ext):
      return "Unsupported side-load file type: \"\(ext)\". Supported: EPUB, PDF, audiobook manifest."
    case let .unreadableFile(url):
      return "Could not read side-load file at \(url.lastPathComponent)."
    case .destinationUnavailable:
      return "Could not resolve a destination for the side-loaded file."
    case .persistenceFailed:
      return "Could not save the side-loaded book; the import was cancelled."
    }
  }
}

// MARK: - Default seam implementations

/// Extension → MIME classification. LCP-encrypted EPUBs are still `.epub`
/// files; audiobooks import as their manifest JSON.
struct DefaultSideloadContentClassifier: SideloadContentClassifier {
  func classify(fileURL: URL) throws -> SideloadClassification {
    let ext = fileURL.pathExtension.lowercased()
    let mimeType: String
    switch ext {
    case "epub":
      mimeType = ContentTypeEpubZip
    case "pdf":
      mimeType = ContentTypeOpenAccessPDF
    case "json", "audiobook":
      mimeType = ContentTypeOpenAccessAudiobook
    default:
      throw SideloadImportError.unsupportedFileType(ext.isEmpty ? "<none>" : ext)
    }
    // Defend against a mapping drift: the minted MIME MUST classify back to a
    // supported content type, else the reader would show the unsupported-item
    // error after import.
    let contentType = TPPBookContentType.from(mimeType: mimeType)
    guard contentType != .unsupported else {
      throw SideloadImportError.unsupportedFileType(ext)
    }
    return SideloadClassification(contentType: contentType, mimeType: mimeType)
  }
}

/// `FileManager`-backed file operations. Creates the destination's parent
/// directory (the test `directoryProvider` path does not create it) and
/// overwrites an existing file so a re-import of the same content is idempotent.
struct DefaultSideloadFileManaging: SideloadFileManaging {
  let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func copyFile(from source: URL, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
  }

  func removeFile(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }
}

// MARK: - SideloadedBookManager

/// Concurrency: `@unchecked Sendable`. All stored dependencies are immutable
/// `let`s and are themselves internally synchronised (the registries are
/// lock/queue-backed; `BookFileManager` is effectively stateless path logic).
/// The manager holds no mutable state of its own. It is cached in an
/// `AppContainer` static the same way `SideloadedBookRegistry` is, and its
/// `rehydrateAtLaunch()` runs off the main actor from the registry-load
/// completion — so it cannot be `@MainActor`-only.
final class SideloadedBookManager: @unchecked Sendable {

  private let bookRegistry: TPPBookRegistryProvider
  private let sideloadedRegistry: SideloadedBookRegistering
  private let bookFileManager: BookFileManager
  private let classifier: SideloadContentClassifier
  private let fileManaging: SideloadFileManaging
  private let imageCache: ImageCacheType

  init(
    bookRegistry: TPPBookRegistryProvider,
    sideloadedRegistry: SideloadedBookRegistering,
    bookFileManager: BookFileManager,
    classifier: SideloadContentClassifier = DefaultSideloadContentClassifier(),
    fileManaging: SideloadFileManaging = DefaultSideloadFileManaging(),
    imageCache: ImageCacheType = ImageCache.shared
  ) {
    self.bookRegistry = bookRegistry
    self.sideloadedRegistry = sideloadedRegistry
    self.bookFileManager = bookFileManager
    self.classifier = classifier
    self.fileManaging = fileManaging
    self.imageCache = imageCache
  }

  /// Every side-loaded book, in import order. Drives the Settings manage-list
  /// and (indirectly) the side-loaded catalog lane.
  var allBooks: [TPPBook] {
    sideloadedRegistry.allBooks
  }

  /// The original imported filename for a side-loaded book. Returns nil
  /// for an unknown identifier; callers fall back to the book title.
  func originalFilename(for identifier: String) -> String? {
    sideloadedRegistry.originalFilename(for: identifier)
  }

  // MARK: Import

  /// Import a local file as a side-loaded book. Returns the minted `TPPBook`.
  ///
  /// The identifier is derived from the file's CONTENT (sha256), so importing
  /// the same file twice yields the same identifier — the second import
  /// overwrites in place rather than creating a duplicate lane entry (dedup).
  ///
  /// Ordered effects (pinned by `SideloadImportContractTests`):
  /// classify → copyFile → sideloadedRegistry.add → bookRegistry.addBook.
  @discardableResult
  func `import`(fileURL: URL) throws -> TPPBook {
    let classification = try classifier.classify(fileURL: fileURL)

    let identifier = try Self.contentIdentifier(for: fileURL)
    let title = fileURL.deletingPathExtension().lastPathComponent
    let book = Self.mintOpenAccessBook(
      identifier: identifier,
      title: title.isEmpty ? "Side-loaded book" : title,
      mimeType: classification.mimeType,
      imageCache: imageCache
    )

    // Pin the write to the fixed side-load account, not currentAccountId, so
    // the file stays resolvable after a library switch; `BookFileManager`
    // resolves side-loaded ids to the same account.
    guard let destination = bookFileManager.fileUrl(
      for: book,
      account: SideloadedBookRegistry.sideloadContentAccountID
    ) else {
      throw SideloadImportError.destinationUnavailable
    }

    do {
      try fileManaging.copyFile(from: fileURL, to: destination)
    } catch {
      Log.error(#file, "Side-load import: file copy failed: \(error.localizedDescription)")
      throw error
    }

    // Side-load registry first: it is the sync exemption. If the manifest
    // fails to persist, abort before the main registry write (the next
    // `sync()` would otherwise evict the book and delete its file) and remove
    // the copied file.
    do {
      try sideloadedRegistry.add(book: book, fileURL: fileURL)
    } catch {
      try? fileManaging.removeFile(at: destination)
      Log.error(#file, "Side-load import: manifest persist failed, aborting before main-registry write: \(error.localizedDescription)")
      throw SideloadImportError.persistenceFailed
    }
    bookRegistry.addBook(
      book,
      location: nil,
      state: .downloadSuccessful,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )

    Log.info(#file, "Side-loaded \(classification.contentType) book imported: \(identifier)")
    return book
  }

  // MARK: Remove

  /// Forget a side-loaded book: delete its on-disk file, then remove it from
  /// the side-loaded registry AND the main registry. No-op for an unknown id.
  func remove(identifier: String) {
    let book = bookRegistry.book(forIdentifier: identifier)
      ?? sideloadedRegistry.allBooks.first { $0.identifier == identifier }

    if let book,
       let fileURL = bookFileManager.fileUrl(
        for: book,
        account: SideloadedBookRegistry.sideloadContentAccountID
       ) {
      do {
        try fileManaging.removeFile(at: fileURL)
      } catch {
        Log.warn(#file, "Side-load remove: could not delete file \(fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    sideloadedRegistry.remove(identifier: identifier)
    bookRegistry.removeBook(forIdentifier: identifier)
  }

  // MARK: Launch rehydration

  /// Re-register every persisted side-loaded book into the MAIN registry as
  /// `.downloadSuccessful`. The main registry does not persist side-loaded-ness,
  /// so a cold launch loses these entries until this runs. Idempotent: a book
  /// already present in the main registry is skipped, so running twice does not
  /// duplicate or reset state.
  ///
  /// MUST be driven from the `bookRegistry.load(completion:)` callback (see
  /// `TPPAppDelegate.setupBookRegistryAndNotifications`): `load()` is async and
  /// a rehydrate that ran before the disk snapshot landed would be clobbered.
  func rehydrateAtLaunch() {
    for book in sideloadedRegistry.allBooks
    where bookRegistry.book(forIdentifier: book.identifier) == nil {
      bookRegistry.addBook(
        book,
        location: nil,
        state: .downloadSuccessful,
        fulfillmentId: nil,
        readiumBookmarks: nil,
        genericBookmarks: nil
      )
    }
  }

  // MARK: Minting

  /// A stable, content-derived identifier. The sha256 of THIS string is what
  /// `BookFileManager` uses for the on-disk path; deriving the id from content
  /// is what makes a re-import of the same file dedup.
  static func contentIdentifier(for fileURL: URL) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw SideloadImportError.unreadableFile(fileURL)
    }
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "sideload-\(hex)"
  }

  /// Mints a synthetic OPEN-ACCESS `TPPBook` with exactly one acquisition whose
  /// MIME is `mimeType` — DRM-free (no revoke URL, no bearer token, no
  /// needs-auth acquisition), unlimited availability, no cover.
  static func mintOpenAccessBook(
    identifier: String,
    title: String,
    mimeType: String,
    imageCache: ImageCacheType
  ) -> TPPBook {
    let acquisition = TPPOPDSAcquisition(
      relation: .openAccess,
      type: mimeType,
      hrefURL: URL(string: "palace-sideload://\(identifier)") ?? URL(fileURLWithPath: "/"),
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    return TPPBook(
      acquisitions: [acquisition],
      authors: nil,
      categoryStrings: nil,
      distributor: nil,
      identifier: identifier,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: nil,
      publisher: nil,
      subtitle: nil,
      summary: nil,
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: nil,
      bookDuration: nil,
      imageCache: imageCache
    )
  }
}

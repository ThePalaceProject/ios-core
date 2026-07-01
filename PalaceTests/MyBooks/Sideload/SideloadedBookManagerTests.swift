//
//  SideloadedBookManagerTests.swift
//  PalaceTests
//
//  Behaviour coverage for the side-loading import/remove/rehydrate flow
//  (PP-2677). Drives the real `SideloadedBookManager` against a temp-dir
//  `SideloadedBookRegistry`, a `TPPBookRegistryMock`, and a `BookFileManager`
//  with a temp `directoryProvider` — no singletons, no network.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SideloadedBookManagerTests: PalaceWiringTestCase {

  private var tempRoot: URL!
  private var contentRoot: URL!
  private var manifestDir: URL!
  private var importSourceDir: URL!
  private var defaultsSuiteName: String!
  private var customDefaults: UserDefaults!

  /// A library that is NOT the fixed side-load account — proves the import
  /// pins the write to the fixed account regardless of the current library.
  private let nonPrimaryAccount = "urn:uuid:deadbeef-1111-4000-8000-notprimarylib"

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SideloadMgrTests-\(UUID().uuidString)")
    contentRoot = tempRoot.appendingPathComponent("content")
    manifestDir = tempRoot.appendingPathComponent("manifest")
    importSourceDir = tempRoot.appendingPathComponent("incoming")
    for dir in [contentRoot, manifestDir, importSourceDir] {
      try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
    }

    defaultsSuiteName = "SideloadMgrTests-\(UUID().uuidString)"
    customDefaults = UserDefaults(suiteName: defaultsSuiteName)
    customDefaults.set(nonPrimaryAccount, forKey: currentAccountIdentifierKey)

    XCTAssertNotEqual(nonPrimaryAccount, SideloadedBookRegistry.sideloadContentAccountID,
                      "Precondition: current account must differ from the fixed side-load account")
  }

  override func tearDownWithError() throws {
    customDefaults.removePersistentDomain(forName: defaultsSuiteName)
    customDefaults = nil
    defaultsSuiteName = nil
    try? FileManager.default.removeItem(at: tempRoot)
    tempRoot = nil
    try super.tearDownWithError()
  }

  // MARK: - Fixtures / builders

  private func writeFixture(ext: String, contents: String = UUID().uuidString) throws -> URL {
    let url = importSourceDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func makeBookFileManager(registry: TPPBookRegistryProvider) -> BookFileManager {
    let accountsManager = makeFreshAccountsManager(defaults: customDefaults)
    let root = contentRoot!
    return BookFileManager(
      bookRegistry: registry,
      accountsManager: accountsManager,
      fileManager: .default,
      directoryProvider: { account in root.appendingPathComponent("acct-\(account ?? "nil")") },
      sideloadedIdentifiersProvider: { [] }
    )
  }

  private func makeManager(
    registry: TPPBookRegistryProvider,
    sideloaded: SideloadedBookRegistry,
    fileManaging: SideloadFileManaging = DefaultSideloadFileManaging()
  ) -> SideloadedBookManager {
    SideloadedBookManager(
      bookRegistry: registry,
      sideloadedRegistry: sideloaded,
      bookFileManager: makeBookFileManager(registry: registry),
      classifier: DefaultSideloadContentClassifier(),
      fileManaging: fileManaging,
      imageCache: MockImageCache()
    )
  }

  // MARK: - Classification

  func testImport_epubFile_mintsEpubOpenAccessBook_andRegistersDownloadSuccessful() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    let source = try writeFixture(ext: "epub")

    let book = try manager.import(fileURL: source)

    XCTAssertEqual(book.defaultBookContentType, .epub)
    XCTAssertTrue(sideloaded.identifiers.contains(book.identifier), "truth store must record the id")
    XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful,
                   "main registry must record .downloadSuccessful so the reader opens it")
    XCTAssertNotNil(registry.book(forIdentifier: book.identifier))
  }

  func testImport_pdfFile_mintsPdfContentType() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)

    let book = try manager.import(fileURL: try writeFixture(ext: "pdf"))

    XCTAssertEqual(book.defaultBookContentType, .pdf)
    XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
  }

  func testImport_audiobookManifest_mintsAudiobookContentType() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)

    let book = try manager.import(fileURL: try writeFixture(ext: "json", contents: "{\"metadata\":{}}"))

    XCTAssertEqual(book.defaultBookContentType, .audiobook)
  }

  // MARK: - Fixed-account write

  func testImport_copiesFileToFixedAccountPath_notCurrentAccount() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    let source = try writeFixture(ext: "epub")

    let book = try manager.import(fileURL: source)

    let fixedAccount = SideloadedBookRegistry.sideloadContentAccountID
    let expectedDir = contentRoot.appendingPathComponent("acct-\(fixedAccount)")
    let expected = expectedDir
      .appendingPathComponent(book.identifier.sha256())
      .appendingPathExtension("epub")

    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                  "file must be copied to the fixed-account sha256 path, expected: \(expected.path)")
    let currentAccountDir = contentRoot.appendingPathComponent("acct-\(nonPrimaryAccount)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: currentAccountDir.path),
                   "file must NOT be written under the current (non-primary) account")
  }

  // MARK: - Dedup

  func testImport_sameContentTwice_doesNotDuplicate() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    let source = try writeFixture(ext: "epub", contents: "identical-bytes")

    let first = try manager.import(fileURL: source)
    let second = try manager.import(fileURL: source)

    XCTAssertEqual(first.identifier, second.identifier,
                   "same content ⇒ same content-derived identifier")
    XCTAssertEqual(sideloaded.identifiers.count, 1, "re-import must not create a duplicate entry")
    XCTAssertEqual(sideloaded.allBooks.count, 1)
  }

  // MARK: - Error paths

  func testImport_unsupportedType_throws_andMutatesNeitherRegistry() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    let source = try writeFixture(ext: "txt")

    XCTAssertThrowsError(try manager.import(fileURL: source)) { error in
      guard case SideloadImportError.unsupportedFileType = error else {
        return XCTFail("expected unsupportedFileType, got \(error)")
      }
    }
    XCTAssertTrue(sideloaded.identifiers.isEmpty, "no partial write to the truth store")
    XCTAssertTrue(registry.registry.isEmpty, "no partial write to the main registry")
  }

  func testImport_copyFailure_throws_andMutatesNeitherRegistry() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded, fileManaging: FailingFileManaging())
    let source = try writeFixture(ext: "epub")

    XCTAssertThrowsError(try manager.import(fileURL: source))
    XCTAssertTrue(sideloaded.identifiers.isEmpty,
                  "a copy failure must abort before any registry mutation")
    XCTAssertTrue(registry.registry.isEmpty)
  }

  // MARK: - Remove

  func testRemove_deletesFile_andClearsBothRegistries() throws {
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    let book = try manager.import(fileURL: try writeFixture(ext: "epub"))

    let expected = contentRoot
      .appendingPathComponent("acct-\(SideloadedBookRegistry.sideloadContentAccountID)")
      .appendingPathComponent(book.identifier.sha256())
      .appendingPathExtension("epub")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "precondition: file exists")

    manager.remove(identifier: book.identifier)

    XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path), "file must be deleted")
    XCTAssertFalse(sideloaded.identifiers.contains(book.identifier), "truth store must be cleared")
    XCTAssertNil(registry.book(forIdentifier: book.identifier), "main registry must be cleared")
  }

  func testRemove_bookPresentOnlyInSideloadedRegistry_deletesFileViaFallbackLookup() throws {
    // Main registry is EMPTY, so `remove` must resolve the book through the
    // side-loaded-registry fallback to find + delete its on-disk file.
    let registry = TPPBookRegistryMock()
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let bfm = makeBookFileManager(registry: registry)
    let manager = SideloadedBookManager(
      bookRegistry: registry,
      sideloadedRegistry: sideloaded,
      bookFileManager: bfm,
      imageCache: MockImageCache()
    )

    let book = SideloadedBookManager.mintOpenAccessBook(
      identifier: "sideload-fallback-1",
      title: "Fallback",
      mimeType: "application/epub+zip",
      imageCache: MockImageCache()
    )
    sideloaded.add(book: book, fileURL: URL(fileURLWithPath: "/tmp/z.epub"))

    let fileURL = try XCTUnwrap(bfm.fileUrl(for: book, account: SideloadedBookRegistry.sideloadContentAccountID))
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "precondition: file staged")
    XCTAssertNil(registry.book(forIdentifier: book.identifier), "precondition: NOT in the main registry")

    manager.remove(identifier: book.identifier)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                   "fallback lookup must resolve the book and delete its file")
    XCTAssertFalse(sideloaded.identifiers.contains(book.identifier))
  }

  // MARK: - Launch rehydration

  func testRehydrateAtLaunch_reRegistersPersistedBooks_intoMainRegistry_asDownloadSuccessful() throws {
    // Persist a side-loaded book directly (simulates surviving a cold launch),
    // with an EMPTY main registry (the main registry loses side-loaded-ness).
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let book = SideloadedBookManager.mintOpenAccessBook(
      identifier: "sideload-rehydrate-1",
      title: "Rehydrated",
      mimeType: "application/epub+zip",
      imageCache: MockImageCache()
    )
    sideloaded.add(book: book, fileURL: URL(fileURLWithPath: "/tmp/x.epub"))

    let registry = TPPBookRegistryMock()
    let manager = makeManager(registry: registry, sideloaded: sideloaded)
    XCTAssertNil(registry.book(forIdentifier: book.identifier), "precondition: main registry empty")

    manager.rehydrateAtLaunch()

    XCTAssertNotNil(registry.book(forIdentifier: book.identifier), "book must be re-registered")
    XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
  }

  func testRehydrateAtLaunch_runTwice_isIdempotent_doesNotReAddPresentBook() throws {
    let sideloaded = SideloadedBookRegistry(manifestDirectory: manifestDir)
    let book = SideloadedBookManager.mintOpenAccessBook(
      identifier: "sideload-rehydrate-2",
      title: "Rehydrated Twice",
      mimeType: "application/epub+zip",
      imageCache: MockImageCache()
    )
    sideloaded.add(book: book, fileURL: URL(fileURLWithPath: "/tmp/y.epub"))

    let registry = CountingBookRegistryMock()
    let manager = makeManager(registry: registry, sideloaded: sideloaded)

    manager.rehydrateAtLaunch()
    manager.rehydrateAtLaunch()

    XCTAssertEqual(registry.addBookCallCount, 1,
                   "second rehydrate must skip the already-present book (idempotent)")
    XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
  }
}

// MARK: - Test doubles

/// A file-managing seam that fails every copy, to drive the copy-failure path.
private struct FailingFileManaging: SideloadFileManaging {
  struct Boom: Error {}
  func copyFile(from source: URL, to destination: URL) throws { throw Boom() }
  func removeFile(at url: URL) throws {}
}

/// Counts `addBook` calls so the idempotency test can prove the second
/// rehydrate does NOT re-add an already-present book (kills the existence-guard
/// mutant, which a keyed-dict registry alone can't observe).
private final class CountingBookRegistryMock: TPPBookRegistryMock {
  private(set) var addBookCallCount = 0
  override func addBook(
    _ book: TPPBook,
    location: TPPBookLocation?,
    state: TPPBookState,
    fulfillmentId: String?,
    readiumBookmarks: [TPPReadiumBookmark]?,
    genericBookmarks: [TPPBookLocation]?
  ) {
    addBookCallCount += 1
    super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                  readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
  }
}

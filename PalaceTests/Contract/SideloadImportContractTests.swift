//
//  SideloadImportContractTests.swift
//  PalaceTests
//
//  Contract-snapshot for the side-loading import pipeline (PP-2677). Pins the
//  ORDERED sequence of dependency calls a successful import makes:
//
//      classify → copyFile → sideloadRegistry.add → bookRegistry.addBook
//
//  A reorder, a dropped call, or a changed state argument drifts the snapshot
//  and fails loudly. See PalaceTests/Contract/README.md for the pattern.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class SideloadImportContractTests: PalaceWiringTestCase {

  private var tempRoot: URL!
  private var contentRoot: URL!
  private var manifestDir: URL!
  private var sourceDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SideloadContractTests-\(UUID().uuidString)")
    contentRoot = tempRoot.appendingPathComponent("content")
    manifestDir = tempRoot.appendingPathComponent("manifest")
    sourceDir = tempRoot.appendingPathComponent("incoming")
    for dir in [contentRoot, manifestDir, sourceDir] {
      try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempRoot)
    tempRoot = nil
    try super.tearDownWithError()
  }

  func testImportPipeline_recordsOrderedDependencyCalls() throws {
    let log = CallLog()

    let recordingRegistry = RecordingBookRegistry(log: log)
    let recordingSideloaded = RecordingSideloadedRegistry(
      inner: SideloadedBookRegistry(manifestDirectory: manifestDir),
      log: log
    )
    let isolatedDefaults = UserDefaults(suiteName: "SideloadContract-\(UUID().uuidString)") ?? .standard
    let bookFileManager = BookFileManager(
      bookRegistry: recordingRegistry,
      accountsManager: makeFreshAccountsManager(defaults: isolatedDefaults),
      fileManager: .default,
      directoryProvider: { [contentRoot] account in contentRoot!.appendingPathComponent("acct-\(account ?? "nil")") },
      sideloadedIdentifiersProvider: { [] }
    )

    let manager = SideloadedBookManager(
      bookRegistry: recordingRegistry,
      sideloadedRegistry: recordingSideloaded,
      bookFileManager: bookFileManager,
      classifier: RecordingClassifier(inner: DefaultSideloadContentClassifier(), log: log),
      fileManaging: RecordingFileManaging(log: log),
      imageCache: MockImageCache()
    )

    // Fixed content ⇒ deterministic; but only stable args are recorded anyway.
    let source = sourceDir.appendingPathComponent("contract-fixture.epub")
    try Data("palace-sideload-contract-fixture".utf8).write(to: source)

    _ = try manager.import(fileURL: source)

    ContractSnapshot.assert(log, named: "importEpub")
  }
}

// MARK: - Recording spies (record stable args only, so the snapshot is deterministic)

private final class RecordingClassifier: SideloadContentClassifier {
  private let inner: SideloadContentClassifier
  private let log: CallLog
  init(inner: SideloadContentClassifier, log: CallLog) { self.inner = inner; self.log = log }
  func classify(fileURL: URL) throws -> SideloadClassification {
    let result = try inner.classify(fileURL: fileURL)
    log.record("classify", args: ["contentType": "\(result.contentType)", "mimeType": result.mimeType])
    return result
  }
}

private final class RecordingFileManaging: SideloadFileManaging {
  private let log: CallLog
  init(log: CallLog) { self.log = log }
  func copyFile(from source: URL, to destination: URL) throws {
    log.record("copyFile", args: ["ext": destination.pathExtension])
  }
  func removeFile(at url: URL) throws {
    log.record("removeFile")
  }
}

private final class RecordingSideloadedRegistry: SideloadedBookRegistering {
  private let inner: SideloadedBookRegistry
  private let log: CallLog
  init(inner: SideloadedBookRegistry, log: CallLog) { self.inner = inner; self.log = log }
  var allBooks: [TPPBook] { inner.allBooks }
  var identifiers: Set<String> { inner.identifiers }
  func add(book: TPPBook, fileURL: URL) throws {
    log.record("sideloadRegistry.add", args: ["contentType": "\(book.defaultBookContentType)"])
    try inner.add(book: book, fileURL: fileURL)
  }
  func remove(identifier: String) {
    log.record("sideloadRegistry.remove")
    inner.remove(identifier: identifier)
  }
  func originalFilename(for identifier: String) -> String? {
    inner.originalFilename(for: identifier)
  }
}

private final class RecordingBookRegistry: TPPBookRegistryMock {
  private let log: CallLog
  init(log: CallLog) { self.log = log; super.init() }
  override func addBook(
    _ book: TPPBook,
    location: TPPBookLocation?,
    state: TPPBookState,
    fulfillmentId: String?,
    readiumBookmarks: [TPPReadiumBookmark]?,
    genericBookmarks: [TPPBookLocation]?
  ) {
    log.record("bookRegistry.addBook", args: ["state": state.stringValue()])
    super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                  readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
  }
}

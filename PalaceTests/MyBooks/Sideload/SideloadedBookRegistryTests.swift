//
//  SideloadedBookRegistryTests.swift
//  PalaceTests
//
//  Behavioural tests for the local-only side-loaded book registry (PP-2678):
//  manifest round-trip, add/remove/rename/update, and the corrupt/empty/
//  missing-manifest and duplicate-add edge cases.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class SideloadedBookRegistryTests: XCTestCase {

  private var tempDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SideloadedBookRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    try super.tearDownWithError()
  }

  // MARK: - Helpers

  private func makeRegistry() -> SideloadedBookRegistry {
    SideloadedBookRegistry(fileManager: .default, manifestDirectory: tempDirectory)
  }

  private func makeBook(identifier: String, title: String) -> TPPBook {
    TPPBook(
      acquisitions: [TPPFake.genericAcquisition],
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
      imageCache: MockImageCache()
    )
  }

  private func fileURL(named name: String) -> URL {
    tempDirectory.appendingPathComponent(name)
  }

  private var manifestPath: String {
    tempDirectory.appendingPathComponent("sideloaded.json").path
  }

  // MARK: - Manifest round-trip

  func test_add_persistsAcrossReload_preservingIdentifiersTitlesAndFilenames() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "First"),
                 fileURL: fileURL(named: "first.epub"))
    try registry.add(book: makeBook(identifier: "sl-2", title: "Second"),
                 fileURL: fileURL(named: "second.pdf"))

    // Fresh instance reads the same on-disk manifest.
    let reloaded = makeRegistry()

    XCTAssertEqual(reloaded.allBooks.map(\.identifier), ["sl-1", "sl-2"],
                   "Reload must preserve books and their import order")
    XCTAssertEqual(reloaded.allBooks.map(\.title), ["First", "Second"],
                   "Reload must preserve titles")
    XCTAssertEqual(reloaded.originalFilename(for: "sl-1"), "first.epub")
    XCTAssertEqual(reloaded.originalFilename(for: "sl-2"), "second.pdf")
    XCTAssertEqual(reloaded.identifiers, ["sl-1", "sl-2"])
  }

  // MARK: - add / remove

  func test_remove_dropsBookFromIdentifiersAndPersists() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "First"),
                 fileURL: fileURL(named: "first.epub"))
    try registry.add(book: makeBook(identifier: "sl-2", title: "Second"),
                 fileURL: fileURL(named: "second.epub"))

    registry.remove(identifier: "sl-1")

    XCTAssertEqual(registry.identifiers, ["sl-2"],
                   "remove must drop the id from the in-memory set")
    // Persisted: a fresh instance must not resurrect the removed book.
    XCTAssertEqual(makeRegistry().identifiers, ["sl-2"],
                   "remove must persist — reload must not resurrect the book")
  }

  func test_remove_unknownIdentifier_isNoOp() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "First"),
                 fileURL: fileURL(named: "first.epub"))

    registry.remove(identifier: "does-not-exist")

    XCTAssertEqual(registry.identifiers, ["sl-1"])
  }

  // MARK: - rename

  func test_rename_changesPersistedTitle_survivesReload() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "Old Title"),
                 fileURL: fileURL(named: "first.epub"))

    registry.rename(identifier: "sl-1", to: "New Title")

    XCTAssertEqual(registry.allBooks.first?.title, "New Title",
                   "rename must mutate the in-memory title")
    XCTAssertEqual(makeRegistry().allBooks.first?.title, "New Title",
                   "rename must persist the new title across reload")
  }

  func test_rename_doesNotMutateSharedBookInstance_replacesWithCopy() throws {
    // The same `TPPBook` reference is handed to the main registry at import, so
    // rename must NOT mutate it in place (that would race main-registry /
    // Catalog readers) — it must replace the stored entry with a copy.
    let registry = makeRegistry()
    let original = makeBook(identifier: "sl-1", title: "Original")
    try registry.add(book: original, fileURL: fileURL(named: "first.epub"))

    registry.rename(identifier: "sl-1", to: "Renamed")

    XCTAssertEqual(original.title, "Original",
                   "rename must not mutate the shared TPPBook instance — it must replace with a copy")
    XCTAssertEqual(registry.allBooks.first?.title, "Renamed",
                   "the registry read API must reflect the new title")
    XCTAssertFalse(registry.allBooks.first === original,
                   "the stored book must be a distinct instance from the shared original")
  }

  func test_rename_unknownIdentifier_isNoOp() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "Old Title"),
                 fileURL: fileURL(named: "first.epub"))

    registry.rename(identifier: "ghost", to: "Should Not Apply")

    XCTAssertEqual(registry.allBooks.first?.title, "Old Title")
  }

  // MARK: - update

  func test_update_replacesBookButPreservesOriginalFilename() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "Before"),
                 fileURL: fileURL(named: "import-source.epub"))

    registry.update(book: makeBook(identifier: "sl-1", title: "After"))

    XCTAssertEqual(registry.allBooks.first?.title, "After",
                   "update must replace the stored book")
    XCTAssertEqual(registry.originalFilename(for: "sl-1"), "import-source.epub",
                   "update must preserve the original imported filename")
  }

  func test_update_unknownIdentifier_doesNotInsert() {
    let registry = makeRegistry()

    registry.update(book: makeBook(identifier: "sl-1", title: "Ghost"))

    XCTAssertTrue(registry.identifiers.isEmpty,
                  "update must never insert an unknown book")
  }

  // MARK: - Persist-failure atomicity

  func test_add_whenManifestWriteFails_throws_andRollsBackInMemory() throws {
    // Nest the manifest directory under a regular FILE so `createDirectory`
    // inside `persistLocked` fails → the write throws. `add` must surface the
    // error AND leave the registry exactly as it was (all-or-nothing).
    let blocker = tempDirectory.appendingPathComponent("blocker")
    try Data("x".utf8).write(to: blocker)
    let unwritableDir = blocker.appendingPathComponent("nested")
    let registry = SideloadedBookRegistry(fileManager: .default, manifestDirectory: unwritableDir)

    XCTAssertThrowsError(try registry.add(book: makeBook(identifier: "sl-1", title: "Doomed"),
                                          fileURL: fileURL(named: "x.epub")),
                         "a manifest write failure must propagate out of add")
    XCTAssertTrue(registry.identifiers.isEmpty,
                  "a failed add must roll back — no partial in-memory entry")
    XCTAssertTrue(registry.allBooks.isEmpty,
                  "a failed add must not leave a dangling order entry")
  }

  // MARK: - Edge cases

  func test_addDuplicateIdentifier_doesNotDoubleInsert_andUpdatesInPlace() throws {
    let registry = makeRegistry()
    try registry.add(book: makeBook(identifier: "sl-1", title: "First Import"),
                 fileURL: fileURL(named: "a.epub"))
    try registry.add(book: makeBook(identifier: "sl-1", title: "Re-Import"),
                 fileURL: fileURL(named: "b.epub"))

    XCTAssertEqual(registry.allBooks.count, 1,
                   "Re-adding the same id must not create a duplicate lane entry")
    XCTAssertEqual(registry.allBooks.first?.title, "Re-Import")
    XCTAssertEqual(registry.originalFilename(for: "sl-1"), "b.epub",
                   "Re-add must overwrite the stored filename")
  }

  func test_missingManifest_loadsAsEmpty() {
    // No file has been written to tempDirectory.
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath))
    // Direct instantiation (not via the helper) to document the construction seam.
    let registry = SideloadedBookRegistry(fileManager: .default, manifestDirectory: tempDirectory)
    XCTAssertTrue(registry.identifiers.isEmpty)
    XCTAssertTrue(registry.allBooks.isEmpty)
  }

  func test_corruptManifest_loadsAsEmpty_withoutCrashing() throws {
    try Data("{ this is not valid json".utf8)
      .write(to: tempDirectory.appendingPathComponent("sideloaded.json"))

    let registry = makeRegistry()

    XCTAssertTrue(registry.identifiers.isEmpty,
                  "A corrupt manifest must load as an empty registry, not crash")
    // And the registry must still be usable afterward.
    try registry.add(book: makeBook(identifier: "sl-1", title: "Recovered"),
                 fileURL: fileURL(named: "r.epub"))
    XCTAssertEqual(registry.identifiers, ["sl-1"])
  }

  func test_emptyManifestFile_loadsAsEmpty() throws {
    try Data().write(to: tempDirectory.appendingPathComponent("sideloaded.json"))
    let registry = makeRegistry()
    XCTAssertTrue(registry.identifiers.isEmpty)
  }

  func test_manifestWithGarbageRecord_skipsUnreadableEntry_keepsValidOnes() throws {
    // Hand-write a manifest: one valid book record + one record whose "book"
    // dict is missing the required id/title (TPPBook(dictionary:) → nil).
    let valid = makeBook(identifier: "sl-good", title: "Good")
    let manifest: [String: Any] = [
      "books": [
        ["book": valid.dictionaryRepresentation(), "filename": "good.epub"],
        ["book": ["title": "no id here"], "filename": "bad.epub"]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try data.write(to: tempDirectory.appendingPathComponent("sideloaded.json"))

    let registry = makeRegistry()

    XCTAssertEqual(registry.identifiers, ["sl-good"],
                   "Garbage records must be skipped while valid ones survive")
  }
}

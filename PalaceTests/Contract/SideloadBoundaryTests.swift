//
//  SideloadBoundaryTests.swift
//  PalaceTests
//
//  Boundary tests for the scoped source-of-truth clause (swarm swarm_8ce6f5ae ·
//  Contract D). `SideloadedBookRegistry` is the documented, probe-guarded SECOND
//  book-state owner, scoped to side-loaded (non-loan) content. These tests pin
//  the boundary the doctrine declares:
//
//    1. The side-load owner reports its OWN membership-derived state through the
//       `BookStateReading` seam (present → `.downloadSuccessful`; unknown →
//       `.unregistered`) and never invents a loan state.
//    2. The two owners answer over DISJOINT identifier sets: through the shared
//       `BookStateReading` seam, each returns `.unregistered` for the other
//       owner's book — they never reconcile against each other.
//    3. Importing a side-loaded book registers it (`addBook`, `.downloadSuccessful`)
//       but NEVER drives a loan-state transition (`setState`): the side-load path
//       does not reach into the loan owner's transition seam.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

// The loan owner already exposes `state(for:)` via `TPPBookRegistryProvider`;
// the test conforms the mock to the shared read seam so a heterogeneous
// `[BookStateReading]` can exercise both owners. (Production `TPPBookRegistry`
// conformance is Contract C's — its file is off-limits here.)
extension TPPBookRegistryMock: BookStateReading {}

@MainActor
final class SideloadBoundaryTests: PalaceWiringTestCase {

  private var tempRoot: URL!
  private var contentRoot: URL!
  private var manifestDir: URL!
  private var sourceDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SideloadBoundaryTests-\(UUID().uuidString)")
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
    contentRoot = nil
    manifestDir = nil
    sourceDir = nil
    try super.tearDownWithError()
  }

  private func makeSideloadRegistry() -> SideloadedBookRegistry {
    SideloadedBookRegistry(manifestDirectory: manifestDir)
  }

  // MARK: - 1. The side-load owner's own state(for:) projection

  func testState_forUnknownIdentifier_isUnregistered() {
    let registry = makeSideloadRegistry()
    XCTAssertEqual(registry.state(for: "never-added"), .unregistered)
  }

  func testState_forNilIdentifier_isUnregistered() {
    let registry = makeSideloadRegistry()
    XCTAssertEqual(registry.state(for: nil), .unregistered)
  }

  func testState_afterAdd_isDownloadSuccessful() throws {
    let registry = makeSideloadRegistry()
    let book = TPPBookMocker.mockBook(identifier: "sideload-1", title: "Sideloaded")
    try registry.add(book: book, fileURL: sourceDir.appendingPathComponent("x.epub"))

    XCTAssertEqual(registry.state(for: "sideload-1"), .downloadSuccessful)
  }

  func testState_afterRemove_returnsToUnregistered() throws {
    let registry = makeSideloadRegistry()
    let book = TPPBookMocker.mockBook(identifier: "sideload-2", title: "Sideloaded")
    try registry.add(book: book, fileURL: sourceDir.appendingPathComponent("y.epub"))
    XCTAssertEqual(registry.state(for: "sideload-2"), .downloadSuccessful)

    registry.remove(identifier: "sideload-2")
    XCTAssertEqual(registry.state(for: "sideload-2"), .unregistered)
  }

  // MARK: - 2. Disjoint ownership through the shared BookStateReading seam

  func testTwoOwners_answerOnlyForTheirOwnBooks_andNeverReconcile() throws {
    // Side-load owner holds A; loan owner holds B in an active loan state.
    let sideloadOwner = makeSideloadRegistry()
    let bookA = TPPBookMocker.mockBook(identifier: "A-sideloaded", title: "A")
    try sideloadOwner.add(book: bookA, fileURL: sourceDir.appendingPathComponent("a.epub"))

    let loanOwner = TPPBookRegistryMock()
    let bookB = TPPBookMocker.mockBook(identifier: "B-loaned", title: "B")
    loanOwner.addBook(bookB, state: .downloadNeeded)

    // Both are viewed through ONE read seam.
    let owners: [BookStateReading] = [sideloadOwner, loanOwner]
    XCTAssertEqual(owners.count, 2)

    // Each owner speaks ONLY for its own identifier; neither reconciles the
    // other's book into its own state.
    XCTAssertEqual(sideloadOwner.state(for: "A-sideloaded"), .downloadSuccessful)
    XCTAssertEqual(sideloadOwner.state(for: "B-loaned"), .unregistered,
                   "Side-load owner must not report loan state for a loaned book.")
    XCTAssertEqual(loanOwner.state(for: "B-loaned"), .downloadNeeded)
    XCTAssertEqual(loanOwner.state(for: "A-sideloaded"), .unregistered,
                   "Loan owner must not know a side-loaded book it never received.")

    // Exercising the heterogeneous seam yields each owner's OWN view of A.
    XCTAssertEqual(owners.map { $0.state(for: "A-sideloaded") },
                   [.downloadSuccessful, .unregistered])
  }

  // MARK: - 3. Import registers content but drives NO loan-state transition

  func testImport_registersDownloadSuccessful_butNeverCallsSetState() throws {
    let spyLoanRegistry = SetStateSpyRegistry()
    let sideloadRegistry = makeSideloadRegistry()

    let isolatedDefaults = UserDefaults(suiteName: "SideloadBoundary-\(UUID().uuidString)") ?? .standard
    let bookFileManager = BookFileManager(
      bookRegistry: spyLoanRegistry,
      accountsManager: makeFreshAccountsManager(defaults: isolatedDefaults),
      fileManager: .default,
      directoryProvider: { [contentRoot] account in contentRoot!.appendingPathComponent("acct-\(account ?? "nil")") },
      sideloadedIdentifiersProvider: { [] }
    )

    let manager = SideloadedBookManager(
      bookRegistry: spyLoanRegistry,
      sideloadedRegistry: sideloadRegistry,
      bookFileManager: bookFileManager,
      classifier: DefaultSideloadContentClassifier(),
      fileManaging: NoopFileManaging(),
      imageCache: MockImageCache()
    )

    let source = sourceDir.appendingPathComponent("boundary-fixture.epub")
    try Data("palace-sideload-boundary-fixture".utf8).write(to: source)

    let imported = try manager.import(fileURL: source)

    // The side-load owner is now authoritative for the imported book.
    XCTAssertEqual(sideloadRegistry.state(for: imported.identifier), .downloadSuccessful)

    // The loan owner received exactly one registration, as a completed download…
    XCTAssertEqual(spyLoanRegistry.addBookStates, [.downloadSuccessful])
    // …and the side-load path NEVER drove a loan-state transition.
    XCTAssertTrue(spyLoanRegistry.setStateCalls.isEmpty,
                  "Importing side-loaded content must not call setState on the loan owner: got \(spyLoanRegistry.setStateCalls)")
  }
}

// MARK: - Spies / fakes

/// Loan-registry spy: records every `addBook` state and every `setState` call so
/// the boundary test can assert the side-load path registers content but never
/// transitions loan state.
private final class SetStateSpyRegistry: TPPBookRegistryMock {
  private(set) var addBookStates: [TPPBookState] = []
  private(set) var setStateCalls: [(state: TPPBookState, id: String)] = []

  override func addBook(
    _ book: TPPBook,
    location: TPPBookLocation?,
    state: TPPBookState,
    fulfillmentId: String?,
    readiumBookmarks: [TPPReadiumBookmark]?,
    genericBookmarks: [TPPBookLocation]?
  ) {
    addBookStates.append(state)
    super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                  readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
  }

  override func setState(_ state: TPPBookState, for bookIdentifier: String) {
    setStateCalls.append((state, bookIdentifier))
    super.setState(state, for: bookIdentifier)
  }
}

/// No-op file operations so the boundary test exercises the import decision
/// path without touching disk (the copy target is irrelevant to the boundary).
private final class NoopFileManaging: SideloadFileManaging {
  func copyFile(from source: URL, to destination: URL) throws {}
  func removeFile(at url: URL) throws {}
}

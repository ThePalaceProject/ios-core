//
//  BookFileManagerSideloadResolutionTests.swift
//  PalaceTests
//
//  Component 4 (sideloading-plan.md R6): a side-loaded book's file is written
//  under one fixed account (`SideloadedBookRegistry.sideloadContentAccountID`)
//  because side-loaded content is account-agnostic. `BookFileManager.fileUrl`
//  must therefore resolve a side-loaded id to that FIXED account's directory
//  even when the current library (or a caller-supplied account) differs — else
//  a library switch orphans the file and the reader can't open it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookFileManagerSideloadResolutionTests: PalaceWiringTestCase {

  private var tempDirectory: URL!
  private var defaultsSuiteName: String!
  private var customDefaults: UserDefaults!

  /// A library that is NOT the fixed side-load account, so we can prove the
  /// resolution ignores it for side-loaded ids.
  private let nonPrimaryAccount = "urn:uuid:deadbeef-0000-4000-8000-nonprimarylib"

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BFMSideloadTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    defaultsSuiteName = "BFMSideloadTests-\(UUID().uuidString)"
    customDefaults = UserDefaults(suiteName: defaultsSuiteName)
    // Drive currentAccountId to a NON-primary library.
    customDefaults.set(nonPrimaryAccount, forKey: currentAccountIdentifierKey)

    XCTAssertNotEqual(nonPrimaryAccount, SideloadedBookRegistry.sideloadContentAccountID,
                      "Precondition: the current account must differ from the fixed side-load account")
  }

  override func tearDownWithError() throws {
    customDefaults.removePersistentDomain(forName: defaultsSuiteName)
    customDefaults = nil
    defaultsSuiteName = nil
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    try super.tearDownWithError()
  }

  // MARK: - Helpers

  private func makeBook(identifier: String) -> TPPBook {
    TPPBook(
      acquisitions: [TPPFake.genericAcquisition],
      authors: nil, categoryStrings: nil, distributor: nil,
      identifier: identifier,
      imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
      subtitle: nil, summary: nil, title: "Title \(identifier)", updated: Date(),
      annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
      relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
      revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
      contributors: nil, bookDuration: nil, imageCache: MockImageCache()
    )
  }

  /// Builds a BookFileManager whose content directory is a per-account temp
  /// folder (so the resolved path reveals WHICH account was used), a registry
  /// with the two seeded books, and a fixed side-loaded id set.
  private func makeFileManager(sideloadedIDs: Set<String>) -> BookFileManager {
    let registry = TPPBookRegistryMock()
    registry.addBook(makeBook(identifier: "sideload-1"), state: .downloadSuccessful)
    registry.addBook(makeBook(identifier: "normal-1"), state: .downloadSuccessful)
    // Carries the "sideload-" prefix but is NOT in the provider set — for the
    // defense-in-depth case: prefix alone must not pin to the fixed account.
    registry.addBook(makeBook(identifier: "sideload-ghost"), state: .downloadSuccessful)

    let accountsManager = makeFreshAccountsManager(defaults: customDefaults)
    let dir = tempDirectory!

    return BookFileManager(
      bookRegistry: registry,
      accountsManager: accountsManager,
      fileManager: .default,
      directoryProvider: { account in
        dir.appendingPathComponent("acct-\(account ?? "nil")")
      },
      sideloadedIdentifiersProvider: { sideloadedIDs }
    )
  }

  // MARK: - Tests

  func test_sideloadedId_resolvesToFixedAccount_evenWhenExplicitAccountDiffers() {
    let bfm = makeFileManager(sideloadedIDs: ["sideload-1"])

    // Caller passes the NON-primary account; the side-load substitution must
    // override it with the fixed account.
    let url = bfm.fileUrl(for: "sideload-1", account: nonPrimaryAccount)

    let path = try? XCTUnwrap(url).path
    XCTAssertNotNil(path)
    XCTAssertTrue(path?.contains("acct-\(SideloadedBookRegistry.sideloadContentAccountID)") ?? false,
                  "Side-loaded id must resolve under the fixed side-load account, got: \(path ?? "nil")")
    XCTAssertFalse(path?.contains("acct-\(nonPrimaryAccount)") ?? true,
                   "Side-loaded id must NOT resolve under the caller-supplied non-primary account")
  }

  func test_sideloadedId_resolvesToFixedAccount_evenWhenCurrentAccountDiffers() {
    // Multi-step: currentAccountId is a non-primary library (set in setUp),
    // then resolve via the no-account overload (which reads currentAccountId),
    // and assert the FIXED account directory — proving a library switch cannot
    // orphan the side-loaded file.
    let bfm = makeFileManager(sideloadedIDs: ["sideload-1"])

    let url = bfm.fileUrl(for: "sideload-1")

    let path = try? XCTUnwrap(url).path
    XCTAssertTrue(path?.contains("acct-\(SideloadedBookRegistry.sideloadContentAccountID)") ?? false,
                  "With current account = non-primary, side-loaded id must still resolve under the fixed account, got: \(path ?? "nil")")
    XCTAssertFalse(path?.contains("acct-\(nonPrimaryAccount)") ?? true)
  }

  func test_nonSideloadedId_resolvesAgainstCurrentAccount_unchanged() {
    // Contrast: a normal book is NOT side-loaded, so it must resolve against
    // the current/caller account exactly as before (no behavior change).
    let bfm = makeFileManager(sideloadedIDs: ["sideload-1"])

    let explicitURL = bfm.fileUrl(for: "normal-1", account: nonPrimaryAccount)
    let explicitPath = try? XCTUnwrap(explicitURL).path
    XCTAssertTrue(explicitPath?.contains("acct-\(nonPrimaryAccount)") ?? false,
                  "A non-side-loaded id must resolve under the passed account, got: \(explicitPath ?? "nil")")
    XCTAssertFalse(explicitPath?.contains("acct-\(SideloadedBookRegistry.sideloadContentAccountID)") ?? true,
                   "A non-side-loaded id must NOT be pinned to the fixed side-load account")

    // And via the current-account overload.
    let currentURL = bfm.fileUrl(for: "normal-1")
    let currentPath = try? XCTUnwrap(currentURL).path
    XCTAssertTrue(currentPath?.contains("acct-\(nonPrimaryAccount)") ?? false,
                  "A non-side-loaded id must resolve under currentAccountId")
  }

  func test_sideloadPrefixedId_notInProvider_resolvesAgainstAccount_defenseInDepth() {
    // An id can carry the "sideload-" prefix yet not be registered in the
    // provider set. The prefix is only a cheap gate for the lock+set lookup;
    // membership in the provider is still authoritative. Such an id must NOT be
    // pinned to the fixed side-load account — it resolves against the caller's
    // account like any normal id.
    let bfm = makeFileManager(sideloadedIDs: ["sideload-1"])

    let url = bfm.fileUrl(for: "sideload-ghost", account: nonPrimaryAccount)

    let path = try? XCTUnwrap(url).path
    XCTAssertTrue(path?.contains("acct-\(nonPrimaryAccount)") ?? false,
                  "A prefixed id absent from the provider must resolve under the passed account, got: \(path ?? "nil")")
    XCTAssertFalse(path?.contains("acct-\(SideloadedBookRegistry.sideloadContentAccountID)") ?? true,
                   "Prefix alone must not pin to the fixed side-load account — provider membership is authoritative")
  }
}

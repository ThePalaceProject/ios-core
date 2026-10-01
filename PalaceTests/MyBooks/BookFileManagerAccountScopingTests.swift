//
//  BookFileManagerAccountScopingTests.swift
//  PalaceTests
//
//  Pins how `BookFileManager` scopes download files per account: the
//  `fileUrl(for:)` convenience follows `currentAccountId` (two libraries never
//  share a download path), and a registered `sideload-` id always resolves under
//  `SideloadedBookRegistry.sideloadContentAccountID` so a library switch cannot
//  orphan it. See docs/architecture/god-class-decomposition-plan.md §3a.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class BookFileManagerAccountScopingTests: PalaceWiringTestCase {

    private var registry: TPPBookRegistryMock!
    private var defaults: UserDefaults!
    private var accountsManager: AccountsManager!

    private let accountA = "wave3-filescope-A-\(UUID().uuidString)"
    private let accountB = "wave3-filescope-B-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        defaults = Self.testUserDefaults()
        // Start "current library == A".
        defaults.set(accountA, forKey: currentAccountIdentifierKey)
        accountsManager = makeFreshAccountsManager(defaults: defaults)
    }

    override func tearDownWithError() throws {
        registry = nil
        accountsManager = nil
        defaults = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A `directoryProvider` that echoes the resolved account into a stable temp
    /// path, so a test can read back WHICH account the file URL resolved under.
    /// Returns nil for a nil account (matches production's "no directory").
    private static func echoingDirectoryProvider() -> (String?) -> URL? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wave3-filescope-\(UUID().uuidString)")
        return { account in
            guard let account else { return nil }
            return root.appendingPathComponent(account).appendingPathComponent("content")
        }
    }

    private func makeManager(
        sideloadedIdentifiers: Set<String> = []
    ) -> BookFileManager {
        BookFileManager(
            bookRegistry: registry,
            accountScope: AccountsManagerDownloadContextAdapter(accountsManager: accountsManager),
            fileManager: .default,
            directoryProvider: Self.echoingDirectoryProvider(),
            sideloadedIdentifiersProvider: { sideloadedIdentifiers }
        )
    }

    /// The account-directory component embedded in a resolved file URL. The
    /// echoing provider lays out `<root>/<account>/content/<hash>.<ext>`, so the
    /// account is the grandparent directory of the file.
    private func resolvedAccount(in url: URL) -> String {
        url.deletingLastPathComponent()        // .../<account>/content
            .deletingLastPathComponent()        // .../<account>
            .lastPathComponent
    }

    // MARK: - 1. File path follows the CURRENT account

    /// The `fileUrl(for:)` convenience resolves under `currentAccountId`; a
    /// hard-coded or constant account would resolve under the wrong directory.
    func testFileUrlConvenience_resolvesUnderCurrentAccount() throws {
        let book = TPPBookMocker.mockBook(identifier: "scope-current-1", title: "Title scope-current-1")
        registry.addBook(book, state: .downloadSuccessful)
        let sut = makeManager()

        let url = try XCTUnwrap(sut.fileUrl(for: "scope-current-1"),
                                "Convenience overload must resolve a URL for a registered book under the current account")
        XCTAssertEqual(resolvedAccount(in: url), accountA,
                       "fileUrl(for:) must resolve under the CURRENT account (A) — this is the currentAccountId read Wave 3 inverts")
    }

    /// Switching the current library (A → B) re-points the SAME book's download
    /// file to B's per-account directory. Two libraries never share a download
    /// path. Capturing the account once would keep resolving under A.
    func testFileUrlConvenience_followsAccountSwitch_AtoB() throws {
        let book = TPPBookMocker.mockBook(identifier: "scope-switch-1", title: "Title scope-switch-1")
        registry.addBook(book, state: .downloadSuccessful)
        let sut = makeManager()

        let urlUnderA = try XCTUnwrap(sut.fileUrl(for: "scope-switch-1"))
        XCTAssertEqual(resolvedAccount(in: urlUnderA), accountA)

        // Simulate a library switch by advancing the same key the setter writes.
        defaults.set(accountB, forKey: currentAccountIdentifierKey)

        let urlUnderB = try XCTUnwrap(sut.fileUrl(for: "scope-switch-1"))
        XCTAssertEqual(resolvedAccount(in: urlUnderB), accountB,
                       "After the current library flips A→B, the SAME book must resolve under B's directory — downloads follow the current account")
        XCTAssertNotEqual(urlUnderA, urlUnderB,
                          "A and B must yield DISTINCT download paths — per-account isolation, no cross-library co-mingling")
        // File stem (hashed identifier) is account-independent; only the
        // account directory differs.
        XCTAssertEqual(urlUnderA.lastPathComponent, urlUnderB.lastPathComponent,
                       "Only the per-account directory changes across a switch — the hashed file name is stable")
    }

    // MARK: - 2. Sideloaded content is pinned to the fixed sideload account

    /// The isolation EXCEPTION: a registered sideloaded id resolves under the
    /// fixed `sideloadContentAccountID`, NOT the current account — so a library
    /// switch can't orphan its file. Pins BookFileManager.swift:92–96.
    ///
    /// Kill cases:
    ///  - Dropping the sideload override → the file resolves under the current
    ///    account (A) and is orphaned when the user switches libraries.
    ///  - Dropping the membership check → a normal id that merely carries the
    ///    prefix would be mis-pinned (covered by the negative test below).
    func testSideloadedBook_pinsToFixedSideloadAccount_ignoringCurrentAccount() throws {
        let sideloadId = "sideload-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: sideloadId, title: "Title \(sideloadId)")
        registry.addBook(book, state: .downloadSuccessful)
        // Current library is A, but the book is a registered sideloaded id.
        let sut = makeManager(sideloadedIdentifiers: [sideloadId])

        let url = try XCTUnwrap(sut.fileUrl(for: sideloadId))
        XCTAssertEqual(resolvedAccount(in: url), SideloadedBookRegistry.sideloadContentAccountID,
                       "A registered sideloaded id must resolve under the FIXED sideload account, ignoring current account A — a library switch must not orphan it")
        XCTAssertNotEqual(resolvedAccount(in: url), accountA,
                          "Sideloaded content must NOT be scoped to the current library")
    }

    /// Sideloaded content stays pinned to the fixed account even AFTER a library
    /// switch — the property that makes sideloaded books readable across any
    /// current library.
    func testSideloadedBook_staysPinned_acrossAccountSwitch() throws {
        let sideloadId = "sideload-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: sideloadId, title: "Title \(sideloadId)")
        registry.addBook(book, state: .downloadSuccessful)
        let sut = makeManager(sideloadedIdentifiers: [sideloadId])

        let underA = try XCTUnwrap(sut.fileUrl(for: sideloadId))
        defaults.set(accountB, forKey: currentAccountIdentifierKey)
        let underB = try XCTUnwrap(sut.fileUrl(for: sideloadId))

        XCTAssertEqual(underA, underB,
                       "A sideloaded book's file path must be identical before and after a library switch — pinned to the fixed sideload account")
        XCTAssertEqual(resolvedAccount(in: underB), SideloadedBookRegistry.sideloadContentAccountID)
    }

    /// Negative boundary: a `sideload-`-prefixed id that is NOT in the
    /// sideloaded set must fall through to normal per-account scoping (the
    /// membership check is defense-in-depth, BookFileManager.swift:92–93).
    /// Guards against scoping on the prefix alone.
    func testPrefixedButUnregistered_fallsBackToCurrentAccount() throws {
        let notReallySideloaded = "sideload-not-registered-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: notReallySideloaded, title: "Title \(notReallySideloaded)")
        registry.addBook(book, state: .downloadSuccessful)
        // Empty sideloaded set → the prefix alone must NOT trigger the override.
        let sut = makeManager(sideloadedIdentifiers: [])

        let url = try XCTUnwrap(sut.fileUrl(for: notReallySideloaded))
        XCTAssertEqual(resolvedAccount(in: url), accountA,
                       "A prefixed id absent from the sideloaded set must scope to the CURRENT account — the override requires BOTH prefix AND membership")
    }
}

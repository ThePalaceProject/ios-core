//
//  BookFileManagerAccountScopingTests.swift
//  PalaceTests
//
//  PRE-WAVE CHARACTERIZATION PACK — god-class decomposition Wave 3, the
//  mutually-coupled hub pair Accounts ↔ Downloads
//  (docs/architecture/god-class-decomposition-plan.md §3a-2/§3a-3, §4 Wave 3).
//
//  WHAT THIS PINS
//  ==============
//  The Downloads→Accounts READ edge for per-account download-file isolation.
//  `BookFileManager` (extracted from MyBooksDownloadCenter; owns the on-disk
//  geometry for downloaded books) resolves a book's file URL under the CURRENT
//  library by reading `accountsManager.currentAccountId`:
//
//      func fileUrl(for identifier: String) -> URL? {
//          fileUrl(for: identifier, account: accountsManager.currentAccountId)  // BookFileManager.swift:67
//      }
//
//  Wave 3 moves `BookFileManager` into **PalaceDownloads**, which must NOT know
//  `AccountsManager` (the whole point of the hub split). The dependency has to
//  invert to an injected account-scope provider (`AccountScopeProviding`
//  `currentAccountID`, per §3b-1 / §2.3) rather than the concrete
//  `AccountsManager`. These tests pin the CURRENT behavior the inversion must
//  reproduce byte-for-byte:
//
//    1. The resolved download-file directory FOLLOWS the current account — flip
//       `currentAccountId` A→B and the same book resolves to a different
//       per-account directory. (Two accounts never co-mingle their downloads.)
//    2. The sideloaded-content ISOLATION EXCEPTION: a `sideload-`-prefixed id
//       whose identifier is in the sideloaded set resolves under the FIXED
//       `SideloadedBookRegistry.sideloadContentAccountID`, IGNORING the current
//       account — so a library switch cannot orphan a sideloaded book's file
//       (BookFileManager.swift:92–96, sideloading-plan.md R6).
//
//  Existing `BookFileManagerTests` only exercises the EXPLICIT-account overloads
//  (`fileUrl(for:account:)`) — it never drives the `currentAccountId`-reading
//  convenience nor the sideload override. Those two coupling seams are the
//  genuinely-unpinned surface this file adds; there is no overlap.
//
//  DETERMINISM / ISOLATION: `currentAccountId` is controlled purely through an
//  isolated `UserDefaults` suite seeded at `currentAccountIdentifierKey` (the
//  same key the setter writes) — NO heavy `currentAccount` setter is driven, so
//  no static singletons (`ImageCache.shared`, network executor) are touched. A
//  `directoryProvider` closure maps account → a temp URL that embeds the account
//  string, so the account the path resolved under is directly observable without
//  a real Application Support directory. No network, no keychain, no sleeps.
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

    /// The `fileUrl(for:)` convenience resolves under `currentAccountId`. Pins the
    /// Downloads→Accounts read that Wave 3 inverts to an injected scope provider.
    ///
    /// Kill case: a mutant that hard-codes the account or reads a fixed string
    /// instead of `accountsManager.currentAccountId` would resolve under the
    /// wrong (or a constant) directory.
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
    /// path. Pins the per-account isolation the extraction must preserve.
    ///
    /// Kill case: a mutant that captures the account once (or ignores
    /// currentAccountId) would keep resolving under A after the switch.
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
    /// Guards against a mutant that pins on the prefix alone.
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

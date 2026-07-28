//
//  MyBooksDownloadCenterAccountScopeSeamTests.swift
//  PalaceTests
//
//  Wave 3 S2b — proves `MyBooksDownloadCenter` resolves account SCOPE through
//  the injected `DownloadAccountScopeProviding` seam, NOT a hardcoded
//  `AccountsManager` / `AppContainer.production()` reach.
//
//  Two behavioral pins, both driven by a spy scope so the account-SCOPE reads
//  under test resolve through the spy — no real AccountsManager, keychain, or
//  UserDefaults backs the scope path. (MBDC's OTHER init defaults still resolve
//  `AppContainer.production()` for the credential / networkExecutor / disk-budget
//  deps, which these tests do not exercise; the shared production graph is not a
//  freshly-constructed AccountsManager, so there is no isolation-lint concern.)
//
//    1. `fileUrl(for:)` value-flow — MBDC's default `BookFileManager` resolves
//       the on-disk path under the account the injected seam reports. The spy
//       returns a distinctive id; the account that reaches the file-path
//       `directoryProvider` MUST be exactly that id. A mutant that reverted the
//       retype (BookFileManager reading `AppContainer.production()`'s current
//       account) would resolve a different id here → the assertion fails.
//
//    2. `reset(account:)` seam-consultation — the account-match guard reads the
//       injected seam. The spy counts `currentAccountID` reads; both guard
//       branches (matching + non-matching id) must consult it. A mutant that
//       re-hardcoded the guard onto a concrete manager reads the spy 0 times →
//       the assertions fail. (The guarded effect is unobservable scratch state,
//       so the ==/!= flip is not killable without new production surface — see
//       the test's inline HONEST LIMITATION note.)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

/// Spy `DownloadAccountScopeProviding` — returns a controllable account id +
/// auth-surface hosts and records how many times each is read. `@unchecked
/// Sendable` (the protocol is `Sendable`): all mutable state is NSLock-guarded
/// because the production wire-up can capture it into `@Sendable` host-provider
/// closures.
private final class SpyDownloadAccountScope: DownloadAccountScopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _accountID: String?
    private var _hosts: Set<String>
    private var _accountIDReads = 0
    private var _hostsReads = 0

    init(accountID: String?, hosts: Set<String> = []) {
        self._accountID = accountID
        self._hosts = hosts
    }

    var currentAccountID: String? {
        lock.withLock { _accountIDReads += 1; return _accountID }
    }

    var currentAccountAuthSurfaceHosts: Set<String> {
        lock.withLock { _hostsReads += 1; return _hosts }
    }

    var accountIDReadCount: Int { lock.withLock { _accountIDReads } }
    var hostsReadCount: Int { lock.withLock { _hostsReads } }

    func setAccountID(_ id: String?) { lock.withLock { _accountID = id } }
}

@MainActor
final class MyBooksDownloadCenterAccountScopeSeamTests: XCTestCase {

    private var registry: TPPBookRegistryMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
    }

    override func tearDownWithError() throws {
        registry = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. fileUrl value-flow through the injected seam

    /// The injected scope's `currentAccountID` must be the account under which
    /// MBDC's file-path resolution happens. We record the account string that
    /// reaches the `directoryProvider` — the single choke point every
    /// `fileUrl(for:)` overload funnels through — and assert it equals the spy's
    /// id. This proves MBDC's default `BookFileManager` reads the injected seam,
    /// not `AppContainer.production().accountsManager`.
    func testFileUrl_resolvesPathUnderAccountFromInjectedScopeSeam() throws {
        let seamAccountID = "seam-lib-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: seamAccountID)

        let recordedAccount = LockedBox<String?>(nil)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountScopeSeamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: spy,
            directoryProvider: { account in
                recordedAccount.value = account
                return tempDir
            }
        )

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        let url = center.fileUrl(for: book.identifier)

        XCTAssertNotNil(url,
            "fileUrl must resolve a URL when the registry has the book and the directory provider returns a directory")
        XCTAssertEqual(recordedAccount.value, seamAccountID,
            "MBDC must resolve the download-file path under the account the INJECTED scope seam reports — not a hardcoded AccountsManager / AppContainer.production() read")
        XCTAssertGreaterThan(spy.accountIDReadCount, 0,
            "fileUrl(for:) must consult the injected DownloadAccountScopeProviding.currentAccountID")
    }

    /// A second id proves the read is live, not a coincidence: flip the seam and
    /// the resolved account flips with it. Kills a mutant that captured the id
    /// once at init instead of reading the seam per call.
    func testFileUrl_tracksInjectedScopeSeamAcrossAccountChange() throws {
        let firstID = "seam-first-\(UUID().uuidString)"
        let secondID = "seam-second-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: firstID)

        let recordedAccount = LockedBox<String?>(nil)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountScopeSeamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: spy,
            directoryProvider: { account in
                recordedAccount.value = account
                return tempDir
            }
        )

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        _ = center.fileUrl(for: book.identifier)
        XCTAssertEqual(recordedAccount.value, firstID)

        spy.setAccountID(secondID)
        _ = center.fileUrl(for: book.identifier)
        XCTAssertEqual(recordedAccount.value, secondID,
            "the file-path account must follow the injected seam's current value on each read — proving a live seam read, not an init-time capture")
    }

    // MARK: - 2. reset(account:) consults the injected seam

    /// `reset(account:)`'s account-match guard compares the argument against the
    /// injected scope seam's `currentAccountID`. This test drives BOTH sides of
    /// that guard — a MATCHING id (guard true) and a NON-matching id (guard
    /// false) — and asserts the seam is the operand consulted in each case.
    ///
    /// A mutant that re-hardcoded the guard onto a concrete
    /// `AccountsManager.currentAccountId` reads the spy 0 times → both assertions
    /// fail. Exercising both branches also pins that the argument actually flows
    /// into a comparison against the seam value (not ignored).
    ///
    /// HONEST LIMITATION — the `==` → `!=` mutant is NOT killed here. The guard's
    /// only effect is clearing `bookIdentifierOfBookToRemove`, which in the
    /// current tree is write-only scratch state: it is never assigned a non-nil
    /// value and never read back through any public/internal surface (verified by
    /// a whole-tree grep). There is therefore NO observable behavioral difference
    /// between the guard being true and false. Per the S2b review constraint we do
    /// NOT add a test-only `_forTesting` getter to production just to observe it;
    /// the seam-consultation + both-branches pin is the strongest assertion the
    /// existing surface allows. When the remove-from-device confirmation flow that
    /// reads this scratch state is (re)wired, this test should be upgraded to
    /// assert the cleared/retained effect and kill the ==/!= mutant.
    func testResetAccount_consultsInjectedScopeSeamOnBothGuardBranches() {
        // Guard-true branch: reset argument MATCHES the seam's current id.
        let matchingID = "current-lib-\(UUID().uuidString)"
        let matchSpy = SpyDownloadAccountScope(accountID: matchingID)
        let matchCenter = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: matchSpy
        )
        let matchBefore = matchSpy.accountIDReadCount
        matchCenter.reset(account: matchingID)
        XCTAssertGreaterThan(matchSpy.accountIDReadCount, matchBefore,
            "reset(account:) with a MATCHING id must read the injected seam's currentAccountID for its guard, not a hardcoded AccountsManager")

        // Guard-false branch: reset argument does NOT match the seam's current id.
        let nonMatchSpy = SpyDownloadAccountScope(accountID: "current-lib-\(UUID().uuidString)")
        let nonMatchCenter = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: nonMatchSpy
        )
        let nonMatchBefore = nonMatchSpy.accountIDReadCount
        nonMatchCenter.reset(account: "some-other-lib-\(UUID().uuidString)")
        XCTAssertGreaterThan(nonMatchSpy.accountIDReadCount, nonMatchBefore,
            "reset(account:) with a NON-matching id must still read the injected seam's currentAccountID to evaluate its guard")
    }
}

/// Minimal thread-safe box so the `@escaping` directory-provider closure (which
/// is not `@Sendable` here but is called synchronously on the main actor) can
/// hand a captured value back to the test without a `var` capture warning under
/// Swift 6.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

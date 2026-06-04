//
//  LibrariesSectionViewModelTests.swift
//  PalaceTests
//
//  Covers the inline Settings → MY LIBRARIES section view model (PP-917):
//  sorted ordering, stale-uuid filter + persistence, current-library
//  deletion guard, secondary-library deletion + FCM token cleanup, and
//  the add-library sheet trigger.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class LibrariesSectionViewModelTests: XCTestCase {

    private func makeAccount(uuid: String, name: String) -> Account {
        let publication = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/\(uuid)/catalog", rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: uuid, title: name),
            images: nil
        )
        return Account(publication: publication, imageCache: MockImageCache())
    }

    // MARK: - refresh()

    func test_refresh_putsCurrentAccountFirstAndSortsOthersByName() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let zebra = makeAccount(uuid: "zebra", name: "Zebra Library")
        let alpha = makeAccount(uuid: "alpha", name: "Alpha Library")
        let mid = makeAccount(uuid: "mid", name: "main street")

        let env = FakeLibrariesEnvironment(
            currentUUID: bookshelf.uuid,
            persisted: [zebra, alpha, mid, bookshelf]
        )
        env.lookupResponses = [
            bookshelf.uuid: bookshelf, zebra.uuid: zebra, alpha.uuid: alpha, mid.uuid: mid
        ]

        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["bookshelf", "alpha", "mid", "zebra"],
                       "Current account first; remaining sorted case-insensitively by name (Alpha < main street < Zebra).")
        XCTAssertEqual(sut.currentAccountUUID, "bookshelf")
    }

    func test_refresh_filtersUUIDsNotInRegistry_andPersistsCleanedList() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let ghost = makeAccount(uuid: "ghost", name: "Ghost Library")
        let kept = makeAccount(uuid: "kept", name: "Kept Library")

        let env = FakeLibrariesEnvironment(
            currentUUID: bookshelf.uuid,
            persisted: [bookshelf, ghost, kept]
        )
        // ghost does NOT resolve via lookup — it's stale.
        env.lookupResponses = [bookshelf.uuid: bookshelf, kept.uuid: kept]

        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["bookshelf", "kept"])
        XCTAssertEqual(env.persistedIds, ["bookshelf", "kept"],
                       "Cleaned list must be persisted so the next launch doesn't re-load the ghost UUID.")
    }

    func test_refresh_doesNotPersist_whenNoStaleUUIDs() {
        let a = makeAccount(uuid: "a", name: "A")
        let b = makeAccount(uuid: "b", name: "B")
        let env = FakeLibrariesEnvironment(currentUUID: a.uuid, persisted: [a, b])
        env.lookupResponses = [a.uuid: a, b.uuid: b]

        _ = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        XCTAssertNil(env.persistedIds, "No churn → no UserDefaults write.")
    }

    func test_refresh_withNoCurrentAccount_sortsAllAlphabetically() {
        let zebra = makeAccount(uuid: "zebra", name: "Zebra")
        let alpha = makeAccount(uuid: "alpha", name: "Alpha")
        let env = FakeLibrariesEnvironment(currentUUID: nil, persisted: [zebra, alpha])
        env.lookupResponses = [zebra.uuid: zebra, alpha.uuid: alpha]

        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["alpha", "zebra"])
        XCTAssertNil(sut.currentAccountUUID)
    }

    // MARK: - deleteSecondary

    func test_deleteSecondary_callsTokenDeleter_andRemovesAccount_andPersists() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let toDelete = makeAccount(uuid: "to_delete", name: "To Delete")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf, toDelete])
        env.lookupResponses = [bookshelf.uuid: bookshelf, toDelete.uuid: toDelete]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)
        env.persistedIds = nil // reset after the initial refresh churn

        sut.deleteSecondary(toDelete)

        XCTAssertEqual(env.tokensDeleted, ["to_delete"],
                       "deleteToken(for:) must be called BEFORE the account is dropped — otherwise the FCM endpoint is unknowable.")
        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["bookshelf"])
        XCTAssertEqual(env.persistedIds, ["bookshelf"])
    }

    func test_deleteSecondary_noOpsOnCurrentAccount() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let other = makeAccount(uuid: "other", name: "Other")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf, other])
        env.lookupResponses = [bookshelf.uuid: bookshelf, other.uuid: other]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)
        env.persistedIds = nil
        env.tokensDeleted = []

        sut.deleteSecondary(bookshelf)

        XCTAssertEqual(env.tokensDeleted, [], "Active library must not have its FCM token deleted via swipe.")
        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["bookshelf", "other"],
                       "Active library row stays even if the user somehow triggers delete on it.")
        XCTAssertNil(env.persistedIds, "No churn → no UserDefaults write.")
    }

    // MARK: - switchToAccount

    func test_switchToAccount_callsEnvironment_andUpdatesCurrentUUID_andResortsAccounts() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let other = makeAccount(uuid: "other", name: "Other Library")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf, other])
        env.lookupResponses = [bookshelf.uuid: bookshelf, other.uuid: other]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)
        XCTAssertEqual(sut.accounts.first?.uuid, "bookshelf", "Sanity: bookshelf starts on top.")

        sut.switchToAccount(other)

        XCTAssertEqual(env.switchedTo, ["other"], "Environment switch must be invoked.")
        XCTAssertEqual(sut.currentAccountUUID, "other", "View model updates currentAccountUUID optimistically.")
        XCTAssertEqual(sut.accounts.first?.uuid, "other",
                       "After switch the new active library must be the first row so the checkmark moves immediately.")
        XCTAssertTrue(sut.isSwitching,
                      "isSwitching stays true until the environment fires its completion (drives the loading overlay).")
    }

    func test_switchToAccount_firesCompletion_andClearsIsSwitching_whenEnvironmentReportsReady() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let other = makeAccount(uuid: "other", name: "Other Library")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf, other])
        env.lookupResponses = [bookshelf.uuid: bookshelf, other.uuid: other]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        let exp = expectation(description: "switch completion fires once auth doc reports ready")
        sut.switchToAccount(other) { exp.fulfill() }

        XCTAssertTrue(sut.isSwitching, "Overlay drives off this flag while we wait for the env callback.")
        env.fireSwitchCompletion(for: "other")
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(sut.isSwitching, "Overlay must come down once the auth doc finishes.")
    }

    /// The add-library path: TPPSettingsView's sheet callback hands a
    /// freshly picked account straight to `switchToAccount` — the account
    /// is NOT yet in `accounts`. The optimistic resort must insert it as
    /// the first row, and the completion (which the view uses to jump to
    /// the Catalog tab) must still fire when the environment reports ready.
    func test_switchToAccount_newlyAddedAccount_insertsItFirst_andFiresCompletion() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let added = makeAccount(uuid: "added", name: "Freshly Added Library")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf])
        env.lookupResponses = [bookshelf.uuid: bookshelf]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)
        XCTAssertEqual(sut.accounts.map { $0.uuid }, ["bookshelf"], "Sanity: added isn't in the list yet.")

        let exp = expectation(description: "completion fires so the view can jump to the Catalog tab")
        sut.switchToAccount(added) { exp.fulfill() }

        XCTAssertEqual(env.switchedTo, ["added"], "Environment switch chain must run for the new account.")
        XCTAssertEqual(sut.accounts.first?.uuid, "added",
                       "Account absent from the list must be inserted as the first (active) row.")
        XCTAssertEqual(sut.currentAccountUUID, "added")
        XCTAssertTrue(sut.isSwitching)

        env.fireSwitchCompletion(for: "added")
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(sut.isSwitching)
    }

    func test_switchToAccount_isNoOpForCurrentAccount() {
        let bookshelf = makeAccount(uuid: "bookshelf", name: "Palace Bookshelf")
        let env = FakeLibrariesEnvironment(currentUUID: bookshelf.uuid, persisted: [bookshelf])
        env.lookupResponses = [bookshelf.uuid: bookshelf]
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        let exp = expectation(description: "completion still fires synchronously for the no-op path")
        sut.switchToAccount(bookshelf) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(env.switchedTo, [],
                       "Already-active library must not re-fire the switch chain (saves a redundant currentAccount didSet).")
        XCTAssertFalse(sut.isSwitching, "Skipping the work should also skip the overlay state.")
    }

    // MARK: - presentAddLibrary

    func test_presentAddLibrary_flipsSheetBool() {
        let env = FakeLibrariesEnvironment(currentUUID: nil, persisted: [])
        let sut = LibrariesSectionViewModel(environment: env, observeNotifications: false)

        XCTAssertFalse(sut.showAddLibrarySheet)
        sut.presentAddLibrary()
        XCTAssertTrue(sut.showAddLibrarySheet)
    }
}

// MARK: - Fake environment

@MainActor
private final class FakeLibrariesEnvironment: LibrariesSectionEnvironment {
    var currentUUID: String?
    var persisted: [Account]
    var lookupResponses: [String: Account] = [:]
    var persistedIds: [String]?
    var tokensDeleted: [String] = []
    var switchedTo: [String] = []
    private var pendingSwitchCompletions: [String: () -> Void] = [:]

    init(currentUUID: String?, persisted: [Account]) {
        self.currentUUID = currentUUID
        self.persisted = persisted
    }

    nonisolated func currentAccountUUID() -> String? {
        MainActor.assumeIsolated { self.currentUUID }
    }
    nonisolated func loadPersistedAccounts() -> [Account] {
        MainActor.assumeIsolated { self.persisted }
    }
    nonisolated func lookupAccount(_ uuid: String) -> Account? {
        MainActor.assumeIsolated { self.lookupResponses[uuid] }
    }
    nonisolated func persistAccountIds(_ ids: [String]) {
        MainActor.assumeIsolated { self.persistedIds = ids }
    }
    nonisolated func deleteToken(for account: Account) {
        MainActor.assumeIsolated { self.tokensDeleted.append(account.uuid) }
    }
    nonisolated func switchToAccount(_ account: Account, completion: @escaping () -> Void) {
        MainActor.assumeIsolated {
            self.switchedTo.append(account.uuid)
            self.currentUUID = account.uuid
            // Park the completion so tests can simulate the async auth-doc
            // callback at a deterministic point.
            self.pendingSwitchCompletions[account.uuid] = completion
        }
    }

    func fireSwitchCompletion(for uuid: String) {
        pendingSwitchCompletions.removeValue(forKey: uuid)?()
    }
}

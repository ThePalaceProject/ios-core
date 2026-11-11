//
//  AppContainerServiceLifetimeTests.swift
//  PalaceTests
//
//  Two test containers must not reach each other's services or the production
//  graph's (PP-5545). Each test builds two containers and drives one of them.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AppContainerServiceLifetimeTests: XCTestCase {

    /// Account UUIDs a test drove through `AccountStateStore.shared`, cleared
    /// after each test so their load states do not reach the next one.
    private var touchedAccountUUIDs: [String] = []

    override func tearDown() {
        touchedAccountUUIDs.forEach { AccountStateStore.shared.reset(for: $0) }
        touchedAccountUUIDs = []
        super.tearDown()
    }

    // MARK: - Account switch

    /// A library switch on container A pops A's navigation stacks and cancels
    /// A's requests only. B's and the production app's stay as they were.
    func testAccountSwitch_OnContainerA_CleansUpOnlyItsOwnServices() async {
        let executorA = CancelCountingExecutor(cachingStrategy: .ephemeral)
        let executorB = CancelCountingExecutor(cachingStrategy: .ephemeral)
        let containerA = makeTestAppContainer(bookRegistry: TPPBookRegistryMock(), networkExecutor: executorA)
        let containerB = makeTestAppContainer(bookRegistry: TPPBookRegistryMock(), networkExecutor: executorB)

        let stackA = Self.registerStack(in: containerA.navigationCoordinatorHub, bookID: "a-book")
        let stackB = Self.registerStack(in: containerB.navigationCoordinatorHub, bookID: "b-book")
        let productionHub = AppContainer.production().navigationCoordinatorHub // MIGRATED-DEFERRED: the app's own hub is what the switch must leave alone.
        let productionStack = Self.registerStack(in: productionHub, bookID: "production-book")

        let priorUUID = "urn:uuid:lifetime-prior-\(UUID().uuidString)"
        let nextUUID = "urn:uuid:lifetime-next-\(UUID().uuidString)"
        touchedAccountUUIDs = [priorUUID, nextUUID]
        let cleanup = containerA.accountsManager._seedAccountForTesting(Self.makeAccount(uuid: priorUUID))
        defer { cleanup() }

        containerA.accountsManager.currentAccount = Self.makeAccount(uuid: nextUUID)

        // The switch flag clears only after the pop-to-root hop has run, so it is
        // the barrier for the negative assertions below.
        XCTAssertTrue(containerA.accountsManager.isAccountSwitching,
                      "Setup: A→B must be a real switch, or the barrier below passes at once")
        await awaitConditionAsync { !containerA.accountsManager.isAccountSwitching }

        XCTAssertEqual(stackA.path.count, 0, "The switch must clear the stacks of the container that switched")
        XCTAssertEqual(stackB.path.count, 1, "Another container's stacks must keep their content")
        XCTAssertEqual(productionStack.path.count, 1, "The production app's stacks must keep their content")
        XCTAssertEqual(executorA.cancelCount, 1, "The switch must cancel the requests of the container that switched")
        XCTAssertEqual(executorB.cancelCount, 0, "Another container's requests must keep running")
    }

    // MARK: - Sign-in presentation

    /// B's download center asks for credentials through B's sign-in presenter,
    /// not the production one, when a download needs a sign-in.
    func testDownloadNeedingSignIn_PresentsThroughItsOwnContainersPresenter() async {
        let userAccount = TPPUserAccountMock()
        userAccount.authDefinition = TPPLibraryAccountMock().basicAuthentication
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)

        let containerB = makeTestAppContainer(bookRegistry: registry, userAccount: userAccount)
        var presentedLibraries: [String] = []
        let spy = SignInModalSheetPresenter(
            appContainer: containerB,
            currentAccountIDProvider: { "lifetime-library-b" },
            needsAuthProvider: { _ in true },
            driver: { libraryID, _, completion in
                presentedLibraries.append(libraryID)
                completion()
            }
        )
        let spied = containerB.withSignInModalSheetPresenter(spy)

        await spied.downloadCenter.startDownloadAsync(for: book)
        await awaitConditionAsync { !presentedLibraries.isEmpty }

        XCTAssertEqual(presentedLibraries, ["lifetime-library-b"],
                       "The sign-in sheet must come from the container that owns the download center")
    }

    // MARK: - Settings

    /// A setting written through one container is not visible through another.
    func testSettings_WrittenThroughContainerA_AreNotVisibleThroughContainerB() {
        let containerA = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let containerB = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let original = containerA.settings.appRatingSessionCount
        defer { containerA.settings.appRatingSessionCount = original }
        let written = containerB.settings.appRatingSessionCount + 41

        containerA.settings.appRatingSessionCount = written

        XCTAssertEqual(containerA.settings.appRatingSessionCount, written)
        XCTAssertNotEqual(containerB.settings.appRatingSessionCount, written,
                          "Each container's settings must have their own store")
    }

    // MARK: - Helpers

    private static func registerStack(in hub: NavigationCoordinatorHub, bookID: String) -> NavigationCoordinator {
        let coordinator = NavigationCoordinator()
        hub.register(coordinator, for: nil)
        coordinator.push(.bookDetail(BookRoute(id: bookID)))
        return coordinator
    }

    /// Link-less publication, so the switch drives no network fetch.
    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(updated: Date(), description: "lifetime", id: uuid,
                                                 title: "Lifetime \(uuid.suffix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: MockImageCache())
    }
}

/// Counts account-switch cancellations instead of cancelling.
private final class CancelCountingExecutor: TPPNetworkExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelCount = 0
    var cancelCount: Int { lock.withLock { _cancelCount } }

    override func cancelNonEssentialTasks() {
        lock.withLock { _cancelCount += 1 }
    }
}

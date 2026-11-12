//
//  BookDetailInjectedDependenciesTests.swift
//  PalaceTests
//
//  The book detail screen's sign-in sheet, end-of-book prompt and rating
//  prompt go through the `BookDetailDependencies` it was built with (PP-5544).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalacePreferences
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class BookDetailInjectedDependenciesTests: XCTestCase {

    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - Sign-in sheet

    /// A gated download with no credentials opens the injected sign-in sheet
    /// and does not start the download.
    func testDidSelectDownload_whenSignInIsNeeded_presentsTheInjectedSignInSheet() async throws {
        // The gate reads the patron through the production accounts manager:
        // `TPPUserAccount.authDefinition` resolves the library there.
        let accountsManager = AppContainer.production().accountsManager  // MIGRATED-DEFERRED: TPPUserAccount.authDefinition resolves its library through the production accounts manager, so the gate only sees a library seeded there.
        let fixture = try makeBasicAuthLibrary()
        let cleanup = accountsManager._seedAccountForTesting(fixture)
        defer { cleanup() }
        XCTAssertFalse(accountsManager.currentUserAccount.hasCredentials(),
                       "precondition: the seeded library has no stored credentials")

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = TPPBookRegistryMock()
        registry.addBook(book, location: nil, state: .downloadNeeded,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let signInSheet = SignInModalSheetPresenterSpy()
        let vm = BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in nil },
            relatedBooksFetcher: { _ in throw URLError(.notConnectedToInternet) },
            dependencies: .testDouble(signInPresenter: signInSheet)
        )
        var started = 0
        vm.downloadStarter = { _ in started += 1 }

        vm.didSelectDownload(for: book)
        await drainMainQueueAsync()

        XCTAssertEqual(signInSheet.presentForCurrentAccountCount, 1)
        XCTAssertEqual(started, 0, "the download waits for sign-in")
    }

    // MARK: - End of book

    /// Choosing Return pops the injected navigation stack and notes the
    /// finished book on the injected rating prompt.
    func testEndOfBookChoice_return_popsInjectedStackAndNotesCompletion() async {
        let coordinator = NavigationCoordinator()
        let hub = NavigationCoordinatorHub(tabRouterHub: nil)
        hub.register(coordinator, for: .myBooks)
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
        let completion = BookCompletionSpy()

        let handle = BookDetailViewModel.endOfBookChoiceHandler(for: book,
                                                                downloadCenter: appContainer.downloadCenter,
                                                                navigationHub: hub,
                                                                bookCompletion: completion)
        handle(true)
        await drainMainQueueAsync()

        XCTAssertEqual(coordinator.path.count, 0, "Return leaves the finished book's screen")
        XCTAssertEqual(completion.completedCount, 1)
    }

    /// Keeping the book leaves the stack alone but still counts the finish.
    func testEndOfBookChoice_keep_notesCompletionWithoutPopping() async {
        let coordinator = NavigationCoordinator()
        let hub = NavigationCoordinatorHub(tabRouterHub: nil)
        hub.register(coordinator, for: .myBooks)
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
        let completion = BookCompletionSpy()

        let handle = BookDetailViewModel.endOfBookChoiceHandler(for: book,
                                                                downloadCenter: appContainer.downloadCenter,
                                                                navigationHub: hub,
                                                                bookCompletion: completion)
        handle(false)
        await drainMainQueueAsync()

        XCTAssertEqual(coordinator.path.count, 1)
        XCTAssertEqual(completion.completedCount, 1)
    }

    /// A book with nothing to return skips the prompt and notes the finish
    /// on the injected rating prompt.
    func testPresentEndOfBookAlert_nothingToReturn_notesCompletionOnInjectedPrompt() async {
        let book = makeBookWithoutAcquisitions()
        let completion = BookCompletionSpy()

        BookDetailViewModel.presentEndOfBookAlert(for: book,
                                                  downloadCenter: appContainer.downloadCenter,
                                                  navigationHub: NavigationCoordinatorHub(tabRouterHub: nil),
                                                  bookCompletion: completion)
        await drainMainQueueAsync()

        XCTAssertEqual(completion.completedCount, 1)
    }

    // MARK: - Composition

    /// The container hands the screens its own collaborators, not new ones.
    func testContainerBundles_carryTheContainersOwnCollaborators() {
        let detail = appContainer.bookDetailDependencies

        XCTAssertTrue(detail.bookOpen.readers === appContainer.readerService)
        XCTAssertTrue(detail.bookOpen.navigationHub === appContainer.navigationCoordinatorHub)
        XCTAssertTrue(detail.bookOpen.audiobookSession() === appContainer.audiobookSession)
        XCTAssertTrue(detail.signInNetwork === appContainer.networkExecutor)
        XCTAssertTrue(detail.signInPresenter === appContainer.signInModalSheetPresenter)
        XCTAssertTrue(detail.bookCompletion === appContainer.ratingPromptPresenter)
    }

    // MARK: - Fixtures

    private func makeBasicAuthLibrary() throws -> Account {
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog", rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: "pp5544-gate-\(UUID().uuidString)", title: "Gate Fixture"),
            images: nil
        )
        let account = Account(publication: pub, imageCache: MockImageCache())
        let docURL = try XCTUnwrap(Bundle(for: TPPLibraryAccountMock.self)
            .url(forResource: "nypl_authentication_document", withExtension: "json"))
        account.authenticationDocument = try OPDS2AuthenticationDocument.fromData(try Data(contentsOf: docURL))
        let details = try XCTUnwrap(account.details)
        account._setState(.detailsLoaded(details))
        XCTAssertTrue(details.auths.first?.needsAuth == true, "precondition: the fixture library requires sign-in")
        return account
    }

    private func makeBookWithoutAcquisitions() -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: nil,
            identifier: "pp5544-no-acquisitions",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "No Acquisitions",
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

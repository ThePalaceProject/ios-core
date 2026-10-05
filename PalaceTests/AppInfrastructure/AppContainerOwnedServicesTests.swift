//
//  AppContainerOwnedServicesTests.swift
//  PalaceTests
//
//  The sign-in sheet presenter, book-cell model cache and catalog API and
//  repository belong to the container that resolved them. Pinned here: two
//  containers route effects only to their own collaborators, value copies
//  share the services, `with...` copies own fresh ones, and dropping a
//  container releases them.
//

import os
import XCTest
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class AppContainerOwnedServicesTests: PalaceWiringTestCase {

    override func setUp() {
        super.setUp()
        TaggedRecordingURLProtocol.reset()
    }

    override func tearDown() {
        TaggedRecordingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(_ identifier: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: "Owned \(identifier)", authors: "Author")
    }

    /// A container whose network executor sends every request through
    /// `protocolClass`, so a test can tell which container's session a
    /// request used.
    private func makeContainer(routingThrough protocolClass: AnyClass) -> AppContainer {
        let accountsManager = makeFreshAccountsManager()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let executor = TPPNetworkExecutor(
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: accountsManager
        )
        return makeTestAppContainer(accountsManager: accountsManager, networkExecutor: executor)
    }

    private func makeSpyPresenter(for container: AppContainer) -> SignInModalSheetPresenter {
        SignInModalSheetPresenter(
            appContainer: container,
            currentAccountIDProvider: { nil },
            needsAuthProvider: { _ in false },
            driver: { _, _, completion in completion() }
        )
    }

    // MARK: - Two containers, distinct collaborators

    /// A catalog fetch must use the resolving container's network session. A
    /// process-wide API would send container B's request through whichever
    /// container built it first.
    func testCatalogRepository_TwoContainers_FetchUsesOnlyItsOwnContainersSession() async {
        let containerA = makeContainer(routingThrough: ContainerASessionProtocol.self)
        let containerB = makeContainer(routingThrough: ContainerBSessionProtocol.self)
        let urlA = URL(string: "https://catalog.example/a/\(UUID().uuidString)")!
        let urlB = URL(string: "https://catalog.example/b/\(UUID().uuidString)")!

        _ = try? await containerA.catalogRepository.fetchFeed(at: urlA)
        _ = try? await containerB.catalogRepository.fetchFeed(at: urlB)

        XCTAssertEqual(TaggedRecordingURLProtocol.requestedURLs(tag: "A"), [urlA],
                       "Container A's catalog fetch must go through container A's session, and only its own fetch")
        XCTAssertEqual(TaggedRecordingURLProtocol.requestedURLs(tag: "B"), [urlB],
                       "Container B's catalog fetch must go through container B's session, and only its own fetch")
    }

    /// A book cell model must read the registry of the container whose cache
    /// built it. A shared cache would show container A's loan state in B.
    func testBookCellModelCache_TwoContainers_ModelReadsOnlyItsOwnContainersRegistry() {
        let registryA = TPPBookRegistryMock()
        let registryB = TPPBookRegistryMock()
        let book = makeBook("owned-cell-\(UUID().uuidString)")
        registryA.addBook(book, state: .downloadSuccessful)
        registryB.addBook(book, state: .holding)
        let containerA = makeTestAppContainer(bookRegistry: registryA)
        let containerB = makeTestAppContainer(bookRegistry: registryB)

        let modelA = containerA.bookCellModelCache.model(for: book)
        let modelB = containerB.bookCellModelCache.model(for: book)

        XCTAssertEqual(modelA.registryState, .downloadSuccessful,
                       "Container A's cell must reflect container A's registry")
        XCTAssertEqual(modelB.registryState, .holding,
                       "Container B's cell must reflect container B's registry, not A's")
    }

    /// Each container builds its own presenter; a second container must not
    /// be handed the first one's, which is wired to the first container's
    /// accounts manager.
    func testSignInPresenter_TwoContainers_EachResolvesItsOwnStableInstance() {
        let containerA = makeTestAppContainer()
        let containerB = makeTestAppContainer()

        let presenterA = containerA.signInModalSheetPresenter
        let presenterB = containerB.signInModalSheetPresenter

        XCTAssertFalse(presenterA === presenterB,
                       "Two containers must not share a sign-in presenter")
        XCTAssertTrue(containerA.signInModalSheetPresenter === presenterA,
                      "Repeated reads of one container must return the same presenter")
        XCTAssertTrue(containerB.signInModalSheetPresenter === presenterB,
                      "Repeated reads of one container must return the same presenter")
    }

    // MARK: - Value copies and overrides

    /// A plain copy is the same container: it must resolve the same services,
    /// whichever copy built them first.
    func testValueCopy_SharesOwnedServicesWithTheOriginal() {
        let original = makeTestAppContainer()
        let copy = original

        let cacheFromCopy = copy.bookCellModelCache
        let presenterFromOriginal = original.signInModalSheetPresenter

        XCTAssertTrue(original.bookCellModelCache === cacheFromCopy,
                      "A cache built through a copy must be the original's cache")
        XCTAssertTrue(copy.signInModalSheetPresenter === presenterFromOriginal,
                      "A presenter built through the original must be the copy's presenter")
        XCTAssertTrue(copy.catalogRepository as AnyObject === original.catalogRepository as AnyObject,
                      "Copies must share the catalog repository")
    }

    /// A `with...` copy is a different container: it owns fresh services built
    /// against itself, keeps every other override (chaining), and leaves the
    /// original's services alone.
    func testOverrideCopies_ChainBothOverrides_AndOwnFreshServices() {
        let original = makeTestAppContainer()
        let originalCache = original.bookCellModelCache
        let originalPresenter = original.signInModalSheetPresenter
        let signInSpy = makeSpyPresenter(for: original)
        let audiobookSpy = SpyAudiobookSessionPresenter()

        let chained = original
            .withSignInModalSheetPresenter(signInSpy)
            .withAudiobookSessionPresenter(audiobookSpy)

        XCTAssertTrue(chained.signInModalSheetPresenter === signInSpy,
                      "The first override must survive the second modifier")
        XCTAssertTrue(chained.audiobookSessionPresenter === audiobookSpy,
                      "The second override must apply")
        XCTAssertFalse(chained.bookCellModelCache === originalCache,
                       "An override copy must own its own book cell cache")
        XCTAssertTrue(original.bookCellModelCache === originalCache,
                      "Building the copy's services must not replace the original's")
        XCTAssertTrue(original.signInModalSheetPresenter === originalPresenter,
                      "The original keeps its own presenter after an override copy is made")
    }

    /// Without a sign-in override, an override copy builds a presenter of its
    /// own rather than reusing the original's, which was built against the
    /// original container and its overrides.
    func testOverrideCopy_WithoutSignInOverride_BuildsItsOwnPresenter() {
        let original = makeTestAppContainer()
        let originalPresenter = original.signInModalSheetPresenter

        let copy = original.withAudiobookSessionPresenter(SpyAudiobookSessionPresenter())

        XCTAssertFalse(copy.signInModalSheetPresenter === originalPresenter,
                       "An override copy must not resolve the original's presenter")
        XCTAssertTrue(copy.signInModalSheetPresenter === copy.signInModalSheetPresenter,
                      "The copy's presenter must be stable across reads")
    }

    // MARK: - Lifetime

    /// Dropping the last copy of a container releases what it owns, including
    /// the presenter, which holds a container of its own. The cache's deinit
    /// is what cancels its periodic cleanup task.
    func testDroppingContainer_ReleasesOwnedServices() {
        weak var presenter: SignInModalSheetPresenter?
        weak var cache: BookCellModelCache?
        weak var repository: AnyObject?

        autoreleasepool {
            let container = makeTestAppContainer()
            presenter = container.signInModalSheetPresenter
            cache = container.bookCellModelCache
            repository = container.catalogRepository as AnyObject
            XCTAssertNotNil(presenter)
            XCTAssertNotNil(cache)
            XCTAssertNotNil(repository)
        }

        XCTAssertNil(presenter, "The presenter must not outlive its container")
        XCTAssertNil(cache, "The book cell cache must not outlive its container")
        XCTAssertNil(repository, "The catalog repository must not outlive its container")
    }

    /// The presenter holds a non-owning copy of its container. While the owner
    /// is alive that copy resolves the owner's services; after the owner is
    /// gone it still resolves working services instead of failing.
    func testNonOwningCopy_ResolvesOwnersServicesWhileAlive_AndFreshOnesAfter() {
        var owner: AppContainer? = makeTestAppContainer()
        let nonOwning = owner!.nonOwningCopy()
        weak var ownerCache: BookCellModelCache?

        autoreleasepool {
            ownerCache = owner!.bookCellModelCache
            XCTAssertTrue(nonOwning.bookCellModelCache === ownerCache,
                          "A non-owning copy must resolve the owner's cache while the owner is alive")
            owner = nil
        }

        XCTAssertNil(ownerCache, "A non-owning copy must not keep the owner's services alive")
        let first = nonOwning.bookCellModelCache
        let second = nonOwning.bookCellModelCache
        XCTAssertFalse(first === second,
                       "With the owner gone, each read builds a fresh, uncached service")
    }
}

// MARK: - Recording URL protocols

/// Records each request under the subclass's tag and answers 404 without
/// touching the network.
class TaggedRecordingURLProtocol: URLProtocol {
    private struct Entry: Sendable {
        let tag: String
        let url: URL
    }

    private static let entries = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    class var tag: String { "" }

    static func reset() {
        entries.withLock { $0.removeAll() }
    }

    static func requestedURLs(tag: String) -> [URL] {
        entries.withLock { $0.filter { $0.tag == tag }.map(\.url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let tag = type(of: self).tag
        Self.entries.withLock { $0.append(Entry(tag: tag, url: url)) }
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ContainerASessionProtocol: TaggedRecordingURLProtocol {
    override class var tag: String { "A" }
}

final class ContainerBSessionProtocol: TaggedRecordingURLProtocol {
    override class var tag: String { "B" }
}

//
//  BookRegistrySyncSideloadExemptionTests.swift
//  PalaceTests
//
//  Sync exemption for side-loaded books. `sync()` evicts any book NOT in the
//  loans feed and deletes its content; side-loaded books never appear there, so
//  `recordsToDelete.subtract(sideloadedIDsProvider())` is what keeps them.
//
//  Drives production `sync()` with a contrast case (EMPTY exemption evicts the
//  same book). Keychain-gated. The loans feed is in memory: a first URLProtocol
//  load waits on CFNetwork starting a default-QoS thread, up to 17.6s under TSan.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

@MainActor
final class BookRegistrySyncSideloadExemptionTests: XCTestCase {

  private let loansURLString = "https://sideload-exemption-test.example.com/loans"

  private var store: BookRegistryStore!
  private var accountsManager: AccountsManager!
  private var spyContentService: SpyLocalContentService!
  private var downloadCenter: MyBooksDownloadCenter!
  private var feedFetcher: LoansFeedFetcher!

  // MARK: - Loans feed fetcher

  /// Serves the loans fixture from memory and records the URLs sync() asked
  /// for, so a test can tell that sync() resolved the account's loans URL.
  final class LoansFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []
    private let feedXML: String

    init(feedXML: String) { self.feedXML = feedXML }

    var requestedURLs: [URL] {
      lock.lock(); defer { lock.unlock() }
      return _requestedURLs
    }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
      try await fetchFeed(from: url, resetCache: false)
    }

    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
      lock.withLock { _requestedURLs.append(url) }
      guard let xml = TPPXML.xml(withData: Data(feedXML.utf8)),
            let feed = TPPOPDSFeed(xml: xml) else {
        throw NSError(domain: "LoansFeedFetcher", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "loans fixture did not parse"])
      }
      return feed
    }
  }

  // MARK: - Spy

  /// Records the on-disk delete calls sync() makes for evicted books without
  /// touching the filesystem. `MyBooksDownloadCenter.deleteLocalContent`
  /// delegates to `localContentService`, which (unlike the extension method on
  /// the download center) is overridable — so this is the correct seam.
  final class SpyLocalContentService: LocalBookContentService {
    private(set) var deletedBookIds: [String] = []
    override func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
      deletedBookIds.append(book.identifier)
    }
    override func deleteLocalContent(for identifier: String, account: String? = nil) {
      deletedBookIds.append(identifier)
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()

    feedFetcher = LoansFeedFetcher(feedXML: Self.loansFeedXML)
    let appContainer = makeTestAppContainer()
    accountsManager = appContainer.accountsManager
    store = BookRegistryStore()
    spyContentService = SpyLocalContentService(bookRegistry: TPPBookRegistryMock())
    downloadCenter = MyBooksDownloadCenter(
      bookRegistry: TPPBookRegistryMock(),
      localContentService: spyContentService
    )
  }

  override func tearDownWithError() throws {
    feedFetcher = nil
    downloadCenter = nil
    spyContentService = nil
    store = nil
    accountsManager = nil
    try super.tearDownWithError()
  }

  // MARK: - Loans feed fixture (one entry, none of our seeded ids)

  private static let loansFeedXML = """
  <?xml version="1.0" encoding="utf-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
    <title type="text">Loans</title>
    <id>urn:test:loans</id>
    <updated>2026-07-01T00:00:00Z</updated>
    <entry>
      <title type="text">Feed Only Book</title>
      <id>feed-only-book</id>
      <updated>2026-07-01T00:00:00Z</updated>
      <link href="http://example.com/x.epub" type="application/epub+zip" rel="http://opds-spec.org/acquisition/open-access" />
    </entry>
  </feed>
  """

  // MARK: - Helpers

  private func makeBook(identifier: String, title: String) -> TPPBook {
    TPPBook(
      acquisitions: [TPPFake.genericAcquisition],
      authors: nil, categoryStrings: nil, distributor: nil,
      identifier: identifier,
      imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
      subtitle: nil, summary: nil, title: title, updated: Date(),
      annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
      relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
      revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
      contributors: nil, bookDuration: nil, imageCache: MockImageCache()
    )
  }

  private func seedStore(_ books: [(String, String)]) {
    let done = expectation(description: "seeded")
    done.expectedFulfillmentCount = books.count
    for (id, title) in books {
      store.addBook(makeBook(identifier: id, title: title), state: .downloadSuccessful) { _ in done.fulfill() }
    }
    wait(for: [done], timeout: 3.0)
    drainMainQueue()
  }

  /// Seeds a fresh-UUID fixture account as currentAccount, with an auth
  /// document whose shelf link is the stubbed loans URL, and stored
  /// credentials on the production-stack user account sync() consults.
  /// Returns the uuid and a cleanup closure (defer-call it).
  private func seedReadyCredentialedAccount() throws -> (uuid: String, cleanup: () -> Void) {
    try KeychainAvailability.skipIfUnavailable()

    let fixtureId = "sideload-exempt-\(UUID().uuidString)"
    let pub = OPDS2Publication(
      links: [OPDS2Link(href: "https://example.com/catalog", rel: "http://opds-spec.org/catalog")],
      metadata: OPDS2Publication.Metadata(id: fixtureId, title: "Sideload Exemption Fixture"),
      images: nil
    )
    let fixture = Account(publication: pub, imageCache: MockImageCache())
    let seedCleanup = accountsManager._seedAccountForTesting(fixture)

    // Auth document with a shelf link → details.loansUrl == our stubbed URL.
    let json: [String: Any] = [
      "id": "urn:uuid:\(fixtureId)",
      "title": "Sideload Exemption Fixture",
      "links": [["href": loansURLString, "rel": "http://opds-spec.org/shelf"]],
      "authentication": [[
        "type": "http://opds-spec.org/auth/basic",
        "inputs": ["login": ["keyboard": "Default"], "password": ["keyboard": "Default"]],
        "labels": ["login": "Login", "password": "Password"]
      ]],
      "features": ["enabled": [], "disabled": []]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    let details = AccountDetails(authenticationDocument: doc, uuid: fixtureId)
    accountsManager.currentAccount?._setState(.detailsLoaded(details))

    // Credentials on the instance sync() reads via sharedAccount → production.
    let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: fixtureId) // MIGRATED-DEFERRED: SUT BookRegistrySync.sync() reads credentials via the production shared account, so credentials must be seeded on the production user account
    prodUserAccount.setAuthToken("sideload-token", barcode: "bc", pin: "1234",
                                 expirationDate: Date().addingTimeInterval(3600))

    return (fixtureId, {
      prodUserAccount.removeAll()
      seedCleanup()
    })
  }

  private func makeSyncManager(sideloadedIDs: Set<String>) -> BookRegistrySync {
    BookRegistrySync(
      store: store,
      accountsManager: accountsManager,
      downloadCenterProvider: { [downloadCenter] in downloadCenter! },
      opdsFeedServiceProvider: { [feedFetcher] in feedFetcher! },
      sideloadedIDsProvider: { sideloadedIDs }
    )
  }

  private func runSync(_ syncManager: BookRegistrySync) {
    let exp = expectation(description: "sync completed")
    var received: [TPPBookRegistry.RegistryState] = []
    syncManager.sync(
      currentState: .loaded,
      setState: { received.append($0) },
      completion: { _, _ in exp.fulfill() }
    )
    wait(for: [exp], timeout: 10.0)
    drainMainQueue()
    XCTAssertEqual(feedFetcher.requestedURLs.map(\.absoluteString), [loansURLString],
                   "sync() must fetch the loans URL from the account's auth document, once")
    XCTAssertEqual(received.last, .synced,
                   "sync() must reach reconciliation (.synced); got \(received)")
  }

  // MARK: - Tests

  func test_sync_withSideloadedIdExempt_preservesBookAndSkipsOnDiskDelete() throws {
    let (_, cleanup) = try seedReadyCredentialedAccount()
    defer { cleanup() }

    // Two downloaded books: one side-loaded (exempt), one normal (not in feed).
    seedStore([("sideloaded-1", "Side-loaded"), ("normal-1", "Normal")])

    let syncManager = makeSyncManager(sideloadedIDs: ["sideloaded-1"])
    runSync(syncManager)

    // The side-loaded book survives with its downloaded state...
    XCTAssertEqual(store.state(for: "sideloaded-1"), .downloadSuccessful,
                   "Exempt side-loaded book must survive a loans-feed sync that omits it")
    XCTAssertFalse(spyContentService.deletedBookIds.contains("sideloaded-1"),
                   "Exempt side-loaded book's on-disk content must NOT be deleted")

    // ...while the non-exempt book in the SAME run IS evicted + deleted,
    // proving reconciliation actually ran (so the survival above is the
    // exemption at work, not a short-circuited sync).
    XCTAssertNil(store.book(forIdentifier: "normal-1"),
                 "A non-exempt downloaded book absent from the feed must be evicted")
    XCTAssertTrue(spyContentService.deletedBookIds.contains("normal-1"),
                  "The evicted normal book's on-disk content must be deleted")
  }

  func test_sync_withEmptyExemption_evictsTheSameBook_andDeletesItsContent() throws {
    // Contrast case: identical scenario, EMPTY exemption set. The "side-loaded"
    // book is now unprotected and MUST be evicted + deleted, proving the previous
    // test's survival is caused by the exemption subtract.
    let (_, cleanup) = try seedReadyCredentialedAccount()
    defer { cleanup() }

    seedStore([("sideloaded-1", "Side-loaded"), ("normal-1", "Normal")])

    let syncManager = makeSyncManager(sideloadedIDs: [])
    runSync(syncManager)

    XCTAssertNil(store.book(forIdentifier: "sideloaded-1"),
                 "With no exemption, the book absent from the feed must be evicted")
    XCTAssertTrue(spyContentService.deletedBookIds.contains("sideloaded-1"),
                  "With no exemption, the book's on-disk content must be deleted")
  }
}

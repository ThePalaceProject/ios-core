//
//  BookRegistrySyncSideloadExemptionTests.swift
//  PalaceTests
//
//  THE critical sync-exemption regression (sideloading-plan.md R1).
//
//  The main registry's server `sync()` evicts any book NOT in the loans feed
//  and deletes its on-disk content. Side-loaded books are registered
//  `.downloadSuccessful` but of course never appear in the loans feed, so
//  without the `recordsToDelete.subtract(sideloadedIDsProvider())` exemption
//  the next sync silently destroys them.
//
//  These tests drive the FULL production `sync()` path — real account
//  readiness gate, a stubbed loans-feed HTTP response, the real reconciliation
//  barrier, and a spy download center recording on-disk deletes — with a
//  mutation-grade contrast: the SAME scenario with an EMPTY exemption set must
//  evict the same book (proving the exemption, not some other guard, is what
//  saved it — so removing the `subtract` line fails the first test).
//
//  Keychain-gated (credentials must be writable for sync() to reach the feed
//  fetch) — an environment-capability guard, NOT a host-sign-in-state dodge:
//  the fixture UUID is unique so credential state is deterministic.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookRegistrySyncSideloadExemptionTests: XCTestCase {

  private let loansURLString = "https://sideload-exemption-test.example.com/loans"

  private var store: BookRegistryStore!
  private var accountsManager: AccountsManager!
  private var spyContentService: SpyLocalContentService!
  private var downloadCenter: MyBooksDownloadCenter!
  private var savedProtocolClasses: [AnyClass]!

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

    // Route the SHARED network executor (used by TPPOPDSFeed.withURL inside
    // the loans fetch) through the HTTP stub so we control the loans feed.
    savedProtocolClasses = AppContainer.testExecutorProtocolClasses
    AppContainer.testExecutorProtocolClasses = [HTTPStubURLProtocol.self, NoNetworkURLProtocol.self]
    AppContainer._rebuildCachedForTestProtocols()

    HTTPStubURLProtocol.register { [loansURLString] request in
      guard request.url?.absoluteString.contains("/loans") == true else { return nil }
      return HTTPStubURLProtocol.StubbedResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/atom+xml"],
        body: Data(Self.loansFeedXML.utf8)
      )
    }

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
    HTTPStubURLProtocol.removeAllHandlers()
    AppContainer.testExecutorProtocolClasses = savedProtocolClasses
    AppContainer._rebuildCachedForTestProtocols()
    savedProtocolClasses = nil
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
    let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: fixtureId) // MIGRATED-DEFERRED: SUT BookRegistrySync.sync() reads credentials via the production shared account, so credentials must be seeded on the production user account (swarm_495a88d9)
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
      opdsFeedServiceProvider: { OPDSFeedService() },
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
    // Mutation-grade contrast: identical scenario, EMPTY exemption set. Now the
    // "side-loaded" book is unprotected and MUST be evicted + deleted — this is
    // what proves the previous test's survival is caused by the exemption
    // subtract, and kills the "subtract removed" mutant.
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

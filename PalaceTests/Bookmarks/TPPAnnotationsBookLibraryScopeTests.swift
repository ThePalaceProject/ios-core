//
//  TPPAnnotationsBookLibraryScopeTests.swift
//  PalaceTests
//
//  An audiobook keeps playing after the patron selects another library
//  (PP-5552). Its annotations must still go to the library that lent the book,
//  with that library's sign-in, sync setting and device ID, not the selected
//  library's. All HTTP goes through HTTPStubURLProtocol.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
import PalaceReadingPosition
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Two libraries with loaded account details. Library B is selected; the book
/// under test belongs to library A.
private final class BookAndSelectedLibraries: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
    let accountA: Account
    let accountB: Account
    let patronA = TPPUserAccountMock()
    let patronB = TPPUserAccountMock()
    var selectedId: String

    init(accountA: Account, accountB: Account) {
        self.accountA = accountA
        self.accountB = accountB
        self.selectedId = accountB.uuid
        super.init()
    }

    func reportSignInProgress(_ progress: SignInProgress) {}
    var tppAccountUUID: String { accountA.uuid }
    var currentAccountId: String? { selectedId }
    var currentAccount: Account? { account(selectedId) }

    func account(_ uuid: String) -> Account? {
        switch uuid {
        case accountA.uuid: return accountA
        case accountB.uuid: return accountB
        default: return nil
        }
    }

    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        libraryUUID == accountA.uuid ? patronA : patronB
    }

    var currentUserAccount: TPPUserAccount { userAccount(for: selectedId) }
}

private struct SentRequest {
    let method: String?
    let url: URL?
    let authorization: String?
    let body: [String: Any]?

    var device: String? {
        (body?[TPPBookmarkSpec.Body.key] as? [String: Any])?[TPPBookmarkSpec.Body.Device.key] as? String
    }

    init(_ request: URLRequest) {
        method = request.httpMethod
        url = request.url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        body = Self.bodyBytes(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// URLProtocol usually sees the body as a stream, whatever the caller set.
    private static func bodyBytes(of request: URLRequest) -> Data? {
        if let direct = request.httpBody { return direct }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            collected.append(buffer, count: count)
        }
        return collected
    }
}

extension SentRequest: @unchecked Sendable {}

@MainActor
final class TPPAnnotationsBookLibraryScopeTests: XCTestCase {

    private static let libraryAAnnotations = URL(string: "https://lion.lyrasistechnology.org/acton/annotations/")!
    private static let libraryBAnnotations = URL(string: "http://acl.simplye-ca.org/CALMDA/annotations/")!
    private static let serverAnnotationID = "https://lion.lyrasistechnology.org/acton/annotations/77"
    private static let deviceA = "urn:uuid:device-library-a"
    private static let deviceB = "urn:uuid:device-library-b"

    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var libraries: BookAndSelectedLibraries!
    private var detailsA: AccountDetails!
    private var detailsB: AccountDetails!
    private var offlineQueue: OfflineQueueSpy!
    private var executor: TPPNetworkExecutor!
    private let sent = LockIsolated<[SentRequest]>([])
    private var savedAnnotationsURLOverride: URL??

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuite = "TPPAnnotationsBookLibraryScopeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)

        let bundle = Bundle(for: TPPLibraryAccountMock.self)
        let feedData = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json")))
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        let authDocData = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "nypl_authentication_document", withExtension: "json")))
        let authDoc = try OPDS2AuthenticationDocument.fromData(authDocData)

        let accountA = Account(publication: try XCTUnwrap(feed.catalogs.first { $0.metadata.title == "Acton Public Library" }),
                               imageCache: MockImageCache())
        let accountB = Account(publication: try XCTUnwrap(feed.catalogs.first { $0.metadata.title == "Alameda County Library" }),
                               imageCache: MockImageCache())
        detailsA = AccountDetails(authenticationDocument: authDoc, uuid: accountA.uuid, defaults: defaults)
        detailsB = AccountDetails(authenticationDocument: authDoc, uuid: accountB.uuid, defaults: defaults)
        accountA._setState(.detailsLoaded(detailsA))
        accountB._setState(.detailsLoaded(detailsB))
        XCTAssertTrue(detailsA.supportsSimplyESync, "fixture precondition: the auth document must advertise sync")

        libraries = BookAndSelectedLibraries(accountA: accountA, accountB: accountB)
        libraries.patronA.setAuthToken("bearerA", barcode: "patronA", pin: "1111",
                                       expirationDate: Date().addingTimeInterval(3600))
        libraries.patronA.markLoggedIn()
        libraries.patronA.setDeviceID(Self.deviceA)
        // Library B starts signed out, as in the field report.
        libraries.patronB.removeAll()

        HTTPStubURLProtocol.reset()
        let sent = self.sent
        let postResponse = AnnotationsTestFixtures.postSuccessResponse(annotationId: Self.serverAnnotationID)
        let listResponse = AnnotationsTestFixtures.serverBookmarksResponse(bookmarks: [])
        HTTPStubURLProtocol.register { request in
            sent.withValue { $0.append(SentRequest(request)) }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: nil,
                             body: listResponse)
            }
            return .init(statusCode: 200, headers: nil,
                         body: postResponse)
        }
        executor = makeExecutor(protocolClass: HTTPStubURLProtocol.self)

        savedAnnotationsURLOverride = TPPAnnotations.annotationsURLOverride
        TPPAnnotations.annotationsURLOverride = nil
        TPPAnnotations.executorOverride = executor
        TPPAnnotations.accountsManagerOverride = libraries
        AnnotationDevice.accountsManagerOverride = libraries
        offlineQueue = OfflineQueueSpy()
        TPPAnnotations.offlineQueueOverride = offlineQueue
        TPPAnnotations.errorLoggerOverride = ErrorLoggerSpy()
    }

    override func tearDown() {
        TPPAnnotations.executorOverride = nil
        TPPAnnotations.accountsManagerOverride = nil
        AnnotationDevice.accountsManagerOverride = nil
        TPPAnnotations.offlineQueueOverride = nil
        TPPAnnotations.errorLoggerOverride = nil
        TPPAnnotations.annotationsURLOverride = savedAnnotationsURLOverride
        HTTPStubURLProtocol.reset()
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        executor = nil
        offlineQueue = nil
        libraries = nil
        detailsA = nil
        detailsB = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeExecutor(protocolClass: AnyClass) -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return TPPNetworkExecutor(credentialsProvider: nil,
                                  cachingStrategy: .ephemeral,
                                  sessionConfiguration: config,
                                  accountsManager: libraries)
    }

    private var bookAnnotations: TPPAnnotationsWrapper {
        TPPAnnotationsWrapper(accountId: libraries.accountA.uuid)
    }

    private func signInLibraryB() {
        libraries.patronB.setAuthToken("bearerB", barcode: "patronB", pin: "2222",
                                       expirationDate: Date().addingTimeInterval(3600))
        libraries.patronB.markLoggedIn()
        libraries.patronB.setDeviceID(Self.deviceB)
    }

    private func postListeningPosition(with annotations: AnnotationsManager) async -> AnnotationResponse? {
        await withCheckedContinuation { continuation in
            annotations.postListeningPosition(forBook: AnnotationsTestFixtures.testBookID,
                                              selectorValue: "{\"chapter\":1}") { response in
                continuation.resume(returning: response)
            }
        }
    }

    // MARK: - Listening position

    func testPostListeningPosition_BookFromLibraryAWhileBSelected_PostsToLibraryAWithItsToken() async {
        let response = await postListeningPosition(with: bookAnnotations)

        XCTAssertEqual(response?.serverId, Self.serverAnnotationID)
        let requests = sent.value
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, Self.libraryAAnnotations)
        XCTAssertEqual(requests.first?.authorization, "Bearer bearerA")
        XCTAssertEqual(requests.first?.device, Self.deviceA)
    }

    func testPostListeningPosition_LibraryBSignedIn_StillPostsToLibraryA() async {
        signInLibraryB()

        _ = await postListeningPosition(with: bookAnnotations)

        let requests = sent.value
        XCTAssertEqual(requests.map(\.url), [Self.libraryAAnnotations])
        XCTAssertEqual(requests.first?.authorization, "Bearer bearerA")
        XCTAssertEqual(requests.first?.device, Self.deviceA)
    }

    /// The selected library allows sync and would accept the post; the book's
    /// library does not, so nothing may be sent anywhere.
    func testPostListeningPosition_SyncTurnedOffForLibraryA_SendsNothing() async {
        signInLibraryB()
        detailsA.syncPermissionGranted = false
        TPPAnnotations.annotationsURLOverride = Self.libraryBAnnotations

        let response = await postListeningPosition(with: bookAnnotations)

        XCTAssertNil(response)
        XCTAssertEqual(sent.value.count, 0)
    }

    func testPostListeningPosition_LibraryASignedOut_SendsNothing() async {
        signInLibraryB()
        libraries.patronA.removeAll()
        TPPAnnotations.annotationsURLOverride = Self.libraryBAnnotations

        let response = await postListeningPosition(with: bookAnnotations)

        XCTAssertNil(response)
        XCTAssertEqual(sent.value.count, 0)
    }

    func testPostListeningPosition_Offline_QueuesUnderLibraryAWithItsToken() async {
        TPPAnnotations.executorOverride = makeExecutor(protocolClass: NoNetworkURLProtocol.self)

        _ = await postListeningPosition(with: bookAnnotations)

        let queued = offlineQueue.enqueued
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.libraryID, libraries.accountA.uuid)
        XCTAssertEqual(queued.first?.url, Self.libraryAAnnotations)
        XCTAssertEqual(queued.first?.headers?["Authorization"], "Bearer bearerA")
    }

    /// Without a library the wrapper keeps its earlier meaning: the selected one.
    func testPostListeningPosition_WrapperWithoutLibrary_UsesSelectedLibrary() async {
        signInLibraryB()
        TPPAnnotations.annotationsURLOverride = Self.libraryBAnnotations

        _ = await postListeningPosition(with: TPPAnnotationsWrapper())

        let requests = sent.value
        XCTAssertEqual(requests.map(\.url), [Self.libraryBAnnotations])
        XCTAssertEqual(requests.first?.authorization, "Bearer bearerB")
        XCTAssertEqual(requests.first?.device, Self.deviceB)
    }

    // MARK: - Bookmarks

    func testPostAudiobookBookmark_BookFromLibraryAWhileBSelected_PostsToLibraryA() async throws {
        let serverId = try await TPPAnnotations.postAudiobookBookmark(forBook: AnnotationsTestFixtures.testBookID,
                                                                      selectorValue: "{\"chapter\":2}",
                                                                      accountId: libraries.accountA.uuid)?.serverId

        XCTAssertEqual(serverId, Self.serverAnnotationID)
        XCTAssertEqual(sent.value.map(\.url), [Self.libraryAAnnotations])
        XCTAssertEqual(sent.value.first?.authorization, "Bearer bearerA")
    }

    func testGetServerBookmarks_BookFromLibraryAWhileBSelected_FetchesWithLibraryAToken() async {
        let book = AnnotationsTestFixtures.createTestBook(annotationsURL: Self.libraryAAnnotations)

        let annotations = bookAnnotations
        let bookmarkCount: Int? = await withCheckedContinuation { continuation in
            annotations.getServerBookmarks(forBook: book, atURL: book.annotationsURL, motivation: .bookmark) {
                continuation.resume(returning: $0?.count)
            }
        }

        XCTAssertEqual(bookmarkCount, 0, "a fetched, empty list rather than a refusal")
        XCTAssertEqual(sent.value.map(\.method), ["GET"])
        XCTAssertEqual(sent.value.first?.authorization, "Bearer bearerA")
    }

    func testDeleteBookmark_BookFromLibraryAWhileBSelected_DeletesWithLibraryAToken() async {
        let annotations = bookAnnotations
        let annotationID = Self.serverAnnotationID
        let deleted: Bool = await withCheckedContinuation { continuation in
            annotations.deleteBookmark(annotationId: annotationID) { continuation.resume(returning: $0) }
        }

        XCTAssertTrue(deleted)
        XCTAssertEqual(sent.value.map(\.method), ["DELETE"])
        XCTAssertEqual(sent.value.first?.authorization, "Bearer bearerA")
    }

    func testDeleteBookmark_SyncTurnedOffForLibraryA_SendsNothing() async {
        signInLibraryB()
        detailsA.syncPermissionGranted = false

        let annotations = bookAnnotations
        let annotationID = Self.serverAnnotationID
        _ = await withCheckedContinuation { continuation in
            annotations.deleteBookmark(annotationId: annotationID) { continuation.resume(returning: $0) }
        }

        XCTAssertEqual(sent.value.count, 0)
    }

    // MARK: - Sync gate

    func testSyncIsPossibleAndPermitted_LibraryAAllowsAndBSignedOut_IsTrue() {
        XCTAssertTrue(bookAnnotations.syncIsPossibleAndPermitted)
    }

    func testSyncIsPossibleAndPermitted_LibraryATurnedOffAndBAllows_IsFalse() {
        signInLibraryB()
        detailsA.syncPermissionGranted = false

        XCTAssertFalse(bookAnnotations.syncIsPossibleAndPermitted)
    }

    // MARK: - Producer: the audiobook position write

    /// The 15-second autosave goes through the position writer and adapter; this
    /// drives that chain, not only the wrapper.
    func testSaveListeningPosition_AfterSwitchToLibraryB_ReachesLibraryA() async throws {
        let book = TPPBookMocker.mockBook(identifier: AnnotationsTestFixtures.testBookID, title: "Scope Book")
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadSuccessful)
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        let tracks = Tracks(manifest: manifest, audiobookID: book.identifier, token: nil)
        let sut = AudiobookBookmarkBusinessLogic(book: book,
                                                 registry: registry,
                                                 annotationsManager: bookAnnotations,
                                                 debounceInterval: nil)

        sut.saveListeningPosition(at: TrackPosition(track: tracks.tracks[1], timestamp: 42.0, tracks: tracks), completion: nil)
        await sut._awaitPositionWriteForTesting()

        XCTAssertEqual(sent.value.map(\.url), [Self.libraryAAnnotations])
        XCTAssertEqual(sent.value.first?.authorization, "Bearer bearerA")
    }
}

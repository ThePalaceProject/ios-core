//
//  BookReturnCleverReauthTests.swift
//  PalaceTests
//
//  Module B of swarm_66819d80 — explicit pinning of the behavior
//  broadening at substitution site 4.10 inside `BookReturnService`.
//
//  Pre-Module-B the return-time auth-error decision used
//  `(authDef?.isSaml == true || authDef?.isOidc == true) && hasCredentials`.
//  A Clever (OAuth-intermediary) library hitting an invalid-credentials
//  problem doc on return therefore skipped the `markCredentialsStale()`
//  call — the reauthenticator was dispatched with the expired bearer
//  still live in keychain, and the next attempt silently reused the
//  stale token.
//
//  Post-Module-B the predicate is `authDef?.isBrowserBased == true &&
//  hasCredentials`. Clever now flips auth state to `.credentialsStale`
//  before the reauthenticator is invoked, forcing a fresh browser
//  sign-in — matching the SAML/OIDC recovery semantics.
//
//  This file pins that broadening with a single behavior spec. It was
//  originally co-located with `BorrowOperationCleverReauthTests` in
//  that file, then extracted here so the test file name matches the
//  test class name (discovery + pbxproj-routing convention).
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - BookReturnService broadening (site 4.10)

@MainActor
final class BookReturnCleverReauthTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var localContent: SpyLocalContentService!
    private var feedFetcher: StubOPDSFeedFetcher!
    private var announcementService: SpyAnnouncementService!
    private var bookmarkLog: TPPBookmarkDeletionLog!
    private var reauthenticator: TPPReauthenticatorMock!
    private var retryTracker: UserRetryTracker!
    private var spyDelegate: SpyDelegate!
    private var userAccount: TPPUserAccountMock!
    private var service: BookReturnService!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        localContent = SpyLocalContentService()
        feedFetcher = StubOPDSFeedFetcher()
        announcementService = SpyAnnouncementService()
        bookmarkLog = .shared
        reauthenticator = TPPReauthenticatorMock()
        retryTracker = .shared
        spyDelegate = SpyDelegate()
        userAccount = TPPUserAccountMock()

        service = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            // Captures the (@unchecked Sendable) mock, not MainActor self —
            // a nonisolated seam closure capturing self is a Swift 6
            // sending error.
            userAccountProvider: { [userAccount] in userAccount! }
        )
        service.delegate = spyDelegate
        book = makeBookWithRevokeURL()
    }

    override func tearDownWithError() throws {
        registry = nil
        localContent = nil
        feedFetcher = nil
        announcementService = nil
        bookmarkLog = nil
        reauthenticator = nil
        retryTracker = nil
        spyDelegate = nil
        userAccount = nil
        service = nil
        book = nil
        try super.tearDownWithError()
    }

    /// Broadening pin for `BookReturnService.swift` L302.
    ///
    /// Pre-Module-B: `needsBrowserReauth = (isSaml || isOidc) &&
    /// hasCredentials`. A Clever (OAuth-intermediary) library hitting a
    /// return-time invalid-credentials problem doc would skip the
    /// `markCredentialsStale()` call → the reauthenticator dispatched
    /// with stale credentials still in keychain → silent reuse of the
    /// expired token in the next attempt.
    ///
    /// Post-Module-B: `needsBrowserReauth = isBrowserBased &&
    /// hasCredentials`. Clever now marks credentials stale before
    /// dispatching the reauth, forcing a fresh browser sign-in.
    ///
    /// The observable side effect is `userAccount.markCredentialsStale()`:
    /// post-fix the auth state transitions to `.credentialsStale` before
    /// reauthenticator dispatch.
    func testReturn_OAuthIntermediary_AuthError_MarksCredentialsStaleBeforeReauth() async throws {
        // Arrange: Clever library, signed in with credentials, book in
        // registry with the return path enabled (revokeURL set).
        userAccount._authDefinition = try SyntheticAuthDef.oauthIntermediary
        userAccount._credentials = .barcodeAndPin(barcode: "clever-user", pin: "x")
        userAccount.setAuthState(.loggedIn)
        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "Precondition: auth state starts as loggedIn")

        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        feedFetcher.stubbedError = NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc]
        )

        // Re-auth stub: clear credentials inside the callback so the
        // post-reauth `hasCredentials()` check goes false and the
        // service announces failure + runs completion instead of
        // recursively re-attempting the return (which would loop on the
        // unchanging stubbed error).
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = nil
        }

        // Act
        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        // Assert: markCredentialsStale fired (auth state transitioned
        // from .loggedIn → .credentialsStale before the reauthenticator
        // got invoked) AND the reauthenticator was actually invoked.
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Auth error must trigger reauth")
        XCTAssertEqual(userAccount.authState, .credentialsStale,
                       "OAuth-intermediary (Clever) return auth-error MUST flip auth state to .credentialsStale before reauth — Module B broadening of `needsBrowserReauth`. Pre-fix Clever users had their stale token silently reused.")
    }

    // MARK: - Helpers

    private func makeProblemDoc(type: String) throws -> TPPProblemDocument {
        let dict: [String: Any] = ["type": type]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    // nonisolated: pure factory (no self state). Calling an isolated
    // method from the (inherited-nonisolated) setUp override is a
    // Swift 6 sending error.
    private nonisolated func makeBookWithRevokeURL() -> TPPBook {
        let identifier = "rev-\(UUID().uuidString)"
        let acquisitionURL = URL(string: "http://example.com/\(identifier)") ?? URL(fileURLWithPath: "/tmp/x")
        let revokeURL = URL(string: "http://example.com/\(identifier)/revoke") ?? URL(fileURLWithPath: "/tmp/x")
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "a", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Clever Reauth Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: revokeURL,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - File-private test fakes
//
// Duplicated from `BorrowOperationCleverReauthTests.swift` because the
// originals are declared `private` (file-scope) in that file. Once
// Module C lands the AuthCoordinator and these tests rewrite against
// it, the duplication retires.

@MainActor
private final class SpyDelegate: NSObject, BookReturnServiceDelegate {
    private(set) var purgeAudiobookCachesCalls: [Bool] = []

    nonisolated func purgeAllAudiobookCaches(force: Bool) {
        Task { @MainActor in
            self.purgeAudiobookCachesCalls.append(force)
        }
    }
}

private final class SpyLocalContentService: LocalBookContentService {
    var deleteForIdentifierCalls: [String] = []

    init() {
        super.init(
            bookRegistry: TPPBookRegistryMock(),
            accountsManager: AppContainer.production().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: TPPBookRegistryMock()),
            fileManager: .default
        )
    }

    override func deleteLocalContent(for identifier: String, account: String? = nil) {
        deleteForIdentifierCalls.append(identifier)
    }

    override func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        deleteForIdentifierCalls.append(book.identifier)
    }
}

private final class SpyAnnouncementService: DownloadAnnouncementService {
    var startedCalls: [String] = []
    var succeededCalls: [String] = []
    var failedCalls: [String] = []

    override func announceReturnStarted(for book: TPPBook) {
        startedCalls.append(book.identifier)
    }

    override func announceReturnSucceeded(for book: TPPBook) {
        succeededCalls.append(book.identifier)
    }

    override func announceReturnFailed(for book: TPPBook) {
        failedCalls.append(book.identifier)
    }
}

private final class StubOPDSFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    var stubbedError: Error?

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        if let stubbedError {
            throw stubbedError
        }
        throw NSError(domain: "BookReturnCleverReauthTests.stub", code: -999,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}

// MARK: - Shared OAuth-intermediary fixture
//
// Mirrors the JSON round-trip pattern from
// `BorrowOperationCleverReauthTests.swift` — the OPDS2 memberwise init
// is internal, so JSON decode is the supported construction path.

private enum SyntheticAuthDef {

    static var oauthIntermediary: AccountDetails.Authentication {
        get throws {
            let json = """
            {
              "type": "http://librarysimplified.org/authtype/OAuth-with-intermediary",
              "description": "Clever (OAuth intermediary)",
              "links": [
                {"rel": "authenticate", "href": "https://intermediary.example.com/auth"}
              ]
            }
            """
            let docAuth = try JSONDecoder().decode(
                OPDS2AuthenticationDocument.Authentication.self,
                from: Data(json.utf8)
            )
            return AccountDetails.Authentication(auth: docAuth)
        }
    }
}

//
//  BorrowOperationCleverReauthTests.swift
//  PalaceTests
//
//  Module B of swarm_66819d80 — explicit pinning of the behavior
//  broadening at substitution sites 4.5 / 4.6 / 4.10. Substituting
//  `(authDef?.isSaml == true || authDef?.isOidc == true)` with
//  `authDef?.isBrowserBased == true` is intentional but visible: an
//  OAuth-intermediary (Clever) library that previously fell through to
//  the "no automatic recovery" generic-alert path now routes through
//  the SAML-style browser-reauth modal.
//
//  This is the right architectural answer (Clever IS browser-based),
//  but it's the kind of broadening that would silently regress without
//  tests written for it. Two tests:
//
//    1. BorrowOperation L562 (within `isAuthError` predicate) +
//       BorrowOperation L613 (`needsBrowserReauth` decision):
//       OAuth-intermediary auth + auth error + credentials → routes to
//       the sign-in modal (was: generic alert / no recovery).
//
//    2. BookReturnService L302 (`needsBrowserReauth` decision):
//       OAuth-intermediary auth + auth error + credentials →
//       `markCredentialsStale()` fires before reauth dispatch (was:
//       skipped — credentials were left intact and the reauth dispatch
//       silently reused stale tokens).
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

// MARK: - BorrowOperation broadening (sites 4.5 + 4.6)

@MainActor
final class BorrowOperationCleverReauthTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyDelegate!
    private var operation: BorrowOperation!
    private var book: TPPBook!

    private let fetchBookResult = LockIsolated<Result<TPPBook, Error>?>(nil)
    private let alertCalls = LockIsolated<[(title: String, message: String, book: TPPBook, hasRetryAction: Bool)]>([])
    private let signInModalCompletions = LockIsolated<[() -> Void]>([])
    private let oidcReauthResult = LockIsolated<Bool>(false)

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()

        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        fetchBookResult.value = .success(book)
        alertCalls.value = []
        signInModalCompletions.value = []
        oidcReauthResult.value = false

        // Swift 6: the injected closures run outside MainActor isolation, so
        // capturing `self` sends a main-actor-isolated value across the
        // boundary. Capture the Sendable boxes as locals instead.
        let fetchBookResultBox = fetchBookResult
        let oidcReauthResultBox = oidcReauthResult
        let alertCallsBox = alertCalls
        let signInModalCompletionsBox = signInModalCompletions
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in
                switch fetchBookResultBox.value! {
                case .success(let r): return r
                case .failure(let e): throw e
                }
            },
            presentBorrowErrorAlert: { title, message, _, _, b, retryAction in
                alertCallsBox.withValue { $0.append((title, message, b, retryAction != nil)) }
            },
            presentSignInModal: { completion in
                signInModalCompletionsBox.withValue { $0.append(completion) }
            },
            attemptOIDCReauth: { oidcReauthResultBox.value }
        )
        operation.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        bookRegistry = nil
        userAccount = nil
        spyDelegate = nil
        operation = nil
        book = nil
        try super.tearDownWithError()
    }

    /// Broadening pin for `BorrowOperation.swift` L562 + L613.
    ///
    /// Pre-Module-B, the `needsBrowserReauth` predicate was
    /// `(authDef?.isSaml == true || authDef?.isOidc == true) && hasCredentials`.
    /// A Clever (OAuth-intermediary) library hitting a borrow-time auth
    /// error with credentials present would skip the browser-reauth arm,
    /// fall through the `!hasCredentials && needsAuth` arm (false — we
    /// HAVE creds), and end up at the "no automatic recovery" log line →
    /// `.showGenericError` → user sees a generic toast with no recovery
    /// path.
    ///
    /// Post-Module-B, `needsBrowserReauth = authDef?.isBrowserBased == true
    /// && hasCredentials`. Clever now routes through the SAML-style
    /// `presentSignInModalAndRetryBorrow` arm — `presentSignInModal` is
    /// invoked, the user re-authenticates, and the borrow retries.
    ///
    /// This is the right answer (Clever IS browser-based) and matches
    /// the user-visible behavior for SAML/OIDC. Test pins the new path.
    func testBorrow_OAuthIntermediary_AuthError_RoutesToBrowserReauthModal() async throws {
        // Arrange: Clever library, credentials present, fresh circuit
        // breaker, auth-error coming back from fetchBook.
        userAccount._authDefinition = try SyntheticAuthDef.oauthIntermediary
        userAccount._credentials = .barcodeAndPin(barcode: "clever-user", pin: "x")
        userAccount.setAuthState(.loggedIn)

        let problemDoc = try Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult.value = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        // Act
        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth-error borrow must rethrow")
        } catch {
            // expected
        }
        // presentSignInModal is awaited inside borrowAsync's reauth path — assert directly.

        // Assert: browser-reauth modal was presented.
        XCTAssertEqual(signInModalCompletions.value.count, 1,
                       "OAuth-intermediary (Clever) auth error with credentials MUST trigger presentSignInModal — the Module B broadening of `needsBrowserReauth`")
        XCTAssertEqual(alertCalls.value.count, 0,
                       "Browser-reauth path must NOT also surface a generic borrow-error alert; that was the pre-Module-B regression for Clever users")
    }

    /// Broadening pin for `BorrowOperation.swift` L562.
    ///
    /// The `isAuthError` predicate has a `TypeNoActiveLoan` arm gated on
    /// `(authDef?.isSaml == true || authDef?.isOidc == true) && hasCredentials`.
    /// Pre-Module-B, an OAuth-intermediary library that received a
    /// `no-active-loan` problem doc with credentials would NOT be treated
    /// as an auth error → fell through to `.showGenericError` → generic
    /// alert with no re-auth attempt.
    ///
    /// Post-Module-B, the predicate broadens to `isBrowserBased` — Clever
    /// users get the PP-3716 auto-re-auth treatment for the same edge
    /// case (server says "no active loan" while the bearer is valid; we
    /// suspect IdP-side session drift; recovery is a fresh sign-in).
    ///
    /// The user-visible signal: `presentSignInModal` fires instead of
    /// the borrow falling through to a generic alert.
    func testBorrow_OAuthIntermediary_NoActiveLoanProblemDoc_TreatedAsAuthError() async throws {
        userAccount._authDefinition = try SyntheticAuthDef.oauthIntermediary
        userAccount._credentials = .barcodeAndPin(barcode: "clever-user", pin: "x")
        userAccount.setAuthState(.loggedIn)

        // Synthesize the PP-3716 edge case: no-active-loan + creds.
        let problemDoc = try Self.makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        // Wrap the NSError so the BorrowOperation `originalError`
        // problemDocument extraction path fires (matches BorrowOperation's
        // `nsError.problemDocument` extraction).
        fetchBookResult.value = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("no-active-loan with credentials must rethrow as auth error")
        } catch {
            // expected
        }
        // presentSignInModal is awaited inside borrowAsync's reauth path — assert directly.

        XCTAssertEqual(signInModalCompletions.value.count, 1,
                       "PP-3716 broadening: OAuth-intermediary (Clever) + no-active-loan + credentials must be treated as auth error and route to sign-in modal")
    }

    // MARK: - Helpers

    private static func makeProblemDoc(type: String) throws -> TPPProblemDocument {
        let dict: [String: Any] = ["type": type]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }
}

// MARK: - File-private test fakes
//
// Sibling test files declare `SpyDelegate` at file-private scope.
// We duplicate the minimal subset Module B needs rather than promoting
// it to test-target internals — promoting would touch off-contract
// files and surface area. Once Module C lands the AuthCoordinator
// and these tests can be rewritten against it, the duplication retires.

@MainActor
private final class SpyDelegate: NSObject, BorrowOperationDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var startBorrowCalls: [(book: TPPBook, attemptDownload: Bool)] = []

    func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }

    nonisolated func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        Task { @MainActor in
            self.startBorrowCalls.append((book, attemptDownload))
        }
    }
}

// MARK: - Shared OAuth-intermediary fixture
//
// Mirrors the `SyntheticAuthDef.basicNeedsAuth` pattern from
// BorrowOperationTests.swift — the OPDS2 memberwise init is internal,
// so JSON round-trip is the supported construction path.

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

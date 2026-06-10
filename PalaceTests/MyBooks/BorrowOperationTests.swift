//
//  BorrowOperationTests.swift
//  PalaceTests
//
//  Coverage for the borrow lifecycle lifted out of MBDC+Async.swift.
//  Closure injection (fetchBook / present-alert / present-sign-in /
//  OIDC reauth) lets these tests verify the state machine without the
//  OPDS network stack or UIKit. The auth-error retry paths
//  (handleBorrowAuthErrorIfNeeded + the OIDC + sign-in-modal hops) are
//  tightly coupled to live AccountDetails.Authentication construction
//  that no existing test helper provides — those branches are exercised
//  via integration tests, not here.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BorrowOperationTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyDelegate!
    private var operation: BorrowOperation!
    private var book: TPPBook!

    /// Recorders for the closure-injected seams.
    private var fetchBookResult: Result<TPPBook, Error>!
    private var fetchBookCalls: [(url: URL, resetCache: Bool, useToken: Bool)] = []
    private var alertCalls: [(title: String, message: String, book: TPPBook, hasRetryAction: Bool)] = []
    private var signInModalCompletions: [() -> Void] = []
    private var oidcReauthResult: Bool = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Clear any cross-test reauth circuit-breaker state.
        BorrowOperation.clearAllBorrowReauthState()

        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // Default: borrow returns the same book (with whatever availability
        // the test sets via book.acquisition replacement before calling).
        fetchBookResult = .success(book)
        fetchBookCalls = []
        alertCalls = []
        signInModalCompletions = []
        oidcReauthResult = false

        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { [unowned self] url, resetCache, useToken in
                self.fetchBookCalls.append((url, resetCache, useToken))
                switch self.fetchBookResult! {
                case .success(let result): return result
                case .failure(let error): throw error
                }
            },
            presentBorrowErrorAlert: { [unowned self] title, message, _, _, book, retryAction in
                self.alertCalls.append((title, message, book, retryAction != nil))
            },
            presentSignInModal: { [unowned self] completion in
                self.signInModalCompletions.append(completion)
            },
            attemptOIDCReauth: { [unowned self] in self.oidcReauthResult }
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

    // MARK: - Success path

    func testBorrowAsync_success_addsBookToRegistryAsDownloadNeeded() async throws {
        // Ensure the registry doesn't already contain the book so we can
        // observe the addBook side effect.
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .unregistered)

        let result = try await operation.borrowAsync(book, attemptDownload: false)

        XCTAssertEqual(result.identifier, book.identifier)
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "Successful borrow with .ready/.unlimited availability must register .downloadNeeded")
        XCTAssertEqual(fetchBookCalls.count, 1,
                       "Borrow must hit the fetchBook closure exactly once on the success path")
        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 0,
                       "attemptDownload=false must NOT call delegate.startDownload")
        XCTAssertEqual(alertCalls.count, 0,
                       "Success path must NOT present an error alert")
    }

    func testBorrowAsync_attemptDownloadTrue_callsDelegateStartDownload() async throws {
        let result = try await operation.borrowAsync(book, attemptDownload: true)

        XCTAssertEqual(result.identifier, book.identifier)
        // Allow the @MainActor.run hop for delegate?.startDownload to settle.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "attemptDownload=true with .downloadNeeded must call delegate.startDownload")
    }

    // MARK: - Holding race (PP-4178)

    func testBorrowAsync_holdingRace_throwsHoldCopyUnavailableAndSetsHolding() async {
        // Replace the book's acquisition with one that decodes to .reserved
        // availability, simulating CM's Loan→Hold race. Easiest path: build
        // a fresh book with the right availability.
        let raceBook = makeBookWithReservedAvailability()
        fetchBookResult = .success(raceBook)

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Borrow with reserved-availability response must throw")
        } catch let error as PalaceError {
            if case .bookRegistry(.holdCopyUnavailable) = error {
                // expected
            } else {
                XCTFail("Expected .bookRegistry(.holdCopyUnavailable), got \(error)")
            }
            XCTAssertEqual(bookRegistry.state(for: raceBook.identifier), .holding,
                           "Holding-race path must register .holding before throwing so UI is accurate")
        } catch {
            XCTFail("Expected PalaceError, got \(error)")
        }
    }

    // MARK: - Pre-fetch validation

    func testBorrowAsync_noAcquisitionURL_throwsInvalidState() async {
        let bookWithoutURL = makeBookWithNoAcquisition()

        do {
            _ = try await operation.borrowAsync(bookWithoutURL, attemptDownload: false)
            XCTFail("Borrow with no acquisition URL must throw")
        } catch let error as PalaceError {
            if case .bookRegistry(.invalidState) = error {
                // expected
            } else {
                XCTFail("Expected .bookRegistry(.invalidState), got \(error)")
            }
            XCTAssertEqual(fetchBookCalls.count, 0,
                           "No-URL guard must short-circuit BEFORE the fetchBook closure runs")
        } catch {
            XCTFail("Expected PalaceError, got \(error)")
        }
    }

    // MARK: - Generic error → showBorrowError

    func testBorrowAsync_genericError_presentsAlertAndRethrows() async {
        struct TestError: Error {}
        fetchBookResult = .failure(TestError())

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Generic fetch error must rethrow")
        } catch {
            // Expected — errored borrow rethrows after presenting alert.
        }

        // Allow the @MainActor.run hop for showBorrowError to settle.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(alertCalls.count, 1,
                                    "Generic error path must invoke presentBorrowErrorAlert")
        XCTAssertEqual(alertCalls.last?.book.identifier, book.identifier)
    }

    // MARK: - Item #7 — 401 without problem document routes to re-auth

    /// Item #7 fix: when a 401 surfaces as `PalaceError.network(.unauthorized)`
    /// (e.g. an OPDS path that stripped the problem doc + we have no
    /// originalError NSError code to lean on), `handleBorrowAuthErrorIfNeeded`
    /// MUST treat it as auth error and present the sign-in modal — not fall
    /// through to a generic alert. Closes the 35k+ "Network request failed
    /// (912)" non-fatal regression.
    func testBorrow_401NetworkUnauthorizedNoProblemDoc_presentsSignInModal() async {
        // Account has no credentials BUT needsAuth — exercises the
        // sign-in-modal arm (vs the OIDC/SAML browser-reauth arm which
        // requires a constructed authDefinition test helpers can't build).
        userAccount._credentials = nil
        userAccount._authDefinition = SyntheticAuthDef.basicNeedsAuth

        // Throw the PalaceError directly so we route through the first
        // catch block (the "no originalError NSError" path).
        fetchBookResult = .failure(PalaceError.network(.unauthorized))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("401 borrow must rethrow")
        } catch {
            // expected
        }

        // Let the @MainActor.run hop for presentSignInModal settle.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(signInModalCompletions.count, 1,
                       "401-no-problem-doc must present the sign-in modal (item #7)")
        XCTAssertEqual(alertCalls.count, 0,
                       "Item #7 fix: re-auth path must NOT also surface a borrow-error alert")
    }

    /// Boundary: a 403 (forbidden) is also covered by the auth-error
    /// predicate broadening so the same 401-no-problem-doc plumbing
    /// can absorb a 403 mid-session.
    func testBorrow_403NetworkForbiddenNoProblemDoc_presentsSignInModal() async {
        userAccount._credentials = nil
        userAccount._authDefinition = SyntheticAuthDef.basicNeedsAuth

        fetchBookResult = .failure(PalaceError.network(.forbidden))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("403 borrow must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(signInModalCompletions.count, 1,
                       "403-no-problem-doc must present the sign-in modal (item #7)")
    }

    /// Negative case: a `PalaceError.network(.unknown)` is NOT an auth
    /// error and MUST fall through to the generic borrow-error alert
    /// (preserves the existing contract for non-auth network failures).
    /// Locks the boundary so the item #7 predicate broadening doesn't
    /// silently absorb every network error.
    func testBorrow_NetworkUnknownError_fallsThroughToAlert() async {
        fetchBookResult = .failure(PalaceError.network(.unknown))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Generic network error must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(signInModalCompletions.count, 0,
                       "Non-auth network errors must NOT trigger the sign-in modal")
        XCTAssertGreaterThanOrEqual(alertCalls.count, 1,
                                    "Non-auth network errors must surface the borrow-error alert")
    }

    // MARK: - Item #8 — SQ-007 spinner cleanup via BorrowAuthErrorDecision

    /// Item #8: SQ-007 fires when the book is already in the registry
    /// with a loan-class state AND credentials are present. The
    /// pre-fix behavior was to suppress re-auth but still call
    /// `showBorrowError` (a misleading credentials toast). Post-fix:
    /// `BorrowAuthErrorDecision.suppressAndClearSpinner` keeps the
    /// alert suppressed AND idempotently re-clears the cell spinner.
    func testBorrow_SQ007AlreadyHasLoanWithCredentials_doesNotShowAlert() async {
        // Seed registry to "already has loan" state.
        bookRegistry.addBook(book, location: nil, state: .downloadNeeded,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)

        // Use a problem-doc-typed invalidCredentials to drive isAuthError
        // through the problemDoc branch (the canonical SQ-007 trigger).
        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("SQ-007 path must still rethrow the error")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(alertCalls.count, 0,
                       "SQ-007 suppression must NOT surface a borrow-error alert (item #8)")
        XCTAssertEqual(signInModalCompletions.count, 0,
                       "SQ-007 suppression must NOT trigger re-auth either")
        XCTAssertFalse(bookRegistry.processing(forIdentifier: book.identifier),
                       "SQ-007 suppression must idempotently clear setProcessing on the cell")
    }

    /// Boundary: same loan-present state but credentials are ABSENT —
    /// SQ-007 doesn't apply, the path should proceed as a real auth
    /// error and present the sign-in modal. Pins the predicate symmetry.
    func testBorrow_AlreadyHasLoanWithoutCredentials_proceedsAsAuthError() async {
        bookRegistry.addBook(book, location: nil, state: .downloadNeeded,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        userAccount._credentials = nil
        userAccount._authDefinition = SyntheticAuthDef.basicNeedsAuth

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth error must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(signInModalCompletions.count, 1,
                       "No-credentials + loan-state must STILL trigger sign-in modal (not SQ-007)")
    }

    /// Boundary: state `.unregistered` is NOT a loan-class state, so
    /// SQ-007 must NOT fire. With basic auth + credentials present,
    /// the predicate routes to "no automatic recovery" → generic alert.
    /// Pins that .unregistered short-circuits SQ-007.
    func testBorrow_StateUnregistered_isNotTreatedAsAlreadyHavingLoan() async {
        // Don't seed registry — state stays .unregistered.
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        userAccount._authDefinition = SyntheticAuthDef.basicNeedsAuth

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth error must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        // basic auth + creds + .unregistered → not SQ-007 → not
        // browser-reauth → no automatic recovery → generic alert.
        XCTAssertGreaterThanOrEqual(alertCalls.count, 1,
                                    ".unregistered must NOT trigger SQ-007 suppression; alert proceeds")
    }

    /// Boundary: `.holding` IS a loan-class state — SQ-007 applies.
    /// Pins the switch-case exhaustiveness in the predicate.
    func testBorrow_StateHolding_isTreatedAsAlreadyHavingLoan() async {
        bookRegistry.addBook(book, location: nil, state: .holding,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth error must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(alertCalls.count, 0,
                       ".holding + credentials → SQ-007 fires → no alert")
        XCTAssertFalse(bookRegistry.processing(forIdentifier: book.identifier),
                       "SQ-007 path clears the spinner")
    }

    // MARK: - F-008 / PP-4542 — browser-vs-basic reauth branch (line 636)
    //
    // `needsBrowserReauth = (authDef?.isBrowserBased == true) && hasCredentials`
    // at BorrowOperation.swift:636 decides whether an authenticated 401
    // routes to the browser re-auth flow (SAML/OIDC/OAuth → sign-in modal,
    // NO error alert) or falls through to `.showGenericError` (alert, no
    // modal). The two tests below are a discriminating pair: SAME pre-state
    // (creds present, .unregistered registry state, invalid-credentials
    // problem doc) differing ONLY in the auth-def's browser-ness — and they
    // assert OPPOSITE observable outcomes. Flipping `== true` to `!= true`
    // at :636 swaps the two outcomes, breaking both tests.
    //
    // The basic-auth half is `testBorrow_StateUnregistered_isNotTreatedAsAlreadyHavingLoan`
    // (basic + creds + .unregistered → alert, no modal). This is the SAML
    // half.

    /// SAML (browser-based) + credentials + invalid-credentials 401 on an
    /// `.unregistered` book must route to the browser re-auth flow: the
    /// sign-in modal is presented and NO borrow-error alert fires.
    ///
    /// Kills :636 `isBrowserBased == true`→`!= true`: under the mutant SAML
    /// evaluates `isBrowserBased != true` == false → `needsBrowserReauth`
    /// false → with creds present the `else if !hasCredentials` arm is also
    /// false → `.showGenericError` → an ALERT fires and the modal does NOT
    /// — both assertions below flip.
    func testBorrow_SAMLBrowserAuth_withCredentials_routesToReauthModalNotAlert() async {
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        userAccount._authDefinition = SyntheticAuthDef.saml

        // .unregistered registry state so SQ-007 (already-has-loan) does NOT
        // fire and suppress the path — we want the live browser-reauth branch.
        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("SAML auth-error borrow must rethrow")
        } catch {
            // expected
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(signInModalCompletions.count, 1,
                       "SAML browser-based account + creds must route to the browser re-auth modal " +
                       "(needsBrowserReauth branch at :636). A `!= true` mutant would skip this and alert instead.")
        XCTAssertEqual(alertCalls.count, 0,
                       "Browser re-auth path must NOT surface a borrow-error alert. A `!= true` mutant at " +
                       ":636 would fall through to .showGenericError and fire the alert.")
    }

    // MARK: - Helpers (items #7 / #8)

    /// Synthesizes a minimal problem document with the given type.
    private static func makeProblemDoc(type: String) -> TPPProblemDocument {
        let dict: [String: Any] = ["type": type]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return TPPProblemDocument.fromProblemResponseData(data)!
    }

    /// Test fixture for the `needsAuth` predicate. The
    /// `handleBorrowAuthErrorIfNeeded` predicate gates on
    /// `authDef?.needsAuth ?? false` for the "no creds + needs auth →
    /// sign-in-modal" arm. `.basic` qualifies; `.saml` / `.oidc` would
    /// route through the browser-reauth arm which other tests cover.
    private enum SyntheticAuthDef {
        static var basicNeedsAuth: AccountDetails.Authentication {
            // OPDS2 authentication-document JSON for basic auth. The
            // memberwise init on the OPDS2 type is internal to
            // PalaceCatalog; round-tripping through JSON is the
            // supported construction path.
            let json = """
            {
              "type": "http://opds-spec.org/auth/basic",
              "description": "Basic auth",
              "labels": {"login": "Barcode", "password": "PIN"}
            }
            """
            let docAuth = try! JSONDecoder().decode(
                OPDS2AuthenticationDocument.Authentication.self,
                from: Data(json.utf8)
            )
            return AccountDetails.Authentication(auth: docAuth)
        }

        /// SAML (browser-based) auth def. `isBrowserBased == true`,
        /// `isSaml == true`. Drives the `needsBrowserReauth` branch at
        /// BorrowOperation.swift:636.
        static var saml: AccountDetails.Authentication {
            let json = """
            {
              "type": "http://librarysimplified.org/authtype/SAML-2.0",
              "description": "SAML",
              "links": [
                {"rel": "authenticate", "href": "https://idp.example.com/saml"}
              ]
            }
            """
            let docAuth = try! JSONDecoder().decode(
                OPDS2AuthenticationDocument.Authentication.self,
                from: Data(json.utf8)
            )
            return AccountDetails.Authentication(auth: docAuth)
        }
    }

    // MARK: - Helpers

    private func makeBookWithReservedAvailability() -> TPPBook {
        let identifier = UUID().uuidString
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: DistributorType.EpubZip.rawValue,
            hrefURL: URL(string: "http://example.com/borrow/\(identifier)")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityReserved(
                holdPosition: 1,
                copiesTotal: 1,
                since: nil,
                until: nil
            )
        )
        let imageCache = MockImageCache()
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Race Book",
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
            imageCache: imageCache
        )
    }

    private func makeBookWithNoAcquisition() -> TPPBook {
        let identifier = UUID().uuidString
        let imageCache = MockImageCache()
        return TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "No-URL Book",
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
            imageCache: imageCache
        )
    }
}

// MARK: - Stubs

@MainActor
private final class SpyDelegate: BorrowOperationDelegate {
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

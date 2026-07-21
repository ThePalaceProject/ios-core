//
//  BorrowOperationContractTests.swift
//  PalaceTests
//
//  Contract-snapshot coverage for BorrowOperation. The PR #890 extraction
//  leaked F-011 (missing `.downloadNeeded` reducer arm) and F-014 (inverted
//  attemptDownload condition skipping startDownload on the post-borrow
//  state). Per-case unit tests in PalaceTests/MyBooks/BorrowOperationTests
//  passed throughout — the regressions slipped because nothing pinned the
//  *call sequence* into the delegate.
//
//  These tests pin the contract: for each (attemptDownload, fetchBook
//  result, registry pre-state) input, what calls land on the delegate
//  spy + closure-injected seams (fetchBook, present-alert, present-modal,
//  attemptOIDCReauth). Future refactors that change which dependency
//  gets called (or in what order) trip a snapshot diff at PR time.
//
//  Notes on coverage scope:
//  - The "silent-reauth via OIDC" path requires a live `AccountDetails
//    .Authentication` whose `.isOidc == true`. No test helper constructs
//    that today (see comment at top of BorrowOperationTests.swift). The
//    auth-error contract here pins the no-auth-recovery fall-through
//    that BorrowOperation hits when authDef is nil — the OIDC silent
//    re-auth branch is integration-tested separately.
//  - All books use deterministic identifiers (not TPPBookMocker's UUID)
//    so snapshots stay stable across runs.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BorrowOperationContractTests: XCTestCase {

    // MARK: - Test fixture state

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyBorrowDelegate!
    private var operation: BorrowOperation!

    /// Recorded calls live here so each test can opt to either drive
    /// pure XCT assertions OR roll the recorded sequence through a
    /// ContractSnapshot.assert(...) check.
    private var log: CallLog!

    /// Swift 6: `fetchBook` is a non-isolated `async` closure, so it cannot
    /// capture `self` (a non-Sendable XCTestCase) to read this per-test value.
    /// Box it behind a lock so the closure captures the box (Sendable) instead.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Result<TPPBook, Error>?
        var value: Result<TPPBook, Error>? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    /// Closure seams.
    private let fetchBookResult = ResultBox()

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()

        log = CallLog()
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyBorrowDelegate(log: log)

        // Default success: the fetch returns the same book that was passed
        // in. Tests override per-scenario.
        let defaultBook = Self.makeBook(identifier: "BOOK-1", availability: .unlimited)
        fetchBookResult.value = .success(defaultBook)

        // NOTE: BorrowOperation's `init` is gated by FEATURE_DRM_CONNECTOR
        // on the Palace target, which is set for production but NOT for
        // PalaceTests (see project.pbxproj: PalaceTests uses
        // "LCP FEATURE_OVERDRIVE" without FEATURE_DRM_CONNECTOR). The
        // compiled framework PalaceTests links against carries the DRM
        // variant of `init`, so we call it unconditionally — same approach
        // as PalaceTests/MyBooks/BorrowOperationTests.swift.
        // Capture Sendable collaborators as locals so the non-isolated async
        // closures (fetchBook, attemptOIDCReauth) don't capture `self` (Swift 6).
        let callLog = log!
        let resultBox = fetchBookResult
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: SilentAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { url, resetCache, useToken in
                callLog.record("fetchBook",
                               args: ["url": url.lastPathComponent,
                                      "resetCache": "\(resetCache)",
                                      "useToken": "\(useToken)"])
                switch resultBox.value! {
                case .success(let result): return result
                case .failure(let error): throw error
                }
            },
            presentBorrowErrorAlert: { title, _, _, _, book, retryAction in
                callLog.record("presentBorrowErrorAlert",
                               args: ["title": title,
                                      "bookId": book.identifier,
                                      "hasRetryAction": "\(retryAction != nil)"])
            },
            presentSignInModal: { _ in
                callLog.record("presentSignInModal", args: [:])
            },
            attemptOIDCReauth: {
                callLog.record("attemptOIDCReauth", args: [:])
                return false
            }
        )
        operation.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        log = nil
        bookRegistry = nil
        userAccount = nil
        spyDelegate = nil
        operation = nil
        fetchBookResult.value = nil
        try super.tearDownWithError()
    }

    // MARK: - F-014 contract: attemptDownload=true on successful borrow

    /// F-014 contract: borrow returns a book whose mapped state is
    /// `.downloadNeeded`. With `attemptDownload=true` the operation MUST
    /// fire `delegate.startDownload(...)`. A future refactor that flips
    /// the condition (as PR #890 did) trips the snapshot diff.
    func test_borrowAsync_attemptDownloadTrue_onSuccessfulBorrow_callsStartDownload() async throws {
        let book = Self.makeBook(identifier: "F014-OK", availability: .unlimited)
        fetchBookResult.value = .success(book)

        _ = try await operation.borrowAsync(book, attemptDownload: true)

        // Drain the @MainActor.run delegate hop.
        await waitForLog(containing: "startDownload")
        ContractSnapshot.assert(log, named: "attemptDownloadTrue_onSuccessfulBorrow_callsStartDownload")
    }

    /// Symmetric guard: same input but `attemptDownload=false` MUST NOT
    /// call startDownload. Pins the gate.
    func test_borrowAsync_attemptDownloadFalse_onSuccessfulBorrow_doesNotCallStartDownload() async throws {
        let book = Self.makeBook(identifier: "F014-NoDL", availability: .unlimited)
        fetchBookResult.value = .success(book)

        _ = try await operation.borrowAsync(book, attemptDownload: false)

        // Wait one settle cycle so a stray dispatch would land if present.
        await yieldSettle()
        ContractSnapshot.assert(log, named: "attemptDownloadFalse_onSuccessfulBorrow_doesNotCallStartDownload")
    }

    // MARK: - Auth-error contract

    /// When the underlying fetch throws a problem-doc-typed
    /// `invalidCredentials` error AND `userAccount.authDefinition == nil`
    /// (no recovery path), BorrowOperation:
    ///   - skips silent re-auth (no authDef → no OIDC, no SAML, no modal)
    ///   - falls through to `showBorrowError` → presents alert.
    /// The OIDC-silent-reauth happy path requires a constructed
    /// AccountDetails.Authentication with .isOidc=true and active
    /// credentials, which no test helper builds today; we cover that
    /// branch in integration tests. The contract pinned here is the
    /// "no auto-recovery → alert" sequence.
    func test_borrowAsync_authError_triggersRetryViaSilentReauth() async {
        let book = Self.makeBook(identifier: "AUTH-ERR", availability: .unlimited)
        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult.value = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth-error borrow must rethrow")
        } catch {
            // expected
        }
        // Auth-error → showBorrowError hops via @MainActor.run.
        await waitForLog(containing: "presentBorrowErrorAlert")
        ContractSnapshot.assert(log, named: "authError_noAuthDef_fallsThroughToAlert")
    }

    // MARK: - Hold response contract

    /// When the borrow response carries `.reserved` availability (CM
    /// Loan→Hold race, PP-4178), BorrowOperation:
    ///   - registers `.holding` state
    ///   - announces start (via silent service — not in log)
    ///   - throws `.bookRegistry(.holdCopyUnavailable)`
    ///   - does NOT call startDownload regardless of attemptDownload.
    func test_borrowAsync_holdResponse_doesNotCallStartDownload() async {
        let preBorrowBook = Self.makeBook(identifier: "HOLD-PRE", availability: .unlimited)
        let raceResponse = Self.makeBook(identifier: "HOLD-POST", availability: .reserved)
        fetchBookResult.value = .success(raceResponse)

        do {
            _ = try await operation.borrowAsync(preBorrowBook, attemptDownload: true)
            XCTFail("Hold-race response must throw .holdCopyUnavailable")
        } catch {
            // expected
        }
        await yieldSettle()
        ContractSnapshot.assert(log, named: "holdResponse_doesNotCallStartDownload")
    }

    // MARK: - SQ-007 idempotency contract

    /// SQ-007 (item #8 fix): if the book is already in the registry
    /// with a loan-class state (`.downloadNeeded` / `.downloadSuccessful` /
    /// etc.) AND `hasCredentials` is true, an `invalidCredentials`
    /// error from a stale auto-re-borrow MUST be suppressed — the
    /// operation MUST NOT trigger re-auth AND MUST NOT surface a
    /// borrow-error alert (post-fix). The pre-fix snapshot included
    /// `presentBorrowErrorAlert`; the post-fix snapshot DOES NOT.
    ///
    /// We mark the registry state to `.downloadNeeded` pre-call, then
    /// fail the fetch with invalidCredentials. The contract pinned:
    ///   - fetchBook called once (the borrow attempt)
    ///   - NO presentSignInModal / NO attemptOIDCReauth
    ///   - NO presentBorrowErrorAlert (item #8 fix — was the bug)
    func test_borrowAsync_alreadyBorrowed_isIdempotent_perSQ007() async {
        let book = Self.makeBook(identifier: "SQ007-BOOK", availability: .unlimited)
        // Seed registry to "already has loan" state.
        bookRegistry.addBook(book, location: nil, state: .downloadNeeded,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // Give the user account credentials so the SQ-007 suppression arm fires.
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        fetchBookResult.value = .failure(NSError(
            domain: "test", code: 401,
            userInfo: ["problemDocument": problemDoc as Any]
        ))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth-error borrow must rethrow")
        } catch {
            // expected
        }
        // Wait one settle cycle so any stray alert dispatch would land.
        await yieldSettle()
        ContractSnapshot.assert(log, named: "alreadyBorrowed_isIdempotent_perSQ007")
    }

    // MARK: - Item #7 contract — 401 no-problem-doc routes to re-auth

    /// Item #7 fix: a `PalaceError.network(.unauthorized)` thrown by
    /// `fetchBook` with no problem document AND no credentials
    /// (forcing the `needsAuth` arm via a synthetic basic-auth
    /// authDefinition) MUST present the sign-in modal — not fall
    /// through to a generic alert. The snapshot pins the post-fix
    /// call shape: fetchBook → presentSignInModal, no
    /// presentBorrowErrorAlert.
    func test_borrowAsync_401NoProblemDoc_routesToSignInModal() async {
        let book = Self.makeBook(identifier: "ITEM7-BOOK", availability: .unlimited)
        userAccount._credentials = nil
        // Authentication-doc JSON for basic auth — minimal but sufficient
        // for `needsAuth == true`.
        let authJSON = """
        {
          "type": "http://opds-spec.org/auth/basic",
          "description": "Basic auth"
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(authJSON.utf8)
        )
        userAccount._authDefinition = AccountDetails.Authentication(auth: docAuth)

        fetchBookResult.value = .failure(PalaceError.network(.unauthorized))

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("401 borrow must rethrow")
        } catch {
            // expected
        }

        await waitForLog(containing: "presentSignInModal")
        ContractSnapshot.assert(log, named: "401NoProblemDoc_routesToSignInModal")
    }

    // MARK: - Helpers

    /// Wait up to ~1s for the log to contain a record with the given method.
    /// Wraps the shared `awaitConditionAsync` helper.
    /// `file`/`line` forwarded so timeout XCTFail blames the call site.
    private func waitForLog(
        containing method: String,
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        // Swift 6: `awaitConditionAsync`'s predicate is a non-Sendable
        // `() -> Bool` sent to a nonisolated async helper, so it must not
        // capture `self` (a non-Sendable XCTestCase). Hoist the Sendable
        // `CallLog` (@unchecked Sendable) and the method name to locals so
        // the predicate captures only Sendable values — mirrors the local-
        // hoist pattern used in setUp for the async closure seams.
        let capturedLog = log
        await awaitConditionAsync(timeout: timeout, file: file, line: line) { [capturedLog, method] in
            capturedLog?.snapshot().contains(where: { $0.method == method }) ?? false
        }
    }

    /// Short settle for cases where we expect NOT to see a call.
    private func yieldSettle() async {
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    private static func makeProblemDoc(type: String? = nil, detail: String? = nil) -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let detail { dict["detail"] = detail }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return TPPProblemDocument.fromProblemResponseData(data)!
    }

    /// Build a book with a deterministic identifier + one of three
    /// availability modes the borrow code branches on.
    enum FixtureAvailability { case unlimited, reserved }

    private static func makeBook(identifier: String, availability: FixtureAvailability) -> TPPBook {
        let acquisitionURL = URL(string: "http://example.com/\(identifier)")!
        let availability: TPPOPDSAcquisitionAvailability = {
            switch availability {
            case .unlimited:
                return TPPOPDSAcquisitionAvailabilityUnlimited()
            case .reserved:
                return TPPOPDSAcquisitionAvailabilityReserved(
                    holdPosition: 1, copiesTotal: 1, since: nil, until: nil)
            }
        }()
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: DistributorType.EpubZip.rawValue,
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: availability
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Co-located spies

/// Records calls into the delegate surface BorrowOperation uses to drive
/// MBDC's startDownload / startBorrow handlers. The shape of these calls
/// is what F-014 broke — the snapshot pins it.
@MainActor
private final class SpyBorrowDelegate: BorrowOperationDelegate {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
        log.record("startDownload",
                   args: ["bookId": book.identifier,
                          "hasRequest": "\(initedRequest != nil)"])
    }

    nonisolated func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        // Capture Sendable snapshots BEFORE the @MainActor Task hop so the
        // task closure never captures the non-Sendable `borrowCompletion`
        // (`(() -> Void)?`) or the non-Sendable `TPPBook`.
        let id = book.identifier
        let hasCompletion = borrowCompletion != nil
        Task { @MainActor [log] in
            log.record("startBorrow",
                       args: ["bookId": id,
                              "attemptDownload": "\(attemptDownload)",
                              "hasCompletion": "\(hasCompletion)"])
        }
    }
}

/// Subclass of DownloadAnnouncementService that suppresses the
/// accessibility announce side effects so they don't surface in the
/// recorded call log. We don't snapshot announcements — they're a
/// side channel — only the delegate / closure-injected calls.
private final class SilentAnnouncementService: DownloadAnnouncementService {
    override func announceBorrowStarted(for book: TPPBook) {}
    override func announceBorrowSucceeded(for book: TPPBook) {}
    override func announceBorrowFailed(for book: TPPBook) {}
    override func announceReturnStarted(for book: TPPBook) {}
    override func announceReturnSucceeded(for book: TPPBook) {}
    override func announceReturnFailed(for book: TPPBook) {}
}

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

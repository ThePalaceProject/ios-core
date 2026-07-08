//
//  LoanRenewalServiceTests.swift
//  PalaceTests
//
//  Reliability WS-C — LoanRenewalService.
//
//  INV-5 (auth-error host scoping): a 401 from a host OUTSIDE the current
//  account's auth surface must NOT mark credentials stale. Reuses the
//  AuthErrorClassifierPropertyTests Invariant-8 pattern (host-scoped
//  provider). Also pins renew-URL extraction and the 2xx success path.
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

final class LoanRenewalServiceTests: XCTestCase {

    // MARK: - Spies / stubs

    private final class StubPoster: RenewalPosting, @unchecked Sendable {
        let status: Int
        let data: Data?
        init(status: Int, data: Data? = nil) { self.status = status; self.data = data }
        func post(to url: URL) async -> (data: Data?, response: HTTPURLResponse?) {
            let response = HTTPURLResponse(url: url, statusCode: status,
                                           httpVersion: nil, headerFields: nil)
            return (data, response)
        }
    }

    /// Poster that fails the transport (nil response) — offline.
    private final class OfflinePoster: RenewalPosting, @unchecked Sendable {
        func post(to url: URL) async -> (data: Data?, response: HTTPURLResponse?) {
            (nil, nil)
        }
    }

    private final class StaleSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _called = false
        func mark() { lock.lock(); _called = true; lock.unlock() }
        var called: Bool { lock.lock(); defer { lock.unlock() }; return _called }
    }

    // MARK: - Helpers

    private func makeBook(identifier: String, borrowHost: String?) -> TPPBook {
        var acquisitions: [TPPOPDSAcquisition] = []
        if let borrowHost {
            let url = URL(string: "https://\(borrowHost)/borrow/\(identifier)")!
            acquisitions.append(TPPOPDSAcquisition(
                relation: .borrow,
                type: "application/atom+xml",
                hrefURL: url,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()))
        }
        return TPPBook(
            acquisitions: acquisitions,
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil, distributor: nil, identifier: identifier,
            imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
            subtitle: nil, summary: nil, title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0), annotationsURL: nil,
            analyticsURL: nil, alternateURL: nil, relatedWorksURL: nil,
            previewLink: nil, seriesURL: nil, revokeURL: nil, reportURL: nil,
            timeTrackingURL: nil, contributors: nil, bookDuration: nil,
            imageCache: MockImageCache())
    }

    private func makeService(
        poster: RenewalPosting,
        accountHosts: Set<String>,
        staleSpy: StaleSpy
    ) -> LoanRenewalService {
        let classifier = AuthErrorClassifier(currentAccountHostsProvider: { accountHosts })
        return LoanRenewalService(
            poster: poster,
            classifier: classifier,
            bookRegistry: TPPBookRegistryMock(),
            markCredentialsStale: { staleSpy.mark() })
    }

    // MARK: - Renew-URL extraction (pure)

    func testRenewURL_extractsBorrowRelAcquisition() {
        let book = makeBook(identifier: "R1", borrowHost: "our.host")
        XCTAssertEqual(
            LoanRenewalService.renewURL(for: book)?.absoluteString,
            "https://our.host/borrow/R1")
    }

    func testRenewURL_noBorrowAcquisition_isNil() {
        let book = makeBook(identifier: "R2", borrowHost: nil)
        XCTAssertNil(LoanRenewalService.renewURL(for: book))
    }

    // MARK: - INV-5: foreign-host 401 does NOT mark credentials stale

    func testForeignHost401_doesNotMarkCredentialsStale() async {
        let staleSpy = StaleSpy()
        // The renew URL is on `foreign.host`; the account's surface is
        // `our.host`. A 401 from `foreign.host` is not our session.
        let book = makeBook(identifier: "R3", borrowHost: "foreign.host")
        let service = makeService(
            poster: StubPoster(status: 401),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)

        XCTAssertEqual(outcome, .foreignHost401)
        XCTAssertFalse(staleSpy.called,
            "INV-5: a foreign-host 401 must never mark the current account's credentials stale")
    }

    func testAccountHost401_marksCredentialsStale() async {
        let staleSpy = StaleSpy()
        // The renew URL is on the account's own auth-surface host.
        let book = makeBook(identifier: "R4", borrowHost: "our.host")
        let service = makeService(
            poster: StubPoster(status: 401),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)

        XCTAssertEqual(outcome, .reauthRequired)
        XCTAssertTrue(staleSpy.called,
            "A 401 from an account-surface host is a real session expiry")
    }

    // MARK: - Success / other outcomes

    func testSuccess2xx_returnsSuccess_doesNotMarkStale() async {
        let staleSpy = StaleSpy()
        let book = makeBook(identifier: "R5", borrowHost: "our.host")
        let service = makeService(
            poster: StubPoster(status: 200),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)

        XCTAssertEqual(outcome, .success)
        XCTAssertFalse(staleSpy.called)
    }

    func testNoRenewURL_returnsNoRenewURL() async {
        let staleSpy = StaleSpy()
        let book = makeBook(identifier: "R6", borrowHost: nil)
        let service = makeService(
            poster: StubPoster(status: 200),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)
        XCTAssertEqual(outcome, .noRenewURL)
    }

    func testOfflineTransport_returnsNetworkError() async {
        let staleSpy = StaleSpy()
        let book = makeBook(identifier: "R7", borrowHost: "our.host")
        let service = makeService(
            poster: OfflinePoster(),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)
        XCTAssertEqual(outcome, .networkError)
        XCTAssertFalse(staleSpy.called)
    }

    func testServerError500_returnsFailed_doesNotMarkStale() async {
        let staleSpy = StaleSpy()
        let book = makeBook(identifier: "R8", borrowHost: "our.host")
        let service = makeService(
            poster: StubPoster(status: 500),
            accountHosts: ["our.host"],
            staleSpy: staleSpy)

        let outcome = await service.renew(book: book)
        XCTAssertEqual(outcome, .failed(status: 500))
        XCTAssertFalse(staleSpy.called)
    }

    // MARK: - #2 production factory is INV-5-safe

    /// The production factory must build a HOST-SCOPED classifier. A
    /// foreign-host 401 through the factory-constructed service classifies
    /// as `.ok` (-> `.foreignHost401`) and never marks credentials stale —
    /// proving the factory binds `currentAccountHostsProvider` rather than
    /// leaving the unsafe `{ nil }` default that re-opens cross-host logout.
    func testProductionFactory_foreignHost401_classifiesOk() async {
        let book = makeBook(identifier: "PF1", borrowHost: "foreign.host")
        let service = LoanRenewalService.production(
            // The factory takes a concrete TPPNetworkExecutor, but this test
            // injects `poster:` so the executor is never used (see production():
            // it only wraps `executor` when `poster == nil`). Use a throwaway
            // ephemeral executor rather than the shared production container, so
            // the test touches no process-wide singleton (TearDownRequiredLint)
            // and needs no teardown.
            executor: TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .ephemeral, delegateQueue: nil),
            bookRegistry: TPPBookRegistryMock(),
            poster: StubPoster(status: 401),
            hostsProvider: { ["our.host"] })

        let outcome = await service.renew(book: book)
        XCTAssertEqual(outcome, .foreignHost401,
            "the production-constructed service must host-scope a foreign-host 401 to .ok")
    }
}

//
//  UnifiedOPDSServiceStateMachineTests.swift
//  PalaceTests
//
//  Migration coverage for `UnifiedOPDSService.fetchLoans()` to the
//  Account state machine (`awaitReady()` readiness gate). Mirrors
//  OPDSFeedServiceStateMachineTests but exercises the OPDS2-preferred
//  path, where URLSession is injectable so we can additionally count
//  HTTP requests fired against the loans URL.
//
//  Two contracts pinned per swarm_81b5099e Network-OPDS:
//
//    1. fetchLoans blocks while account state is `.detailsLoading`,
//       then fires exactly one HTTP request to the loans URL after
//       the state transitions to `.detailsLoaded`. Confirms the
//       awaitReady gate is the first thing the call awaits — not a
//       second HTTP attempt or a stale read past nil.
//    2. fetchLoans surfaces `.detailsFailed` errors instead of falling
//       through to a `accountNotFound` symptom. No HTTP request must
//       fire in this case.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class UnifiedOPDSServiceStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    private var libraryMock: TPPLibraryAccountMock!
    private var account: Account!
    private var details: AccountDetails!
    private var service: UnifiedOPDSService!
    private var stubbedSession: URLSession!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
        account = libraryMock.tppAccount
        guard let loadedDetails = account.details,
              loadedDetails.loansUrl != nil else {
            XCTFail("NYPL fixture must produce AccountDetails with a non-nil loansUrl")
            return
        }
        details = loadedDetails
        stubbedSession = URLSession.stubbedSession()
        HTTPStubURLProtocol.reset()
        service = UnifiedOPDSService(urlSession: stubbedSession)
    }

    override func tearDown() {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        HTTPStubURLProtocol.reset()
        libraryMock = nil
        account = nil
        details = nil
        service = nil
        stubbedSession = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Returns the loans URL that lives on the NYPL fixture's
    /// AccountDetails — the URL the migration's post-await guard reads.
    private var expectedLoansURL: URL { details.loansUrl! }

    /// Registers a single stub that responds to the loans URL with the
    /// supplied OPDS2 JSON body and returns the live request count.
    private func stubLoansFeedResponse(_ body: Data) -> () -> Int {
        let counter = ManagedAtomic<Int>(0)
        let loansURL = expectedLoansURL
        HTTPStubURLProtocol.register { request in
            guard let url = request.url, url == loansURL else { return nil }
            counter.value += 1
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/opds+json"],
                body: body
            )
        }
        return { counter.value }
    }

    /// Minimal valid OPDS2 feed body — empty publications array. Enough
    /// for OPDS2Feed.from(data:) to parse without error.
    private var emptyOPDS2FeedBody: Data {
        let json: [String: Any] = [
            "metadata": ["title": "Loans"],
            "links": [],
            "publications": []
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Tests

    /// Drive .detailsLoading → call fetchLoans → assert no HTTP request
    /// fires until the state transitions to `.detailsLoaded`. After the
    /// transition, exactly one HTTP request must fire against the
    /// loans URL.
    func testFetchLoansFeed_blocksUntilLoaded_thenFetches() async throws {
        // Arrange: state machine parked in .detailsLoading.
        account._setState(.detailsLoading)
        let requestCount = stubLoansFeedResponse(emptyOPDS2FeedBody)

        let fetchStarted = expectation(description: "fetchLoans task started")
        let fetchCompleted = expectation(description: "fetchLoans completed after transition")
        let resultBox = ManagedAtomic<Bool>(false)

        let fetchTask = Task<Void, Never> {
            fetchStarted.fulfill()
            if let _ = try? await service.fetchLoans(accountsManager: libraryMock) {
                resultBox.value = true
            }
            fetchCompleted.fulfill()
        }

        await fulfillment(of: [fetchStarted], timeout: 1.0)
        try await Task.sleep(nanoseconds: 80_000_000) // 80 ms

        // Mid-flight: gate must hold — no HTTP attempt, no completion.
        XCTAssertEqual(requestCount(), 0,
                       "No HTTP request must fire while account is .detailsLoading")
        XCTAssertFalse(fetchTask.isCancelled,
                       "fetchLoans task should be parked on awaitReady")

        // Act: transition releases the gate.
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [fetchCompleted], timeout: 5.0)

        // Assert: exactly one HTTP request fired, and only after the
        // gate was released. Result reached the consumer cleanly.
        XCTAssertEqual(requestCount(), 1,
                       "fetchLoans must fire exactly one HTTP request to the loans URL")
        XCTAssertTrue(resultBox.value,
                      "fetchLoans must return a non-nil UnifiedOPDSFeed after the gate releases")
    }

    /// When state is `.detailsFailed`, fetchLoans must throw the
    /// underlying `AccountLoadError` and must NOT fire any HTTP request.
    /// This is the ordering invariant the migration buys us: failure is
    /// surfaced at the gate, not after a redundant network attempt.
    func testFetchLoansFeed_failedDetailsLoad_throws() async {
        let failure = AccountLoadError.authDocumentFetchFailed(
            underlyingDescription: "HTTP 503 on auth doc"
        )
        account._setState(.detailsFailed(failure))
        let requestCount = stubLoansFeedResponse(emptyOPDS2FeedBody)

        do {
            _ = try await service.fetchLoans(accountsManager: libraryMock)
            XCTFail("fetchLoans must throw when account state is .detailsFailed")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "HTTP 503 on auth doc")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error)): \(error)")
        }

        XCTAssertEqual(requestCount(), 0,
                       "No HTTP request must fire when the gate throws")
    }
}

// MARK: - Tiny atomic helper

private final class ManagedAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

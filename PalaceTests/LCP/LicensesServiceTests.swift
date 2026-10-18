//
//  LicensesServiceTests.swift
//  PalaceTests
//
//  Tests for TPPLicensesService: acquirePublication, pathInZip.
//  Covers High-priority coverage gap: acquirePublication.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

#if LCP

@MainActor
final class LicensesServiceTests: XCTestCase {

    private var sut: TPPLicensesService!

    override func setUp() {
        super.setUp()
        sut = TPPLicensesService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - pathInZip Tests

    func testPathInZip_mapsEveryContentTypeToTheCorrectPath() {
        let cases: [(type: String?, expected: String?)] = [
            (ContentTypeEpubZip as String,       "META-INF/license.lcpl"),
            (ContentTypeReadiumLCP as String,    "license.lcpl"),
            (ContentTypeReadiumLCPPDF as String, "license.lcpl"),
            (ContentTypePDFLCP as String,        "license.lcpl"),
            (ContentTypeAudiobookLCP as String,  "license.lcpl"),
            (nil,                                nil),
            ("application/octet-stream",         nil),
        ]

        for (type, expected) in cases {
            let link = TPPLCPLicenseLink(rel: nil, href: nil, type: type,
                                          title: nil, length: nil, hash: nil)
            XCTAssertEqual(sut.pathInZip(for: link), expected,
                           "pathInZip(for: type=\(type ?? "nil")) should map to \(expected ?? "nil")")
        }
    }

    // MARK: - acquirePublication Tests

    func testAcquirePublication_WithInvalidLCPLFile_CompletesWithError() {
        // Create a temporary file with invalid LCP license content
        let tempDir = FileManager.default.temporaryDirectory
        let invalidLcpl = tempDir.appendingPathComponent("invalid_\(UUID().uuidString).lcpl")
        try? Data("not a valid license".utf8).write(to: invalidLcpl)

        let expectation = XCTestExpectation(description: "Completion called")

        let task = sut.acquirePublication(from: invalidLcpl, progress: { _ in }, completion: { localUrl, error in
            XCTAssertNil(localUrl, "Should not return a URL for invalid license")
            XCTAssertNotNil(error, "Should return an error for invalid license")
            expectation.fulfill()
        })

        XCTAssertNil(task, "Should not return a task for invalid license")

        wait(for: [expectation], timeout: 2.0)

        // Cleanup
        try? FileManager.default.removeItem(at: invalidLcpl)
    }

    func testAcquirePublication_WithNonexistentFile_CompletesWithError() {
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).lcpl")

        let expectation = XCTestExpectation(description: "Completion called")

        let task = sut.acquirePublication(from: nonexistentURL, progress: { _ in }, completion: { localUrl, error in
            XCTAssertNil(localUrl)
            XCTAssertNotNil(error)
            expectation.fulfill()
        })

        XCTAssertNil(task)

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - TPPLicensesServiceError Tests

    func testLicensesServiceError_licenseError_exposesMessageViaDescriptionVerbatim() {
        // .description must return the caller's message unchanged — used by
        // UI alerts and Crashlytics. Guards against changes that prefix,
        // trim, or otherwise mangle the error text on its way to the user.
        XCTAssertEqual(TPPLicensesServiceError.licenseError(message: "simple").description,
                       "simple")
        XCTAssertEqual(TPPLicensesServiceError.licenseError(message: "").description,
                       "")
        let multiline = "line one\nline two\twith tab"
        XCTAssertEqual(TPPLicensesServiceError.licenseError(message: multiline).description,
                       multiline,
                       "whitespace inside the message must be preserved verbatim")
    }
}

#endif

// MARK: - Transfer budget and resumption

/// A streamed LCP audiobook archive is one or two gigabytes, and the transfer
/// policy has to survive a patron's connection rather than a developer's.
///
/// Measured on a patron's device: ~4.3 MB/s, so a 1,896,374,144-byte archive
/// needs about 441 s at full speed. The previous 600 s resource cap left almost
/// no margin, and nothing kept resume data, so every expiry restarted from byte
/// zero and re-saturated the same link. The device log shows 22 failed
/// transfers over six weeks, 8 of them "The request timed out", and the archive
/// never completing.
final class LicensesServiceTransferPolicyTests: XCTestCase {

    /// The archive measured on the patron's device, and their measured rate.
    private let archiveBytes: Double = 1_896_374_144
    private let measuredBytesPerSecond: Double = 4_300_000

    func testResourceTimeout_coversTheMeasuredArchiveOnTheMeasuredLink() {
        let needed = archiveBytes / measuredBytesPerSecond   // ~441 s
        XCTAssertGreaterThan(
            TPPLicensesService.publicationResourceTimeout,
            needed,
            """
            the budget must cover a full transfer at the rate a patron actually \
            gets, or the download is killed every time and restarts from zero
            """
        )
    }

    /// Margin, not just sufficiency: a link that halves mid-transfer is the
    /// observed case, not a hypothetical one.
    func testResourceTimeout_leavesMarginForALinkThatDegrades() {
        let neededAtHalfRate = archiveBytes / (measuredBytesPerSecond / 2)  // ~882 s
        XCTAssertGreaterThan(
            TPPLicensesService.publicationResourceTimeout,
            neededAtHalfRate,
            "the patron's link was observed collapsing mid-transfer, not holding steady"
        )
    }

    /// A stall should still be caught — the budget is for the whole transfer,
    /// not a licence to hang forever on a dead socket.
    func testRequestTimeout_stillBoundsAStalledSocket() {
        XCTAssertLessThanOrEqual(
            TPPLicensesService.publicationRequestTimeout,
            120,
            "a socket delivering nothing must still fail promptly"
        )
        XCTAssertGreaterThan(TPPLicensesService.publicationRequestTimeout, 0)
    }

    // MARK: Resumption

    func testResumeAction_errorCarryingResumeData_resumes() {
        let data = Data("partial".utf8)
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSURLSessionDownloadTaskResumeData: data]
        )
        XCTAssertEqual(
            TPPLicensesService.resumeAction(for: error, attemptsSoFar: 0),
            .resume(data),
            "a timed-out transfer that left resume data must continue, not restart from zero"
        )
    }

    func testResumeAction_errorWithoutResumeData_givesUp() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(
            TPPLicensesService.resumeAction(for: error, attemptsSoFar: 0),
            .giveUp,
            "with nothing to resume from there is no cheaper option than reporting failure"
        )
    }

    func testResumeAction_cancellation_isNotRetried() {
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled,
            userInfo: [NSURLSessionDownloadTaskResumeData: Data("partial".utf8)]
        )
        XCTAssertEqual(
            TPPLicensesService.resumeAction(for: error, attemptsSoFar: 0),
            .giveUp,
            "a cancelled transfer was cancelled on purpose; resuming it fights the caller"
        )
    }

    func testResumeAction_atTheAttemptCap_givesUp() {
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSURLSessionDownloadTaskResumeData: Data("partial".utf8)]
        )
        XCTAssertEqual(
            TPPLicensesService.resumeAction(
                for: error,
                attemptsSoFar: TPPLicensesService.maxResumeAttempts
            ),
            .giveUp,
            "resuming forever on a link that never recovers is a battery and data leak"
        )
    }

    /// The boundary: one below the cap still resumes, so the cap is inclusive of
    /// the attempts actually taken rather than off by one.
    func testResumeAction_justBelowTheCap_stillResumes() {
        let data = Data("partial".utf8)
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSURLSessionDownloadTaskResumeData: data]
        )
        XCTAssertEqual(
            TPPLicensesService.resumeAction(
                for: error,
                attemptsSoFar: TPPLicensesService.maxResumeAttempts - 1
            ),
            .resume(data)
        )
    }
}

// MARK: - Holding the archive fetch while a chapter loads

/// The patron's chapter and the background fetch of the same archive compete
/// for one link, so a load borrows the link for its duration.
///
/// The hold must also be impossible to leak: a load that never reports its end
/// would otherwise suspend the patron's download for the life of the process.
final class LCPPublicationTransferHoldTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LCPPublicationTransfer.resetForTesting()
    }

    override func tearDown() {
        LCPPublicationTransfer.resetForTesting()
        super.tearDown()
    }

    func testNoHoldTaken_isNotInForce() {
        XCTAssertFalse(
            LCPPublicationTransfer.holdIsInForce(heldSince: nil, now: Date()),
            "with no load in flight the fetch must run at full speed"
        )
    }

    func testFreshHold_isInForce() {
        let t0 = Date()
        XCTAssertTrue(
            LCPPublicationTransfer.holdIsInForce(heldSince: t0, now: t0.addingTimeInterval(1))
        )
    }

    /// The case that matters: a load that never reports its end.
    func testHoldPastItsLimit_isNoLongerInForce() {
        let t0 = Date()
        XCTAssertFalse(
            LCPPublicationTransfer.holdIsInForce(
                heldSince: t0,
                now: t0.addingTimeInterval(LCPPublicationTransfer.maxHold + 1)
            ),
            "a load that never ended must not suspend the download indefinitely"
        )
    }

    /// Exactly at the limit the hold lifts, so the bound is not off by one.
    func testHoldExactlyAtItsLimit_isNoLongerInForce() {
        let t0 = Date()
        XCTAssertFalse(
            LCPPublicationTransfer.holdIsInForce(
                heldSince: t0,
                now: t0.addingTimeInterval(LCPPublicationTransfer.maxHold)
            )
        )
    }

    /// The limit has to sit below the claim that tracks the transfer, or a held
    /// fetch outlives the bookkeeping that would have aged it out.
    func testHoldLimit_isBelowTheInflightClaimTimeout() {
        XCTAssertLessThan(
            LCPPublicationTransfer.maxHold,
            LocalBookContentService.inflightContentDownloadIdleTimeout,
            "a hold must not outlive the in-flight claim for the same transfer"
        )
    }
}

// MARK: - The delegate's failure path

/// Drives `didCompleteWithError` directly, because the resume decision only
/// matters through the callback that acts on it — and mutation reported both
/// of those lines uncovered when only the pure policy was tested.
final class LicensesServiceCompletionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LCPPublicationTransfer.resetForTesting()
    }

    override func tearDown() {
        LCPPublicationTransfer.resetForTesting()
        super.tearDown()
    }

    /// A failure with nothing to resume from is reported to the caller.
    func testCompletionWithUnresumableError_reportsFailure() {
        let service = TPPLicensesService()
        var reported: Error?
        var calls = 0
        service.completionHandler = { _, error in calls += 1; reported = error }

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        service.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.invalid")!), didCompleteWithError: error)

        XCTAssertEqual(calls, 1, "the caller must learn the transfer failed")
        XCTAssertEqual((reported as NSError?)?.code, NSURLErrorTimedOut)
    }

    /// A cancellation is deliberate, so it is not surfaced as a failure.
    func testCompletionWithCancellation_reportsNothing() {
        let service = TPPLicensesService()
        var calls = 0
        service.completionHandler = { _, _ in calls += 1 }

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        service.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.invalid")!), didCompleteWithError: error)

        XCTAssertEqual(calls, 0, "a cancelled transfer was cancelled on purpose")
    }

    /// Success must not be reported as a failure.
    func testCompletionWithNoError_reportsNothing() {
        let service = TPPLicensesService()
        var calls = 0
        service.completionHandler = { _, _ in calls += 1 }

        service.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.invalid")!), didCompleteWithError: nil)

        XCTAssertEqual(calls, 0)
    }
}

// MARK: - The hold state machine

/// Covers the stateful half of the hold. The pure predicate was tested
/// separately; mutation showed these guards executed by nothing.
final class LCPPublicationTransferStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LCPPublicationTransfer.resetForTesting()
    }

    override func tearDown() {
        LCPPublicationTransfer.resetForTesting()
        super.tearDown()
    }

    func testHoldThenRelease_returnsTheLink() {
        XCTAssertFalse(LCPPublicationTransfer.isHolding)
        LCPPublicationTransfer.holdForStreamingLoad()
        XCTAssertTrue(LCPPublicationTransfer.isHolding, "a load in flight holds the link")
        LCPPublicationTransfer.releaseStreamingLoad()
        XCTAssertFalse(LCPPublicationTransfer.isHolding, "the load ended, so the fetch resumes")
    }

    /// Begin/end are announced per load and can arrive twice; a second hold
    /// must not move the clock, or a stream of loads would defer expiry forever.
    func testSecondHold_doesNotRestartTheClock() {
        let t0 = Date()
        LCPPublicationTransfer.holdForStreamingLoad(now: t0)
        LCPPublicationTransfer.holdForStreamingLoad(now: t0.addingTimeInterval(30))
        LCPPublicationTransfer.releaseIfExpired(now: t0.addingTimeInterval(LCPPublicationTransfer.maxHold + 1))
        XCTAssertFalse(
            LCPPublicationTransfer.isHolding,
            "expiry is measured from the first hold, not the most recent one"
        )
    }

    func testReleaseWithoutHold_isHarmless() {
        LCPPublicationTransfer.releaseStreamingLoad()
        XCTAssertFalse(LCPPublicationTransfer.isHolding)
    }

    func testExpiryBeforeTheLimit_keepsHolding() {
        let t0 = Date()
        LCPPublicationTransfer.holdForStreamingLoad(now: t0)
        LCPPublicationTransfer.releaseIfExpired(now: t0.addingTimeInterval(1))
        XCTAssertTrue(LCPPublicationTransfer.isHolding, "a load still in progress keeps the link")
    }

    /// Registering a new transfer clears any stale hold from a previous one.
    func testRegisteringANewTransfer_clearsAStaleHold() {
        LCPPublicationTransfer.holdForStreamingLoad()
        XCTAssertTrue(LCPPublicationTransfer.isHolding)
        LCPPublicationTransfer.register(nil)
        XCTAssertFalse(LCPPublicationTransfer.isHolding)
    }
}

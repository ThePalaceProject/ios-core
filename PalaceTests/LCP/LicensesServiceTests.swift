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

// MARK: - The delegate's failure path

/// Drives `didCompleteWithError` directly, because the resume decision only
/// matters through the callback that acts on it — and mutation reported both
/// of those lines uncovered when only the pure policy was tested.
final class LicensesServiceCompletionTests: XCTestCase {

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

// MARK: - Which session carries the archive

/// The archive transfer must survive the app being closed.
///
/// A 1.9 GB archive needs about 441 s of transfer at the 4.3 MB/s measured on
/// a patron's device. The googleapis.com branch used an ephemeral session,
/// which is in-memory only and dies with the process, and nothing persisted
/// resume data — so every app restart began the transfer again at byte zero
/// and it never completed. The sibling branch already used a background
/// session with a stable identifier "across app launches" for exactly this.
final class LicensesServiceSessionPolicyTests: XCTestCase {

    func testGoogleStorageHost_requiresCredentialIsolation() {
        XCTAssertTrue(
            TPPLicensesService.requiresCredentialIsolation(host: "storage.googleapis.com"),
            "no credentials may be sent to googleapis.com"
        )
    }

    func testOtherHosts_doNotRequireCredentialIsolation() {
        XCTAssertFalse(
            TPPLicensesService.requiresCredentialIsolation(host: "contentserver.stage.dtsbytebooks.com")
        )
    }

    func testMissingHost_isTreatedAsRequiringIsolation() {
        XCTAssertTrue(
            TPPLicensesService.requiresCredentialIsolation(host: nil),
            "an unknown host is the cautious case: send nothing"
        )
    }

    /// Case must not decide whether credentials are withheld.
    func testHostMatchingIsCaseInsensitive() {
        XCTAssertTrue(
            TPPLicensesService.requiresCredentialIsolation(host: "Storage.GoogleAPIs.COM")
        )
    }

    /// A background configuration that carries no cookie or credential storage
    /// gives the isolation the ephemeral session was chosen for, while still
    /// surviving app termination.
    func testArchiveSessionConfiguration_isBackgroundAndCarriesNoCredentials() {
        let config = TPPLicensesService.publicationSessionConfiguration(
            identifier: "test.identifier", isolateCredentials: true
        )
        XCTAssertNotNil(config.identifier, "an ephemeral session cannot survive the app closing")
        XCTAssertNil(config.httpCookieStorage, "no cookies may reach the storage host")
        XCTAssertNil(config.urlCredentialStorage, "no credentials may reach the storage host")
        XCTAssertEqual(config.timeoutIntervalForResource, TPPLicensesService.publicationResourceTimeout)
        XCTAssertEqual(config.timeoutIntervalForRequest, TPPLicensesService.publicationRequestTimeout)
    }

    func testArchiveSessionConfiguration_withoutIsolation_keepsStorage() {
        let config = TPPLicensesService.publicationSessionConfiguration(
            identifier: "test.identifier2", isolateCredentials: false
        )
        XCTAssertNotNil(config.identifier)
        XCTAssertNotNil(config.httpCookieStorage)
    }
}

#if DEBUG
// MARK: - The simulator throttle
#endif

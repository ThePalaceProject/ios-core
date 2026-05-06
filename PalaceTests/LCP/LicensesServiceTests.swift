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
@testable import Palace

#if LCP

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
        // UI alerts and Crashlytics. Guards against mutations that prefix,
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

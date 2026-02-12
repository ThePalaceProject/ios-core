//
//  LicensesServiceTests.swift
//  PalaceTests
//
//  Tests for TPPLicensesService: acquirePublication, pathInZip.
//  Covers QAAtlas high-priority gap: acquirePublication.
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

    func testPathInZip_ForEpubZipType_ReturnsMetaInfPath() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: ContentTypeEpubZip as String, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertEqual(path, "META-INF/license.lcpl")
    }

    func testPathInZip_ForReadiumLCPType_ReturnsLicensePath() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: ContentTypeReadiumLCP as String, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertEqual(path, "license.lcpl")
    }

    func testPathInZip_ForReadiumLCPPDFType_ReturnsLicensePath() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: ContentTypeReadiumLCPPDF as String, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertEqual(path, "license.lcpl")
    }

    func testPathInZip_ForPDFLCPType_ReturnsLicensePath() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: ContentTypePDFLCP as String, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertEqual(path, "license.lcpl")
    }

    func testPathInZip_ForAudiobookLCPType_ReturnsLicensePath() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: ContentTypeAudiobookLCP as String, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertEqual(path, "license.lcpl")
    }

    func testPathInZip_ForNilType_ReturnsNil() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: nil, title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertNil(path)
    }

    func testPathInZip_ForUnknownType_ReturnsNil() {
        let link = TPPLCPLicenseLink(rel: nil, href: nil, type: "application/octet-stream", title: nil, length: nil, hash: nil)

        let path = sut.pathInZip(for: link)
        XCTAssertNil(path)
    }

    // MARK: - acquirePublication Tests

    func testAcquirePublication_WithInvalidLCPLFile_CompletesWithError() {
        // Create a temporary file with invalid LCP license content
        let tempDir = FileManager.default.temporaryDirectory
        let invalidLcpl = tempDir.appendingPathComponent("invalid_\(UUID().uuidString).lcpl")
        try? "not a valid license".data(using: .utf8)?.write(to: invalidLcpl)

        let expectation = XCTestExpectation(description: "Completion called")

        let task = sut.acquirePublication(from: invalidLcpl, progress: { _ in }) { localUrl, error in
            XCTAssertNil(localUrl, "Should not return a URL for invalid license")
            XCTAssertNotNil(error, "Should return an error for invalid license")
            expectation.fulfill()
        }

        XCTAssertNil(task, "Should not return a task for invalid license")

        wait(for: [expectation], timeout: 2.0)

        // Cleanup
        try? FileManager.default.removeItem(at: invalidLcpl)
    }

    func testAcquirePublication_WithNonexistentFile_CompletesWithError() {
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).lcpl")

        let expectation = XCTestExpectation(description: "Completion called")

        let task = sut.acquirePublication(from: nonexistentURL, progress: { _ in }) { localUrl, error in
            XCTAssertNil(localUrl)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        XCTAssertNil(task)

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - TPPLicensesServiceError Tests

    func testLicensesServiceError_HasDescription() {
        let error = TPPLicensesServiceError.licenseError(message: "Test error message")
        XCTAssertEqual(error.description, "Test error message")
    }
}

#else

// Stub test to register the test class even when LCP is not enabled
final class LicensesServiceTests: XCTestCase {

    func testLCPNotEnabled_SkipLicensesServiceTests() throws {
        throw XCTSkip("LCP is not enabled in this build configuration")
    }
}

#endif

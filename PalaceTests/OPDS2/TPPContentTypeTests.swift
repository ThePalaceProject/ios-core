//
//  TPPContentTypeTests.swift
//  PalaceTests
//
//  Tests for TPPBookContentType and SampleType/SamplePlayerError
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - TPPBookContentType Tests

final class TPPContentTypeTests: XCTestCase {

    // MARK: - from(mimeType:)

    func testFrom_NilMimeType_ReturnsUnsupported() {
        let result = TPPBookContentType.from(mimeType: nil)
        XCTAssertEqual(result, .unsupported)
    }

    func testFrom_EpubZip_ReturnsEpub() {
        let result = TPPBookContentType.from(mimeType: "application/epub+zip")
        XCTAssertEqual(result, .epub)
    }

    func testFrom_OctetStream_ReturnsEpub() {
        let result = TPPBookContentType.from(mimeType: "application/octet-stream")
        XCTAssertEqual(result, .epub)
    }

    func testFrom_OpenAccessPDF_ReturnsPDF() {
        let result = TPPBookContentType.from(mimeType: "application/pdf")
        XCTAssertEqual(result, .pdf)
    }

    func testFrom_OpenAccessAudiobook_ReturnsAudiobook() {
        let result = TPPBookContentType.from(mimeType: "application/audiobook+json")
        XCTAssertEqual(result, .audiobook)
    }

    func testFrom_UnknownMimeType_ReturnsUnsupported() {
        let result = TPPBookContentType.from(mimeType: "text/plain")
        XCTAssertEqual(result, .unsupported)
    }

    func testFrom_EmptyString_ReturnsUnsupported() {
        let result = TPPBookContentType.from(mimeType: "")
        XCTAssertEqual(result, .unsupported)
    }
}

// MARK: - SampleType Tests

final class SampleTypeTests: XCTestCase {

    func testRawValue_ContentTypeEpubZip() {
        XCTAssertEqual(SampleType.contentTypeEpubZip.rawValue, "application/epub+zip")
    }

    func testRawValue_OverdriveWeb() {
        XCTAssertEqual(SampleType.overdriveWeb.rawValue, "text/html")
    }

    func testRawValue_OpenAccessAudiobook() {
        XCTAssertEqual(SampleType.openAccessAudiobook.rawValue, "application/audiobook+json")
    }

    func testNeedsDownload_EpubZip_ReturnsTrue() {
        XCTAssertTrue(SampleType.contentTypeEpubZip.needsDownload)
    }

    func testNeedsDownload_OverdriveAudiobookMpeg_ReturnsTrue() {
        XCTAssertTrue(SampleType.overdriveAudiobookMpeg.needsDownload)
    }

    func testNeedsDownload_OverdriveAudiobookWaveFile_ReturnsTrue() {
        XCTAssertTrue(SampleType.overdriveAudiobookWaveFile.needsDownload)
    }

    func testNeedsDownload_OverdriveWeb_ReturnsFalse() {
        XCTAssertFalse(SampleType.overdriveWeb.needsDownload)
    }

    func testNeedsDownload_OpenAccessAudiobook_ReturnsFalse() {
        XCTAssertFalse(SampleType.openAccessAudiobook.needsDownload)
    }
}

// MARK: - SamplePlayerError Tests

final class SamplePlayerErrorTests: XCTestCase {

    func testNoSampleAvailable_IsError() {
        let error: Error = SamplePlayerError.noSampleAvailable
        XCTAssertTrue(error is SamplePlayerError)
    }

    func testSampleDownloadFailed_WithUnderlyingError() {
        let underlying = NSError(domain: "test", code: 42, userInfo: nil)
        let error = SamplePlayerError.sampleDownloadFailed(underlying)

        if case .sampleDownloadFailed(let inner) = error {
            XCTAssertEqual((inner as NSError?)?.code, 42)
        } else {
            XCTFail("Expected sampleDownloadFailed case")
        }
    }

    func testSampleDownloadFailed_WithoutUnderlyingError() {
        let error = SamplePlayerError.sampleDownloadFailed()

        if case .sampleDownloadFailed(let inner) = error {
            XCTAssertNil(inner)
        } else {
            XCTFail("Expected sampleDownloadFailed case")
        }
    }

    func testFileSaveFailed_WithUnderlyingError() {
        let underlying = NSError(domain: "fs", code: 13, userInfo: nil)
        let error = SamplePlayerError.fileSaveFailed(underlying)

        if case .fileSaveFailed(let inner) = error {
            XCTAssertEqual((inner as NSError?)?.code, 13)
        } else {
            XCTFail("Expected fileSaveFailed case")
        }
    }

    func testFileSaveFailed_WithoutUnderlyingError() {
        let error = SamplePlayerError.fileSaveFailed()

        if case .fileSaveFailed(let inner) = error {
            XCTAssertNil(inner)
        } else {
            XCTFail("Expected fileSaveFailed case")
        }
    }
}

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
        XCTAssertNotEqual(result, .epub)
        XCTAssertNotEqual(result, .pdf)
        XCTAssertNotEqual(result, .audiobook)
    }

    func testFrom_EpubZip_ReturnsEpub() {
        let result = TPPBookContentType.from(mimeType: "application/epub+zip")
        XCTAssertEqual(result, .epub)
        XCTAssertNotEqual(result, .pdf)
        XCTAssertNotEqual(result, .audiobook)
    }

    func testFrom_OctetStream_ReturnsEpub() {
        let result = TPPBookContentType.from(mimeType: "application/octet-stream")
        XCTAssertEqual(result, .epub)
        // Octet-stream is treated as EPUB (not PDF or audiobook)
        XCTAssertNotEqual(result, .unsupported)
    }

    func testFrom_OpenAccessPDF_ReturnsPDF() {
        let result = TPPBookContentType.from(mimeType: "application/pdf")
        XCTAssertEqual(result, .pdf)
        XCTAssertNotEqual(result, .epub)
        XCTAssertNotEqual(result, .audiobook)
    }

    func testFrom_OpenAccessAudiobook_ReturnsAudiobook() {
        let result = TPPBookContentType.from(mimeType: "application/audiobook+json")
        XCTAssertEqual(result, .audiobook)
        XCTAssertNotEqual(result, .epub)
        XCTAssertNotEqual(result, .pdf)
    }

    func testFrom_UnknownMimeType_ReturnsUnsupported() {
        let result = TPPBookContentType.from(mimeType: "text/plain")
        XCTAssertEqual(result, .unsupported)
        // Multiple unknown types must all be unsupported
        XCTAssertEqual(TPPBookContentType.from(mimeType: "image/jpeg"), .unsupported)
        XCTAssertEqual(TPPBookContentType.from(mimeType: "application/json"), .unsupported)
    }

    func testFrom_EmptyString_ReturnsUnsupported() {
        let result = TPPBookContentType.from(mimeType: "")
        XCTAssertEqual(result, .unsupported)
        // Empty and nil must both map to unsupported
        XCTAssertEqual(TPPBookContentType.from(mimeType: nil), .unsupported)
    }
}

// MARK: - SampleType Tests

final class SampleTypeTests: XCTestCase {

    func testRawValue_ContentTypeEpubZip() {
        XCTAssertEqual(SampleType.contentTypeEpubZip.rawValue, "application/epub+zip")
        // Raw value must be a valid MIME type string
        XCTAssertTrue(SampleType.contentTypeEpubZip.rawValue.contains("/"),
                      "MIME type must contain a forward slash")
        XCTAssertFalse(SampleType.contentTypeEpubZip.rawValue.isEmpty)
    }

    func testRawValue_OverdriveWeb() {
        XCTAssertEqual(SampleType.overdriveWeb.rawValue, "text/html")
        // Web samples do not need a local download
        XCTAssertFalse(SampleType.overdriveWeb.needsDownload,
                       "Overdrive web samples must not require a download")
    }

    func testRawValue_OpenAccessAudiobook() {
        XCTAssertEqual(SampleType.openAccessAudiobook.rawValue, "application/audiobook+json")
        // Open-access audiobook samples stream directly, no download needed
        XCTAssertFalse(SampleType.openAccessAudiobook.needsDownload,
                       "Open-access audiobook samples must not require a download")
    }

    func testNeedsDownload_EpubZip_ReturnsTrue() {
        XCTAssertTrue(SampleType.contentTypeEpubZip.needsDownload)
        // EPUB samples that need download must not be streaming types
        XCTAssertNotEqual(SampleType.contentTypeEpubZip.rawValue, SampleType.overdriveWeb.rawValue,
                          "EPUB zip and web sample must have different raw values")
    }

    func testNeedsDownload_OverdriveAudiobookMpeg_ReturnsTrue() {
        XCTAssertTrue(SampleType.overdriveAudiobookMpeg.needsDownload)
        // Downloadable types must be distinct from streaming types
        XCTAssertNotEqual(SampleType.overdriveAudiobookMpeg, SampleType.overdriveWeb,
                          "MPEG audiobook must be a different sample type than web")
    }

    func testNeedsDownload_OverdriveAudiobookWaveFile_ReturnsTrue() {
        XCTAssertTrue(SampleType.overdriveAudiobookWaveFile.needsDownload)
        // Wave file download type must differ from MPEG download type
        XCTAssertNotEqual(SampleType.overdriveAudiobookWaveFile, SampleType.overdriveAudiobookMpeg,
                          "Wave file and MPEG must be distinct sample types")
    }

    func testNeedsDownload_OverdriveWeb_ReturnsFalse() {
        XCTAssertFalse(SampleType.overdriveWeb.needsDownload)
        // Web samples must stream — confirm raw value is a well-known web MIME type
        XCTAssertEqual(SampleType.overdriveWeb.rawValue, "text/html",
                       "Overdrive web samples must have text/html MIME type")
    }

    func testNeedsDownload_OpenAccessAudiobook_ReturnsFalse() {
        XCTAssertFalse(SampleType.openAccessAudiobook.needsDownload)
        // Open-access audiobook and web sample are the only streaming types (needsDownload == false)
        XCTAssertFalse(SampleType.overdriveWeb.needsDownload,
                       "Overdrive web must also be streaming (no download needed)")
    }
}

// MARK: - SamplePlayerError Tests

final class SamplePlayerErrorTests: XCTestCase {

    func testNoSampleAvailable_IsError() {
        let error: Error = SamplePlayerError.noSampleAvailable
        XCTAssertTrue(error is SamplePlayerError)
        // noSampleAvailable is not the download-failure case
        if case .sampleDownloadFailed = error as! SamplePlayerError {
            XCTFail("noSampleAvailable must not match the sampleDownloadFailed case")
        }
        // It must also not be the file-save-failed case
        if case .fileSaveFailed = error as! SamplePlayerError {
            XCTFail("noSampleAvailable must not match the fileSaveFailed case")
        }
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

//
//  EpubSampleFactoryTests.swift
//  PalaceTests
//
//  Tests for EpubSampleFactory URL wrapper classes.
//

import XCTest
@testable import Palace

@MainActor
final class EpubSampleFactoryTests: XCTestCase {

    // MARK: - URL wrapper tests

    /// `EpubLocationSampleURL` and its `EpubSampleWebURL` subclass exist so
    /// downstream code can pattern-match on type to choose between local-file
    /// and web-fetch flows. Lock the polymorphism contract here:
    ///   - URL passes through both classes unchanged
    ///   - A `EpubSampleWebURL` instance dispatches as a web URL when
    ///     pattern-matched, NOT as the parent type
    ///   - A bare `EpubLocationSampleURL` does NOT match the web subclass
    /// A mutant that collapsed the subclass into the parent (or vice versa)
    /// would fail one of the `is` checks.
    func testSampleURLWrappers_polymorphismAllowsCallSiteRouting() {
        let local = EpubLocationSampleURL(url: URL(string: "file:///path/sample.epub")!)
        let web = EpubSampleWebURL(url: URL(string: "https://example.com/sample.epub")!)

        // URL passes through verbatim on both classes.
        XCTAssertEqual(local.url.absoluteString, "file:///path/sample.epub")
        XCTAssertEqual(web.url.absoluteString, "https://example.com/sample.epub")

        // Web URL dispatches as the SUBCLASS — call sites can route on this.
        XCTAssertTrue(web is EpubSampleWebURL,
                      "EpubSampleWebURL must pattern-match as the subclass for routing")

        // Bare local URL must NOT pattern-match as the web subclass — that
        // would falsely route file URLs through web-download paths.
        XCTAssertFalse(local is EpubSampleWebURL,
                       "EpubLocationSampleURL must NOT match as EpubSampleWebURL — guards against a hierarchy-collapse mutant")
    }

    // MARK: - SamplePlayerError tests

    /// `SamplePlayerError` is an enum with three cases — two carry an
    /// optional `Error` payload, one doesn't. The previous "_exists" tests
    /// were tautologies (an enum case always exists if the file compiles).
    /// Lock the structural contract instead: each case is distinct, each
    /// case is `Error`-conforming, and the payload-bearing cases preserve
    /// nil vs non-nil correctly.
    func testSamplePlayerError_threeDistinctCasesWithOptionalPayloads() {
        let none = SamplePlayerError.noSampleAvailable
        let downloadNil = SamplePlayerError.sampleDownloadFailed(nil)
        let downloadWith = SamplePlayerError.sampleDownloadFailed(NSError(domain: "x", code: 1))
        let saveNil = SamplePlayerError.fileSaveFailed(nil)
        let saveWith = SamplePlayerError.fileSaveFailed(NSError(domain: "x", code: 2))

        // Error conformance.
        XCTAssertNotNil(none as Error)
        XCTAssertNotNil(downloadNil as Error)
        XCTAssertNotNil(saveNil as Error)

        // Payload preservation: nil and non-nil are observably distinct.
        if case .sampleDownloadFailed(let e) = downloadNil { XCTAssertNil(e) }
        else { XCTFail("Expected .sampleDownloadFailed(nil)") }
        if case .sampleDownloadFailed(let e) = downloadWith { XCTAssertNotNil(e) }
        else { XCTFail("Expected .sampleDownloadFailed(error)") }

        if case .fileSaveFailed(let e) = saveNil { XCTAssertNil(e) }
        else { XCTFail("Expected .fileSaveFailed(nil)") }
        if case .fileSaveFailed(let e) = saveWith { XCTAssertNotNil(e) }
        else { XCTFail("Expected .fileSaveFailed(error)") }

        // Cross-case distinctness: download with an error must NOT match
        // the save case (guards against a copy-paste mutant in the enum).
        if case .fileSaveFailed = downloadWith {
            XCTFail("sampleDownloadFailed must not pattern-match as fileSaveFailed")
        }
    }

    func testSamplePlayerError_sampleDownloadFailed_withUnderlyingError() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: nil)
        let error = SamplePlayerError.sampleDownloadFailed(underlyingError)

        // Verify the error captures the underlying error
        if case .sampleDownloadFailed(let captured) = error {
            XCTAssertNotNil(captured)
        } else {
            XCTFail("Expected sampleDownloadFailed case")
        }
    }

    func testSamplePlayerError_fileSaveFailed_withUnderlyingError() {
        let underlyingError = NSError(domain: "test", code: 2, userInfo: nil)
        let error = SamplePlayerError.fileSaveFailed(underlyingError)

        if case .fileSaveFailed(let captured) = error {
            XCTAssertNotNil(captured)
        } else {
            XCTFail("Expected fileSaveFailed case")
        }
    }

    // MARK: - createSample Error Handling Tests

    func testCreateSample_withBookWithoutSample_returnsError() {
        // Create a book without a sample (hasSample: false is the default)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let completed = XCTestExpectation(description: "createSample completion fires")
        var receivedError: Error?
        EpubSampleFactory.createSample(book: book) { _, error in
            receivedError = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3.0)
        XCTAssertNotNil(receivedError,
                        "A book without a sample must yield an error via the completion")
    }
}

//
//  BookButtonMapperTests.swift
//  PalaceTests
//
//  Tests for BookButtonMapper - the single source of truth for
//  mapping TPPBookState to BookButtonState.
//

import XCTest
@testable import Palace

final class BookButtonMapperTests: XCTestCase {

    // MARK: - Direct State Mappings

    func testMapDownloading() {
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMapDownloadFailed() {
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadFailed)
    }

    func testMapDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadSuccessful)
    }

    func testMapDownloadNeeded() {
        let result = BookButtonMapper.map(
            registryState: .downloadNeeded,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadNeeded)
    }

    func testMapUsed() {
        let result = BookButtonMapper.map(
            registryState: .used,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .used)
    }

    func testMapHolding() {
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    func testMapReturning() {
        let result = BookButtonMapper.map(
            registryState: .returning,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .returning)
    }

    /// Phase 7 siblings audit fix: `.SAMLStarted` was previously falling through
    /// the if-cascade to `.unsupported` silently. The exhaustive switch now maps
    /// it to `.downloadInProgress`, matching the parallel `BookButtonState.init?`
    /// mapper (BookButtonState.swift) which treats SAML as part of the download
    /// flow. A user mid-SAML must NOT see "unsupported" — they must see progress.
    func testMapSAMLStarted_returnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .SAMLStarted,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress,
                       "SAMLStarted is part of the download flow — must render as in-progress, not unsupported")
    }

    // MARK: - isProcessingDownload Override

    func testProcessingDownloadOverridesState() {
        // Even if registry says downloadFailed, isProcessingDownload should show downloadInProgress
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testProcessingDownloadOverridesDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    // MARK: - Unregistered Falls Back to Availability

    func testUnregisteredWithNilAvailability() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .unsupported)
    }

    // MARK: - stateForAvailability Tests

    func testStateForNilAvailability() {
        let result = BookButtonMapper.stateForAvailability(nil)
        XCTAssertNil(result)
    }

    // MARK: - Consistency Tests

    /// Parameterized `.allCases` exhaustive coverage. Iterates **every**
    /// `TPPBookState` case (driven by the compiler-synthesized `.allCases`,
    /// NOT a hand-maintained list) and pins each case's expected mapping
    /// with neutral inputs (nil availability, isProcessingDownload=false).
    ///
    /// This is the **safety net** for the exhaustive-switch refactor: if a
    /// future contributor adds a new `TPPBookState` case, the production
    /// switch will fail to compile until they map it, AND this test will
    /// fail until they pin the expected button-state result here. The pair
    /// makes the "silent fall-through to .unsupported" trap impossible.
    ///
    /// Reference: Phase 7 siblings audit
    /// (`.forgeos/audits/phase7-synthesis-2026-05-26.md`). The same trap
    /// produced F-011 (audiobook first-open hang) when a `default:` arm
    /// swallowed `.downloadNeeded` silently.
    func testMap_coversAllTPPBookStates_withNeutralInputs() {
        let expected: [TPPBookState: BookButtonState] = [
            .unregistered:       .unsupported,        // nil availability → no signal → unsupported
            .downloadNeeded:     .downloadNeeded,
            .downloading:        .downloadInProgress,
            .downloadFailed:     .downloadFailed,
            .downloadSuccessful: .downloadSuccessful,
            .returning:          .returning,
            .holding:            .holding,            // no .ready availability → still in queue
            .used:               .used,
            .unsupported:        .unsupported,
            .SAMLStarted:        .downloadInProgress  // part of download flow (fixed in this PR)
        ]

        // .allCases is the source of truth — verify our expectations
        // dictionary is exhaustive. A new TPPBookState case will fail this
        // assertion before reaching the per-case mapping checks.
        XCTAssertEqual(Set(expected.keys), Set(TPPBookState.allCases),
                       "expected mappings must cover every TPPBookState.allCases — add the new case here AND to the production switch")

        for state in TPPBookState.allCases {
            let result = BookButtonMapper.map(
                registryState: state,
                availability: nil,
                isProcessingDownload: false
            )
            XCTAssertEqual(result, expected[state],
                           "TPPBookState.\(state) must map to \(expected[state]!) with neutral inputs (got \(result))")
        }
    }

    func testMappingIsDeterministic() {
        // Same inputs should always produce same outputs
        for _ in 0..<10 {
            let result1 = BookButtonMapper.map(
                registryState: .downloadSuccessful,
                availability: nil,
                isProcessingDownload: false
            )
            let result2 = BookButtonMapper.map(
                registryState: .downloadSuccessful,
                availability: nil,
                isProcessingDownload: false
            )
            XCTAssertEqual(result1, result2)
        }
    }
}

//
//  LCPPDFOpenProgressTests.swift
//  PalaceTests
//
//  State-machine + counter tests for `LCPPDFOpenProgress`, the
//  observable that drives the LCP-PDF loading view. The user-visible
//  symptom that motivates these tests: on the first device run the
//  progress bar got stuck at "1%" (the curve was wrong) and on the
//  next iteration jumped to "Finishing up…" too soon (premature
//  ceiling). The progress math has to be right or the loading UI
//  lies to users for the entire decrypt walk.
//
//  Phase transitions get round-trip coverage per CLAUDE.md
//  "Round-trip wiring tests required for state machines":
//
//    .idle → .preparing → .openingPublication → .decryptingContent
//          (auto-bump on first decrypt) → .extractingToDisk
//          (auto-bump on first extracted-byte record) → .loadingFirstPage
//          → .idle (via finish)
//
//  Tests deliberately cover the AUTO-TRANSITION seams — those are
//  the ones a mutation (flipping the `if phase == X` guard) can
//  silently break and leave the UI stuck on the wrong status text.
//

#if LCP

import XCTest
@testable import Palace

@MainActor
final class LCPPDFOpenProgressTests: XCTestCase {

    private let bookID = "urn:isbn:9781234567890"

    override func setUp() async throws {
        try await super.setUp()
        // Singleton sharing means previous tests can leave counters
        // behind — `finish()` only resets phase + identifier, not the
        // counter fields. Begin-then-finish gives a clean baseline:
        // `begin` zeroes every counter, `finish` then returns phase
        // to .idle so the test starts from a true cold state.
        LCPPDFOpenProgress.shared.begin(bookIdentifier: "test-reset")
        LCPPDFOpenProgress.shared.finish()
    }

    override func tearDown() async throws {
        LCPPDFOpenProgress.shared.finish()
        try await super.tearDown()
    }

    // MARK: - begin() initializes everything

    func testBegin_setsPhaseAndIdentifierAndZeroesCounters() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)

        XCTAssertEqual(progress.phase, .preparing)
        XCTAssertEqual(progress.bookIdentifier, bookID)
        XCTAssertEqual(progress.decryptedBlocks, 0)
        XCTAssertEqual(progress.cachedHits, 0)
        XCTAssertEqual(progress.bytesExtracted, 0)
        XCTAssertEqual(progress.totalExtractBytes, 0)
        XCTAssertTrue(LCPPDFOpenProgress.isOpenInProgress, "begin must flip the cross-actor flag")
    }

    func testBegin_clearsCountersFromPreviousOpen() {
        let progress = LCPPDFOpenProgress.shared
        // First open writes counts.
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.decryptingContent)
        progress.recordDecrypt(byteCount: 2_048)
        progress.recordDecrypt(byteCount: 2_048)
        progress.recordExtractedBytes(1_024)

        // Settle the nonisolated → MainActor hops.
        let firstOpenWait = expectation(description: "first-open counters published")
        Task { @MainActor in firstOpenWait.fulfill() }
        wait(for: [firstOpenWait], timeout: 1.0)
        XCTAssertGreaterThan(progress.decryptedBlocks, 0)

        // Second open must start from zero — a stale carry-over
        // would make the progress bar fake forward motion on the
        // new book.
        progress.begin(bookIdentifier: "urn:isbn:9789999999999")
        XCTAssertEqual(progress.decryptedBlocks, 0)
        XCTAssertEqual(progress.cachedHits, 0)
        XCTAssertEqual(progress.bytesExtracted, 0)
    }

    // MARK: - recordDecrypt counter + auto-transition

    func testRecordDecrypt_incrementsBlocksAndBytes() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.openingPublication)

        progress.recordDecrypt(byteCount: 2_064)
        progress.recordDecrypt(byteCount: 32_784)

        let wait = expectation(description: "decrypt records flushed to main actor")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(progress.decryptedBlocks, 2)
        XCTAssertEqual(progress.decryptedBytes, 2_064 + 32_784)
        XCTAssertEqual(progress.cachedHits, 0)
    }

    func testRecordDecrypt_autoTransitionsFromOpeningPublicationToDecrypting() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.openingPublication)

        progress.recordDecrypt(byteCount: 2_048)
        let wait = expectation(description: "phase transition published")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(progress.phase, .decryptingContent,
                       "first decrypt while opening must flip phase to decryptingContent")
    }

    func testRecordDecrypt_fromCache_incrementsCachedHitsNotBlocks() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.decryptingContent)

        progress.recordDecrypt(byteCount: 2_048, fromCache: true)
        progress.recordDecrypt(byteCount: 2_048, fromCache: true)

        let wait = expectation(description: "cache hits flushed")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(progress.cachedHits, 2)
        XCTAssertEqual(progress.decryptedBlocks, 0, "cached hits must NOT inflate the work-done counter")
        XCTAssertEqual(progress.decryptedBytes, 0, "cached bytes don't count toward AES work")
    }

    func testRecordDecrypt_whenIdle_doesNothing() {
        let progress = LCPPDFOpenProgress.shared
        // No begin() — phase stays .idle.
        progress.recordDecrypt(byteCount: 2_048)
        progress.recordDecrypt(byteCount: 2_048, fromCache: true)

        let wait = expectation(description: "settle")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        // Stray decrypts from other paths (e.g. an audiobook chunk
        // on a parallel actor) must not poison the next LCP-PDF open.
        XCTAssertEqual(progress.decryptedBlocks, 0)
        XCTAssertEqual(progress.cachedHits, 0)
        XCTAssertEqual(progress.phase, .idle)
    }

    // MARK: - recordExtractedBytes counter + auto-transition

    func testRecordExtractedBytes_incrementsBytesAndTransitionsPhase() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.openingPublication)

        progress.recordExtractedBytes(1_048_576) // 1MB chunk

        let wait = expectation(description: "extract bytes flushed")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(progress.bytesExtracted, 1_048_576)
        XCTAssertEqual(progress.phase, .extractingToDisk,
                       "first chunk write must transition phase to extractingToDisk")
    }

    // MARK: - percentComplete: bytes-based vs curve fallback

    func testPercentComplete_withByteTotal_returnsTrueRatio() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setTotalExtractBytes(100)
        progress.recordExtractedBytes(50)

        let wait = expectation(description: "bytes settled")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertEqual(progress.percentComplete, 50,
                       "with totalExtractBytes set, percent is a true bytes ratio")
    }

    func testPercentComplete_clampsAt99NotAt100() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setTotalExtractBytes(100)
        progress.recordExtractedBytes(100) // ratio = 1.0

        let wait = expectation(description: "bytes settled")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        // The bar must never reach 100 BEFORE the navigator paints
        // page 1 — 100% is reserved for "done." The reader-view
        // transition handler is what calls finish().
        XCTAssertEqual(progress.percentComplete, 99,
                       "saturated ratio must clamp at 99, not 100")
    }

    func testPercentComplete_withoutByteTotal_usesDecryptCurve() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.decryptingContent)
        // No totalExtractBytes — falls back to exponential decrypt curve.
        // Pump enough decrypts to push past the exponential→linear knee
        // at credit ≈ 145 blocks.
        for _ in 0..<300 {
            progress.recordDecrypt(byteCount: 2_048)
        }

        let wait = expectation(description: "decrypts settled")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        XCTAssertGreaterThanOrEqual(progress.percentComplete, 80)
        XCTAssertLessThanOrEqual(progress.percentComplete, 99)
    }

    func testPercentComplete_zeroProgress_isZero() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        XCTAssertEqual(progress.percentComplete, 0,
                       "fresh begin must report 0%, not a non-zero floor")
    }

    // MARK: - finish() / round-trip

    func testFinish_resetsToIdleAndClearsIdentifier() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.loadingFirstPage)
        progress.recordExtractedBytes(1_024)

        let wait = expectation(description: "settled")
        Task { @MainActor in wait.fulfill() }
        self.wait(for: [wait], timeout: 1.0)

        progress.finish()

        XCTAssertEqual(progress.phase, .idle)
        XCTAssertNil(progress.bookIdentifier)
        XCTAssertFalse(LCPPDFOpenProgress.isOpenInProgress,
                       "finish must clear the cross-actor flag so cover prefetch can resume")
    }

    /// Round-trip per CLAUDE.md state-machine rule: begin → work →
    /// finish → begin again must yield clean state. A bug where
    /// `finish` failed to reset would silently carry counters
    /// across opens.
    func testRoundTrip_beginWorkFinishBegin_endsAtCleanState() {
        let progress = LCPPDFOpenProgress.shared
        progress.begin(bookIdentifier: bookID)
        progress.setPhase(.decryptingContent)
        progress.recordDecrypt(byteCount: 2_048)
        let firstWait = expectation(description: "first-open work settled")
        Task { @MainActor in firstWait.fulfill() }
        wait(for: [firstWait], timeout: 1.0)
        progress.finish()

        // Re-open on a different book — counters MUST start at zero.
        progress.begin(bookIdentifier: "urn:isbn:9780000000001")

        XCTAssertEqual(progress.decryptedBlocks, 0)
        XCTAssertEqual(progress.cachedHits, 0)
        XCTAssertEqual(progress.bytesExtracted, 0)
        XCTAssertEqual(progress.totalExtractBytes, 0)
        XCTAssertEqual(progress.phase, .preparing)
        XCTAssertEqual(progress.bookIdentifier, "urn:isbn:9780000000001")
        XCTAssertTrue(LCPPDFOpenProgress.isOpenInProgress,
                      "second begin re-arms the cross-actor flag after finish")
    }
}

#endif

//
//  ButtonStateTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 2/20/23.
//  Copyright © 2023 The Palace Project.
//

import XCTest
@testable import Palace

@MainActor
final class ButtonStateTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    private var testAudiobook: TPPBook {
        TPPBook(dictionary: [
                    "acquisitions": [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()],
                    "title": "Tractatus",
                    "categories": ["some cat"],
                    "id": "123",
                    "updated": "2020-10-06T17:13:51Z"]
        )!
    }

    private var testEpub: TPPBook {
        TPPBook(dictionary: [
                    "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
                    "title": "Tractatus",
                    "categories": ["some cat"],
                    "id": "123",
                    "updated": "2020-10-06T17:13:51Z"]
        )!
    }

    // MARK: - Borrowing Tests

    /// Borrow state: when previewEnabled and the book has a preview link, the
    /// sample button appears alongside Get; when previewEnabled is false,
    /// only Get remains. Paired across content types so a mutant that flips
    /// the previewEnabled check fails on either epub or audiobook.
    func testCanBorrow_epubButtonsRespectPreviewToggle() {
        let testEpub = testEpub
        testEpub.previewLink = TPPFake.genericSample

        let withPreview = BookButtonState.canBorrow.buttonTypes(book: testEpub, previewEnabled: true)
        let withoutPreview = BookButtonState.canBorrow.buttonTypes(book: testEpub, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.get, .sample]),
                       "Preview enabled + epub previewLink → Get + Sample")
        XCTAssertEqual(Set(withoutPreview), Set([.get]),
                       "Preview disabled → only Get; sample button must not leak through")
    }

    func testCanBorrow_audiobookButtonsRespectPreviewToggle() {
        let testAudiobook = testAudiobook
        testAudiobook.previewLink = TPPFake.genericAudiobookSample

        let withPreview = BookButtonState.canBorrow.buttonTypes(book: testAudiobook, previewEnabled: true)
        let withoutPreview = BookButtonState.canBorrow.buttonTypes(book: testAudiobook, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.get, .audiobookSample]),
                       "Audiobooks must surface .audiobookSample, not .sample — wrong button → wrong player")
        XCTAssertEqual(Set(withoutPreview), Set([.get]))
    }

    // MARK: - Holding Tests

    /// canHold mirrors canBorrow with reserve in place of get.
    func testCanHold_epubButtonsRespectPreviewToggle() {
        let testEpub = testEpub
        testEpub.previewLink = TPPFake.genericSample

        let withPreview = BookButtonState.canHold.buttonTypes(book: testEpub, previewEnabled: true)
        let withoutPreview = BookButtonState.canHold.buttonTypes(book: testEpub, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.reserve, .sample]))
        XCTAssertEqual(Set(withoutPreview), Set([.reserve]))
    }

    func testCanHold_audiobookButtonsRespectPreviewToggle() {
        let testAudiobook = testAudiobook
        testAudiobook.previewLink = TPPFake.genericAudiobookSample

        let withPreview = BookButtonState.canHold.buttonTypes(book: testAudiobook, previewEnabled: true)
        let withoutPreview = BookButtonState.canHold.buttonTypes(book: testAudiobook, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.reserve, .audiobookSample]))
        XCTAssertEqual(Set(withoutPreview), Set([.reserve]))
    }

    /// holding (not yet ready) state: manageHold replaces reserve.
    func testHolding_epubButtonsRespectPreviewToggle() {
        let testEpub = testEpub
        testEpub.previewLink = TPPFake.genericSample

        let withPreview = BookButtonState.holding.buttonTypes(book: testEpub, previewEnabled: true)
        let withoutPreview = BookButtonState.holding.buttonTypes(book: testEpub, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.manageHold, .sample]))
        XCTAssertEqual(Set(withoutPreview), Set([.manageHold]))
    }

    func testHolding_audiobookButtonsRespectPreviewToggle() {
        let testAudiobook = testAudiobook
        testAudiobook.previewLink = TPPFake.genericAudiobookSample

        let withPreview = BookButtonState.holding.buttonTypes(book: testAudiobook, previewEnabled: true)
        let withoutPreview = BookButtonState.holding.buttonTypes(book: testAudiobook, previewEnabled: false)

        XCTAssertEqual(Set(withPreview),    Set([.manageHold, .audiobookSample]))
        XCTAssertEqual(Set(withoutPreview), Set([.manageHold]))
    }

    /// holdingFrontOfQueue without an isHoldReady availability falls back to
    /// manageHold. Assert exact set AND the absence of the get/reserve buttons
    /// that the next state up adds — guards against a mutant that
    /// prematurely surfaces the borrow path before hold-ready is true.
    func testHoldingFrontOfQueue_withoutHoldReady_returnsManageHoldOnly() {
        let result = BookButtonState.holdingFrontOfQueue.buttonTypes(book: testEpub)
        XCTAssertEqual(Set(result), Set([.manageHold]))
        XCTAssertFalse(result.contains(.get),
                       "holdingFrontOfQueue must NOT prematurely surface .get without isHoldReady")
        XCTAssertFalse(result.contains(.reserve))
    }

    // MARK: - Downloading Tests
    // Note: Button behavior depends on TPPUserAccount.sharedAccount().authDefinition // MIGRATED: comment-only reference, no call site
    // In test environment without auth, .remove is used instead of .return

    func testDownloadNeededEpub() {
        let testState = BookButtonState.downloadNeeded
        let resultButtons = testState.buttonTypes(book: testEpub)
        // Verify download button is present
        XCTAssertTrue(resultButtons.contains(.download), "Download button should be present")
        // Should have exactly 2 buttons (download + return/remove depending on auth)
        XCTAssertEqual(resultButtons.count, 2)
    }

    func testDownloadNeededAudiobook() {
        let testState = BookButtonState.downloadNeeded
        let resultButtons = testState.buttonTypes(book: testAudiobook)
        // Verify download button is present
        XCTAssertTrue(resultButtons.contains(.download), "Download button should be present")
        // Should have exactly 2 buttons
        XCTAssertEqual(resultButtons.count, 2)
    }

    /// downloadInProgress surfaces only Cancel — no read/listen/retry leakage
    /// while bytes are still in flight. Lock the absence assertions so a
    /// mutant that bleeds .read into the in-progress branch fails here.
    func testDownloadInProgress_yieldsOnlyCancelButton() {
        let result = BookButtonState.downloadInProgress.buttonTypes(book: testEpub)
        XCTAssertEqual(Set(result), Set([.cancel]))
        XCTAssertFalse(result.contains(.retry),  "Retry only appears after a failure, never mid-download")
        XCTAssertFalse(result.contains(.read),   "Read must not appear until downloadSuccessful")
        XCTAssertFalse(result.contains(.listen))
    }

    /// downloadFailed surfaces Cancel + Retry (matched pair). A mutant that
    /// drops Retry would silently strand the user with no way to recover.
    func testDownloadFailed_yieldsCancelAndRetry() {
        let result = BookButtonState.downloadFailed.buttonTypes(book: testEpub)
        XCTAssertEqual(Set(result), Set([.cancel, .retry]))
        XCTAssertTrue(result.contains(.retry),
                      "Retry MUST be present on failure or the user has no recovery path")
        XCTAssertFalse(result.contains(.read),
                       "Read must not appear until a successful download")
    }

    // MARK: - Post-Download & Unsupported Tests
    // Note: Button behavior depends on TPPUserAccount.sharedAccount().authDefinition // MIGRATED: comment-only reference, no call site
    // In test environment without auth, .remove is used instead of .return

    func testDownloadSuccessfulEpub() {
        let testState = BookButtonState.downloadSuccessful
        let resultButtons = testState.buttonTypes(book: testEpub)
        // Verify read button is present for downloaded epub
        XCTAssertTrue(resultButtons.contains(.read), "Read button should be present")
        // Should have exactly 2 buttons (read + return/remove depending on auth)
        XCTAssertEqual(resultButtons.count, 2)
    }

    func testUsedEpub() {
        let testState = BookButtonState.used
        let resultButtons = testState.buttonTypes(book: testEpub)
        // Verify read button is present for used epub
        XCTAssertTrue(resultButtons.contains(.read), "Read button should be present")
        // Should have exactly 2 buttons
        XCTAssertEqual(resultButtons.count, 2)
    }

    /// unsupported state must yield zero buttons — no fallback get/read/cancel.
    /// Pin the specific buttons that the OTHER states surface so a mutant
    /// flipping unsupported's branch into any neighbour state's buttons fails.
    func testUnsupported_yieldsEmptyButtonSetAndNoLeakageFromOtherStates() {
        let result = BookButtonState.unsupported.buttonTypes(book: testEpub)
        XCTAssertTrue(result.isEmpty, "unsupported books must surface no actionable buttons")
        XCTAssertFalse(result.contains(.get),     "must not borrow an unsupported book")
        XCTAssertFalse(result.contains(.read),    "must not read an unsupported book")
        XCTAssertFalse(result.contains(.cancel),  "nothing to cancel")
        XCTAssertFalse(result.contains(.retry),   "nothing to retry")
    }

    // MARK: - Additional content-type coverage (audiobook & PDF)

    func testDownloadSuccessfulAudiobook() {
        let testState = BookButtonState.downloadSuccessful
        let audiobook = TPPBookMocker.snapshotAudiobook()

        let resultButtons = testState.buttonTypes(book: audiobook)

        XCTAssertTrue(resultButtons.contains(.listen), "Listen button should be present for audiobook")
        XCTAssertEqual(resultButtons.count, 2, "Should have listen + return/remove")
    }

    func testDownloadSuccessfulPDF() {
        let testState = BookButtonState.downloadSuccessful
        let pdfBook = TPPBookMocker.snapshotPDF()

        let resultButtons = testState.buttonTypes(book: pdfBook)

        XCTAssertTrue(resultButtons.contains(.read), "Read button should be present for PDF")
        XCTAssertEqual(resultButtons.count, 2, "Should have read + return/remove")
    }
}

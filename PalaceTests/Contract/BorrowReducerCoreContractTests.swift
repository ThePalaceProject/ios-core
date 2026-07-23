//
//  BorrowReducerCoreContractTests.swift
//  PalaceTests
//
//  E2 (WS7) coverage for the pure `BorrowReducerCore` extracted from
//  `BorrowOperation`. Direct `Equatable` assertions on `responseState`,
//  `postResponseEffects`, and `alreadyHasActiveLoan` kill mutants (a flipped
//  F-014 download gate, a dropped race arm, a swapped SQ-007 state). The
//  `ContractSnapshot` layer interprets `postResponseEffects` into a `CallLog`
//  using the same seam labels `BorrowOperationContractTests` records, so the
//  emitted sequence is shape-equal to the E1 service snapshot.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

final class BorrowReducerCoreContractTests: XCTestCase {

    // MARK: - responseState (PP-4178 Loan→Hold race)

    func test_responseState_unlimited_downloadNeeded_noError() {
        let book = Self.book(availability: TPPOPDSAcquisitionAvailabilityUnlimited())
        let r = BorrowReducerCore.responseState(for: book, preBorrowBook: book)
        XCTAssertEqual(r.state, .downloadNeeded)
        XCTAssertNil(r.error)
    }

    func test_responseState_borrowReturnedHold_raceError() {
        // Pre-borrow was a loan-class title (unlimited) but the response is
        // reserved → CM Loan→Hold race → .holding + hold-copy-unavailable error.
        let pre = Self.book(availability: TPPOPDSAcquisitionAvailabilityUnlimited())
        let post = Self.book(availability: TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 1, copiesTotal: 1, since: nil, until: nil))
        let r = BorrowReducerCore.responseState(for: post, preBorrowBook: pre)
        XCTAssertEqual(r.state, .holding)
        XCTAssertNotNil(r.error)
    }

    func test_responseState_deliberatePlaceHold_noError() {
        // Pre-borrow was `unavailable` (no copies → the user could only tap
        // Place Hold), so a reserved response is the expected queue placement,
        // NOT a Loan→Hold race error. Only `unavailable` counts as place-hold
        // intent (`preBorrowWasUnavailable` matches only the `.unavailable` arm).
        let pre = Self.book(availability: TPPOPDSAcquisitionAvailabilityUnavailable(
            copiesHeld: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            copiesTotal: TPPOPDSAcquisitionAvailabilityCopiesUnknown))
        let post = Self.book(availability: TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 2, copiesTotal: 1, since: nil, until: nil))
        let r = BorrowReducerCore.responseState(for: post, preBorrowBook: pre)
        XCTAssertEqual(r.state, .holding)
        XCTAssertNil(r.error)
    }

    // MARK: - postResponseEffects

    func test_post_downloadNeeded_attemptDownload_firesStartDownload() {
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(state: .downloadNeeded, isStreamingHTML: false,
                                                  attemptDownload: true, hasRaceError: false),
            [.announceBorrowSucceeded, .noteBorrowSucceeded, .startDownload])
    }

    func test_post_downloadNeeded_noAttemptDownload_skipsStartDownload() {
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(state: .downloadNeeded, isStreamingHTML: false,
                                                  attemptDownload: false, hasRaceError: false),
            [.announceBorrowSucceeded, .noteBorrowSucceeded])
    }

    func test_post_streamingHTML_skipsStartDownload_evenWithAttemptDownload() {
        // PP-4161 advisory F: streaming-HTML has no downloadable asset.
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(state: .downloadNeeded, isStreamingHTML: true,
                                                  attemptDownload: true, hasRaceError: false),
            [.announceBorrowSucceeded, .noteBorrowSucceeded])
    }

    func test_post_holding_schedulesHoldSync_noStartDownload() {
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(state: .holding, isStreamingHTML: false,
                                                  attemptDownload: true, hasRaceError: false),
            [.announceBorrowSucceeded, .noteBorrowSucceeded, .scheduleHoldPositionSync])
    }

    func test_post_raceError_onlyThrows_noAnnounceOrDownload() {
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(state: .holding, isStreamingHTML: false,
                                                  attemptDownload: true, hasRaceError: true),
            [.failWithRaceError])
    }

    // MARK: - alreadyHasActiveLoan (SQ-007)

    func test_alreadyHasActiveLoan_loanStates_true() {
        for s: TPPBookState in [.downloadNeeded, .downloading, .downloadSuccessful,
                                .downloadFailed, .holding, .SAMLStarted, .used, .returning] {
            XCTAssertTrue(BorrowReducerCore.alreadyHasActiveLoan(state: s), "\(s) should count as active loan")
        }
    }

    func test_alreadyHasActiveLoan_noLoanStates_false() {
        XCTAssertFalse(BorrowReducerCore.alreadyHasActiveLoan(state: .unregistered))
        XCTAssertFalse(BorrowReducerCore.alreadyHasActiveLoan(state: .unsupported))
    }

    // MARK: - Shape-equality snapshot (proof vs E1 service snapshot)

    func test_snapshot_downloadNeeded_attemptDownload() {
        let log = interpretPost(state: .downloadNeeded, isStreamingHTML: false, attemptDownload: true)
        ContractSnapshot.assert(log, named: "post_downloadNeeded_attemptDownload_noteThenStartDownload")
    }

    func test_snapshot_streamingHTML_skipsStartDownload() {
        let log = interpretPost(state: .downloadNeeded, isStreamingHTML: true, attemptDownload: true)
        ContractSnapshot.assert(log, named: "post_streamingHTML_noteOnly")
    }

    // MARK: - Helpers

    private static let bookId = "BRC-BOOK"

    /// Interprets `postResponseEffects` into a CallLog using the seam labels the
    /// `BorrowOperationContractTests` record (`announceBorrowSucceeded` is silent
    /// there, so it records nothing here either — keeping the JSON shape-equal).
    private func interpretPost(state: TPPBookState, isStreamingHTML: Bool, attemptDownload: Bool) -> CallLog {
        let log = CallLog()
        let id = Self.bookId
        for effect in BorrowReducerCore.postResponseEffects(
            state: state, isStreamingHTML: isStreamingHTML,
            attemptDownload: attemptDownload, hasRaceError: false) {
            switch effect {
            case .announceBorrowSucceeded:
                break // SilentAnnouncementService in the service test — unrecorded
            case .noteBorrowSucceeded:
                log.record("noteBorrowSucceeded", args: [:])
            case .startDownload:
                log.record("startDownload", args: ["bookId": id, "hasRequest": "false"])
            case .scheduleHoldPositionSync:
                break // fire-and-forget sync Task — unrecorded (mock cast is nil)
            case .failWithRaceError:
                break
            }
        }
        return log
    }

    private static func book(availability: TPPOPDSAcquisitionAvailability) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: DistributorType.EpubZip.rawValue,
            hrefURL: URL(string: "http://example.com/\(bookId)")!,
            indirectAcquisitions: [],
            availability: availability
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: bookId,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(bookId)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

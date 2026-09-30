//
//  AnnouncementChainTests.swift
//  PalaceTests
//
//  Pins TPPAnnouncementBusinessLogic's chaining index-pair calculation
//  (`if i > 0`), extracted into a pure helper and exercised under
//  empty / 1 / 2 / N announcement counts.
//

import XCTest
@testable import Palace

@MainActor
final class AnnouncementChainTests: XCTestCase {

    // MARK: - chainAttachmentIndices

    func test_chainAttachmentIndices_zeroAnnouncements_returnsEmpty() {
        let pairs = TPPAnnouncementBusinessLogic.chainAttachmentIndices(forAnnouncementCount: 0)
        XCTAssertTrue(pairs.isEmpty)
    }

    /// Single announcement is shown directly with its own dismiss button —
    /// no chaining needed. A `>= 0` bound would
    /// emit a (-1, 0) pair and crash on `announcements[-1]`.
    func test_chainAttachmentIndices_oneAnnouncement_returnsEmpty() {
        let pairs = TPPAnnouncementBusinessLogic.chainAttachmentIndices(forAnnouncementCount: 1)
        XCTAssertTrue(pairs.isEmpty)
    }

    /// Two announcements: alerts[0] gets the action that presents alerts[1]
    /// and marks announcements[0] as presented when tapped.
    func test_chainAttachmentIndices_twoAnnouncements_returnsOnePair() {
        let pairs = TPPAnnouncementBusinessLogic.chainAttachmentIndices(forAnnouncementCount: 2)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].attach, 0)
        XCTAssertEqual(pairs[0].present, 1)
    }

    /// Three announcements: chain alerts[0]→alerts[1] and alerts[1]→alerts[2].
    /// Pins both the `> 0` bound and the `i - 1` index calculation.
    func test_chainAttachmentIndices_threeAnnouncements_returnsTwoChainedPairs() {
        let pairs = TPPAnnouncementBusinessLogic.chainAttachmentIndices(forAnnouncementCount: 3)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].attach, 0)
        XCTAssertEqual(pairs[0].present, 1)
        XCTAssertEqual(pairs[1].attach, 1)
        XCTAssertEqual(pairs[1].present, 2)
    }

    func test_chainAttachmentIndices_fiveAnnouncements_returnsFourChainedPairs() {
        let pairs = TPPAnnouncementBusinessLogic.chainAttachmentIndices(forAnnouncementCount: 5)
        XCTAssertEqual(pairs.count, 4)
        for (idx, pair) in pairs.enumerated() {
            XCTAssertEqual(pair.attach, idx)
            XCTAssertEqual(pair.present, idx + 1)
        }
    }
}

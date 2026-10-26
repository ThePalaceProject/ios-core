//
//  BookDetailErrorAdmissionTests.swift
//  PalaceTests
//
//  The admission rules decide whether a published error reaches the book-detail
//  sheet. Too narrow and the patron is told nothing; too wide and a stale error
//  interrupts a book they already have. One table per error kind, every cell
//  asserted.
//

import XCTest
import PalaceBookModel
@testable import Palace

final class BookDetailErrorAdmissionTests: XCTestCase {

    /// One cell of the admission table: the sheet's state, what it is
    /// processing, and whether an error of the kind under test belongs to it.
    private struct Cell {
        let state: TPPBookState
        let processing: Set<BookButtonType>
        let admitted: Bool
        let why: String
    }

    private func assertTable(
        _ kind: DownloadErrorInfo.ErrorKind,
        _ cells: [Cell],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for cell in cells {
            let actual = BookDetailErrorAdmission.admits(
                kind: kind,
                bookState: cell.state,
                processingButtons: cell.processing
            )
            XCTAssertEqual(
                actual, cell.admitted,
                "\(kind) error with state \(cell.state.stringValue()) processing \(cell.processing): \(cell.why)",
                file: file, line: line
            )
        }
    }

    /// `.get`/`.unregistered` is the PP-5407 case — Borrow was tapped and the
    /// sheet sits on the optimistic `.downloading`, so the error is the only
    /// thing that can resolve it. `.holding`/`.reserve` is PP-4178: the
    /// Loan→Hold race registers the hold before throwing, so the state has
    /// already moved on by the time the error lands.
    func testBorrowErrorAdmission_coversEveryCell() {
        assertTable(.borrow, [
            Cell(state: .downloading, processing: [.get], admitted: true,
                 why: "the sheet is mid-borrow and nothing else will clear it"),
            Cell(state: .unregistered, processing: [], admitted: true,
                 why: "no loan means the borrow is what failed, spinner or not"),
            Cell(state: .holding, processing: [], admitted: true,
                 why: "a Loan→Hold race has already moved the state on"),
            Cell(state: .downloadSuccessful, processing: [.reserve], admitted: true,
                 why: "Place Hold is in flight from this sheet"),
            Cell(state: .downloadSuccessful, processing: [], admitted: false,
                 why: "a borrow error on a book the patron already has is stale"),
            Cell(state: .downloadSuccessful, processing: [.download], admitted: false,
                 why: "a download spinner is not a borrow"),
            Cell(state: .downloadNeeded, processing: [], admitted: false,
                 why: "the loan exists, so this borrow error is not about this sheet")
        ])
    }

    func testDownloadErrorAdmission_coversEveryCell() {
        assertTable(.download, [
            Cell(state: .downloading, processing: [], admitted: true,
                 why: "the transfer the error is about is the one on screen"),
            Cell(state: .downloadFailed, processing: [], admitted: true,
                 why: "a failed download is exactly what the sheet is showing"),
            Cell(state: .downloadNeeded, processing: [], admitted: true,
                 why: "the loan is downloadable, so a download error belongs here"),
            Cell(state: .holding, processing: [.retry], admitted: true,
                 why: "the patron asked for a retry from this sheet"),
            Cell(state: .holding, processing: [.download], admitted: true,
                 why: "a download is in flight from this sheet"),
            Cell(state: .unregistered, processing: [], admitted: false,
                 why: "there is no loan, so there is no download to fail"),
            Cell(state: .holding, processing: [.get], admitted: false,
                 why: "a borrow spinner is not a download")
        ])
    }

    /// Wi-Fi-only refusals and the like are not tied to a phase, so they always
    /// reach the patron.
    func testGeneralErrorAdmission_isAdmittedWhateverTheState() {
        assertTable(.general, [
            Cell(state: .downloadSuccessful, processing: [], admitted: true,
                 why: "a general refusal is not scoped to an acquisition phase"),
            Cell(state: .unregistered, processing: [], admitted: true,
                 why: "a general refusal is not scoped to an acquisition phase"),
            Cell(state: .downloading, processing: [.get], admitted: true,
                 why: "a general refusal is not scoped to an acquisition phase")
        ])
    }
}

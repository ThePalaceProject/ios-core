//
//  TPPPDFReaderSearchBindingTests.swift
//  PalaceTests
//
//  Bug PP-4748: the PDF search sheet used `.sheet(isPresented: .constant(...))`,
//  a binding that cannot write back on an interactive (swipe-down) dismiss — so
//  `readerMode` stayed `.search` and the search sheet could never be reopened.
//  The fix routes the sheet's binding through the pure seam
//  `TPPPDFReaderView.searchSheetReaderMode(current:isPresented:)`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TPPPDFReaderSearchBindingTests: XCTestCase {

    /// Dismissing the search sheet (isPresented→false) returns to `.reader`.
    func test_searchSheetReaderMode_dismissFromSearch_returnsToReader() {
        XCTAssertEqual(TPPPDFReaderView.searchSheetReaderMode(current: .search, isPresented: false), .reader,
                       "Interactive dismiss of the search sheet must flip readerMode back to .reader.")
    }

    /// While the sheet is still presented (isPresented==true) the mode stays `.search`.
    func test_searchSheetReaderMode_stillPresented_staysSearch() {
        XCTAssertEqual(TPPPDFReaderView.searchSheetReaderMode(current: .search, isPresented: true), .search,
                       "A still-presented search sheet must keep readerMode == .search — kills the always-return-.reader mutation.")
    }

    /// A dismiss signal while NOT in search must not clobber the current mode.
    func test_searchSheetReaderMode_dismissFromNonSearch_isNoOp() {
        XCTAssertEqual(TPPPDFReaderView.searchSheetReaderMode(current: .toc, isPresented: false), .toc,
                       "A false isPresented while in .toc must not change the mode — kills the drop-`current == .search` guard mutation.")
        XCTAssertEqual(TPPPDFReaderView.searchSheetReaderMode(current: .reader, isPresented: false), .reader)
    }
}

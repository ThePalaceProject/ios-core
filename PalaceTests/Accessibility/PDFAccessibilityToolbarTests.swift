//
//  PDFAccessibilityToolbarTests.swift
//  PalaceTests
//
//  Regression tests for PP-3838: Accessible page navigation for the PDF
//  reader. Mirrors the EPUB reader's accessibility toolbar — the bottom
//  Previous/Next page controls must clamp at the document boundaries and
//  must drive `currentPage` through a single binding.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class PDFAccessibilityToolbarTests: XCTestCase {

  // MARK: - Forward navigation

  func testToolbar_goForward_advancesPage() {
    var page = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goForward()

    XCTAssertEqual(page, 1, "Forward from page 0 should advance to page 1")
    XCTAssertGreaterThan(page, 0, "Page must be positive after forward navigation")
    XCTAssertLessThan(page, 10, "Page must remain within pageCount after one step")
  }

  func testToolbar_goForward_clampsAtLastPage() {
    var page = 9
    let setCount = 0
    var setCallCount = setCount
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { newPage in
        page = newPage
        setCallCount += 1
    }, pageCount: 10)

    toolbar.goForward()

    XCTAssertEqual(page, 9, "Forward must not advance past the last page (index 9 of 10)")
    XCTAssertLessThan(page, 10, "Page index must remain below pageCount after clamped forward")
  }

  // MARK: - Backward navigation

  func testToolbar_goBackward_decrementsPage() {
    var page = 5
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 4, "Backward from page 5 should decrement to page 4")
    XCTAssertGreaterThanOrEqual(page, 0, "Page must remain non-negative after backward navigation")
  }

  func testToolbar_goBackward_clampsAtFirstPage() {
    var page = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 0, "Backward must not decrement below the first page")
    XCTAssertGreaterThanOrEqual(page, 0, "Page must never go negative regardless of backward calls")
  }

  // MARK: - Helpers

  /// Builds a `TPPPDFAccessibilityToolbar` whose binding is backed by a
  /// caller-supplied getter/setter pair so the tests can observe the
  /// underlying state without exercising SwiftUI's view machinery.
  private func makeToolbar(
    currentPage: @escaping () -> Int,
    setCurrentPage: @escaping (Int) -> Void,
    pageCount: Int
  ) -> TPPPDFAccessibilityToolbar {
    let binding = Binding<Int>(get: currentPage, set: setCurrentPage)
    return TPPPDFAccessibilityToolbar(currentPage: binding, pageCount: pageCount)
  }
}


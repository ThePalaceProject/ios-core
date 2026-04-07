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

    XCTAssertEqual(page, 1)
  }

  func testToolbar_goForward_clampsAtLastPage() {
    var page = 9
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goForward()

    XCTAssertEqual(page, 9, "Forward must not advance past the last page")
  }

  // MARK: - Backward navigation

  func testToolbar_goBackward_decrementsPage() {
    var page = 5
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 4)
  }

  func testToolbar_goBackward_clampsAtFirstPage() {
    var page = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 0, "Backward must not decrement below the first page")
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


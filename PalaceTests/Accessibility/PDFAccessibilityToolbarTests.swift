//
//  PDFAccessibilityToolbarTests.swift
//  PalaceTests
//
//  PP-3838: the PDF reader's VoiceOver Previous/Next page controls must clamp
//  at the document boundaries and drive `currentPage` through its binding.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class PDFAccessibilityToolbarTests: XCTestCase {

  func testGoForward_fromFirstPage_advancesOnePage() {
    var page = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goForward()

    XCTAssertEqual(page, 1)
  }

  func testGoForward_onLastPage_doesNotWriteThePage() {
    var page = 9
    var writes = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0; writes += 1 }, pageCount: 10)

    toolbar.goForward()

    XCTAssertEqual(page, 9, "Forward must not advance past the last page (index 9 of 10)")
    XCTAssertEqual(writes, 0)
  }

  func testGoBackward_fromMiddlePage_decrementsOnePage() {
    var page = 5
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 4)
  }

  func testGoBackward_onFirstPage_doesNotWriteThePage() {
    var page = 0
    var writes = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0; writes += 1 }, pageCount: 10)

    toolbar.goBackward()

    XCTAssertEqual(page, 0, "Backward must not decrement below the first page")
    XCTAssertEqual(writes, 0)
  }

  func testGoForward_singlePageDocument_staysOnOnlyPage() {
    var page = 0
    let toolbar = makeToolbar(currentPage: { page }, setCurrentPage: { page = $0 }, pageCount: 1)

    toolbar.goForward()

    XCTAssertEqual(page, 0)
  }

  // MARK: - Helpers

  /// Backs the toolbar's binding with a getter/setter pair so the test observes
  /// writes without rendering the view.
  private func makeToolbar(
    currentPage: @escaping () -> Int,
    setCurrentPage: @escaping (Int) -> Void,
    pageCount: Int
  ) -> TPPPDFAccessibilityToolbar {
    let binding = Binding<Int>(get: currentPage, set: setCurrentPage)
    return TPPPDFAccessibilityToolbar(currentPage: binding, pageCount: pageCount)
  }
}

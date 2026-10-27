//
//  PDFTableOfContentsButtonTests.swift
//  PalaceTests
//
//  The PDF reader's list icon is labelled Table of Contents and announces that
//  to VoiceOver, but it opened whatever the segmented picker had last selected
//  — page previews on every first tap, since that state starts at the first
//  case (PP-5404).
//

import SwiftUI
import XCTest
@testable import Palace

final class PDFTableOfContentsButtonTests: XCTestCase {

  /// The control labelled Table of Contents opens the table of contents.
  ///
  /// Asserted against the destination the button's action uses, which is now a
  /// constant. Before the fix there was no constant to assert: the destination
  /// was computed from the picker's selection, so the control's behaviour did
  /// not follow its label.
  func test_theTableOfContentsButton_opensTheTableOfContents() {
    XCTAssertEqual(
      TPPPDFNavigation<EmptyView>.tableOfContentsButtonDestination,
      .toc,
      "a control labelled Table of Contents must open the table of contents, not page previews"
    )
  }

  /// It is not the previews grid, stated separately.
  ///
  /// The two assertions are not redundant: this one is the regression itself,
  /// and it fails with a message naming what a patron actually saw, which the
  /// equality check above does not.
  func test_theTableOfContentsButton_doesNotOpenThePagePreviewsGrid() {
    XCTAssertNotEqual(
      TPPPDFNavigation<EmptyView>.tableOfContentsButtonDestination,
      .previews,
      "this is the defect: the labelled button opened the thumbnail grid instead"
    )
  }
}

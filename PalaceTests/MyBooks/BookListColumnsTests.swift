//
//  BookListColumnsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Column count for the My Books / catalog grid, across every width the app
/// is actually given.
///
/// The grid used to pick its columns from `UIScreen.main.bounds`, refreshed
/// only on appear and on `UIDevice.orientationDidChangeNotification` — a
/// notification iOS delivers only after `beginGeneratingDeviceOrientationNotifications()`,
/// which this app does not call. So the count was fixed at whatever the screen
/// was when the view first appeared. The container's own width needs no
/// notification at all, and is also right in Split View, which no screen-level
/// signal reports. Observed on an iPad Pro 12.9 in portrait:
/// three columns instead of two, which left each cell ~341pt and wrapped
/// "Due October 23, 2026" onto four lines with the titles truncated.
///
/// The width the grid is handed is the honest input: it is correct on
/// rotation, and it is also correct in Split View, Slide Over and Stage
/// Manager, where the screen's own bounds say nothing about the room the grid
/// has.
final class BookListColumnsTests: XCTestCase {

  // Points per column below which the cell's own content stops fitting. The
  // reported defect rendered at 341pt per column; 360 is the first width above
  // that which still yields the established counts on every shipping iPad.
  private let minimumColumnWidth: CGFloat = 360

  // MARK: - The reported defect

  func testIPadPortrait12Point9_usesTwoColumns_notThree() {
    // 1024 / 3 = 341pt per cell, which is what broke.
    XCTAssertEqual(BookListView.columnCount(forContainerWidth: 1024, isIPad: true), 2)
  }

  // MARK: - Every shipping iPad, both orientations

  func testEveryIPadWidthKeepsItsEstablishedColumnCount() {
    let cases: [(name: String, width: CGFloat, expected: Int)] = [
      ("iPad 10.2 portrait",       810,  2),
      ("iPad 10.2 landscape",     1080,  3),
      ("iPad Pro 11 portrait",     834,  2),
      ("iPad Pro 11 landscape",   1194,  3),
      ("iPad Pro 12.9 portrait",  1024,  2),
      ("iPad Pro 12.9 landscape", 1366,  3),
    ]
    for c in cases {
      XCTAssertEqual(
        BookListView.columnCount(forContainerWidth: c.width, isIPad: true),
        c.expected,
        "\(c.name) at \(c.width)pt"
      )
    }
  }

  // MARK: - iPhone is always a single column, including landscape

  func testIPhoneIsAlwaysOneColumn() {
    // 852 is an iPhone 16 Pro in landscape: wide enough to tempt a width-only
    // rule into two columns, which the phone layout has never used.
    for width in [320, 375, 393, 430, 440, 852, 932] as [CGFloat] {
      XCTAssertEqual(
        BookListView.columnCount(forContainerWidth: width, isIPad: false), 1,
        "iPhone at \(width)pt must stay single-column"
      )
    }
  }

  // MARK: - iPad multitasking, which the screen's bounds cannot see at all

  func testIPadSplitViewNarrowsTheGrid() {
    // A screen-bounds rule reports the full 1366 in every one of these, so it
    // would hand a 678pt column strip three columns.
    XCTAssertEqual(BookListView.columnCount(forContainerWidth: 507, isIPad: true), 1,
                   "Slide Over")
    XCTAssertEqual(BookListView.columnCount(forContainerWidth: 678, isIPad: true), 1,
                   "half of a 12.9 landscape split")
    XCTAssertEqual(BookListView.columnCount(forContainerWidth: 981, isIPad: true), 2,
                   "two thirds of a 12.9 landscape split")
  }

  // MARK: - Degenerate widths

  func testAWidthThatCanFitNothingStillYieldsOneColumn() {
    // A LazyVGrid with zero columns renders nothing at all, so the floor must
    // hold even before layout has given the grid a real width.
    for width in [0, 1, 120] as [CGFloat] {
      XCTAssertEqual(BookListView.columnCount(forContainerWidth: width, isIPad: true), 1,
                     "\(width)pt must still produce a usable grid")
    }
  }

  func testTheCountIsCappedAtThree() {
    // An external display or a future wider iPad must not shred the cells.
    for width in [2048, 3840] as [CGFloat] {
      XCTAssertEqual(BookListView.columnCount(forContainerWidth: width, isIPad: true), 3,
                     "\(width)pt must cap at three columns")
    }
  }

  // MARK: - The rule itself

  func testNoColumnIsEverNarrowerThanTheMinimum() {
    // The property the device table above is only a sample of: whatever the
    // width, the chosen count never slices a column below the minimum unless
    // it is already down to the single-column floor.
    for w in stride(from: CGFloat(361), through: CGFloat(2000), by: 7) {
      let n = BookListView.columnCount(forContainerWidth: w, isIPad: true)
      XCTAssertGreaterThanOrEqual(n, 1, "\(w)pt produced no columns")
      if n > 1 {
        XCTAssertGreaterThanOrEqual(
          w / CGFloat(n), minimumColumnWidth,
          "\(w)pt split into \(n) columns gives \(w / CGFloat(n))pt each"
        )
      }
    }
  }

  func testWideningTheContainerNeverRemovesAColumn() {
    var previous = 0
    for w in stride(from: CGFloat(200), through: CGFloat(2000), by: 5) {
      let n = BookListView.columnCount(forContainerWidth: w, isIPad: true)
      XCTAssertGreaterThanOrEqual(n, previous, "column count fell at \(w)pt")
      previous = n
    }
  }
}

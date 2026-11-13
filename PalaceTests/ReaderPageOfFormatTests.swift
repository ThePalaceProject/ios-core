//
//  ReaderPageOfFormatTests.swift
//  PalaceTests
//
//  `pageOf` was `"Page %d of "` — a trailing space with the total
//  concatenated at the call site. That froze English word order, so no
//  translation could put the total first, and four call sites each rebuilt
//  the sentence by hand. It is now a two-operand positional format.
//

import XCTest
@testable import Palace

final class ReaderPageOfFormatTests: XCTestCase {

    func testRendersBothOperands() {
        let rendered = String(format: Strings.TPPBaseReaderViewController.pageOf, 3, 20)
        XCTAssertEqual(rendered, "Page 3 of 20")
    }

    func testCarriesTwoPositionalOperandsSoATranslationMayReorderThem() {
        // The defect was a single operand plus string concatenation. Positional
        // form is what lets a target language put the total first.
        let format = Strings.TPPBaseReaderViewController.pageOf
        XCTAssertTrue(format.contains("%1$d"), "lost the positional page operand: \(format)")
        XCTAssertTrue(format.contains("%2$d"), "lost the positional total operand: \(format)")
    }

    func testDoesNotEndInASeparatorAwaitingConcatenation() {
        let format = Strings.TPPBaseReaderViewController.pageOf
        XCTAssertFalse(format.hasSuffix(" "),
                       "trailing space means a caller is still concatenating the total")
    }
}

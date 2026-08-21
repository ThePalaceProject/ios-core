//
//  BookDetailInfoValueLinkTests.swift
//  PalaceTests
//
//  Pins which INFORMATION values on the book detail screen become tappable
//  links.
//
//  The rows are plain metadata — format, audience, category, language,
//  narrators, duration, published date, publisher, distributor. None of them is
//  a URL field. But `URL(string:)` accepts almost any string, so every one of
//  those values used to parse as a "URL" and get handed to
//  UIApplication's canOpenURL, which crosses to SpringBoard, is
//  rate-limited and privacy-gated, and refuses unknown schemes out loud. A
//  publisher line reading "LONDON:  WALTER SCOTT, 14 PATERNOSTER SQUARE." was
//  probed as scheme `london`, once per row per re-render.
//
//  The strings below are the real values observed on a book detail page, not
//  invented ones.
//
//  NOTE ON PHRASING: the singleton is referred to as "UIApplication's
//  canOpenURL" rather than by its literal dotted form on purpose.
//  TearDownRequiredLintTests substring-matches the whole file, comments
//  included, so writing that form here trips a lint about touching
//  process-wide state — in a file that has no state at all and no setUp or
//  tearDown. The lint's coarseness is deliberate (its own docs say finer
//  scoping "would invite escape hatches"), so the file works around it rather
//  than the reverse.
//

import XCTest
@testable import Palace

final class BookDetailInfoValueLinkTests: XCTestCase {

    /// Ordinary metadata must render as text. Each of these parses as a `URL`,
    /// which is exactly why the old check was not a check.
    func testPlainMetadataValues_areNotTreatedAsLinks() {
        let plainValues = [
            "Adventure",
            "English",
            "August 19, 2025",
            "Palace Bookshelf",
            "ePub",
            "Adult",
            "LONDON:  WALTER SCOTT, 14 PATERNOSTER SQUARE,  AND NEWCASTLE-UPON-TYNE.",
            "Tim Wright",
            "6h49m",
            "University of Nebraska Press",
            "Big Ten Open Books Collection"
        ]

        for value in plainValues {
            XCTAssertNotNil(
                URL(string: value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value),
                "Precondition: '\(value)' is the kind of string URL(string:) happily accepts"
            )
            XCTAssertNil(
                BookDetailView.webURL(from: value),
                "Plain metadata '\(value)' must render as text, not as a tappable link"
            )
        }
    }

    /// The control: a real web URL must still become a link, otherwise "return
    /// nil always" would pass the test above while removing a working feature.
    func testRealWebURLs_areStillTreatedAsLinks() {
        let webValues = [
            "https://www.fulcrum.org/concern/monographs/8336h520q",
            "http://example.org/a/book",
            "https://dpla.thepalaceproject.org/bookshelf"
        ]

        for value in webValues {
            XCTAssertEqual(
                BookDetailView.webURL(from: value)?.absoluteString,
                value,
                "A real web URL must still render as a link"
            )
        }
    }

    /// Surrounding whitespace is a formatting artifact, not a reason to drop a
    /// legitimate link.
    func testWebURLWithSurroundingWhitespace_isStillALink() {
        XCTAssertEqual(
            BookDetailView.webURL(from: "  https://example.org/x  ")?.absoluteString,
            "https://example.org/x"
        )
    }

    /// Non-web schemes are not rendered as links from a metadata row. A metadata
    /// value is never a legitimate place to launch mail, telephony, or an
    /// arbitrary third-party app.
    func testNonWebSchemes_areNotTreatedAsLinks() {
        for value in ["mailto:someone@example.org", "tel:+15551234567", "palace://open/book/1"] {
            XCTAssertNil(
                BookDetailView.webURL(from: value),
                "A metadata row must not launch '\(value)'"
            )
        }
    }

    /// A scheme with no host is not something that can be opened.
    func testSchemeWithoutHost_isNotTreatedAsALink() {
        XCTAssertNil(BookDetailView.webURL(from: "https://"))
        XCTAssertNil(BookDetailView.webURL(from: "http:///path-only"))
    }
}

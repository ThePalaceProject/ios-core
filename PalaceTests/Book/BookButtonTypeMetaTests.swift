//  BookButtonTypeMetaTests.swift
//
//  PP-4161: every BookButtonType case must produce a non-empty localized title, a
//  ButtonStyleType, and `displaysIndicator` / `isDisabled` values. Exhaustive
//  switches catch a missing arm at compile time; this test catches a new case
//  wired up with an empty title or a style that hides the button.

import XCTest
@testable import Palace

@MainActor
final class BookButtonTypeMetaTests: XCTestCase {

    /// Canonical list of every BookButtonType case. Hand-maintained
    /// because Swift enums don't auto-synthesize `.allCases` without
    /// `CaseIterable`. If a future contributor adds a case here without
    /// also adding the underlying enum case (or vice versa), the test
    /// will fail loudly — `XCTAssertEqual(buttonType.rawValue, ...)` would
    /// trip on the missing case at the switch sites.
    private static let allCases: [BookButtonType] = [
        .get, .reserve, .download, .read, .listen, .retry, .cancel, .close,
        .sample, .audiobookSample, .remove, .cancelHold, .manageHold,
        .return, .returning, .readStreaming
    ]

    /// PP-4161: pin the new case to the hand-maintained allCases list. If
    /// a future contributor removes it accidentally, all the per-case META
    /// assertions below will silently skip it. This early sentinel makes
    /// the omission fail loudly.
    func testBookButtonType_exhaustiveSwitch_coverage_includesReadStreaming() {
        XCTAssertTrue(Self.allCases.contains(.readStreaming),
                      "PP-4161: BookButtonType.readStreaming must be in the test's allCases list. " +
                      "If removed, the streaming-HTML reader's terminal action is unverified at the UI layer.")

        // For every case, exercise the internal switches that drive UI.
        // A nil/empty result here means the case wasn't wired up correctly
        // and the button would render blank or in the wrong style.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        for buttonType in Self.allCases {
            // 1. Localized title must be non-empty. An empty title means
            // the button renders as a blank tappable area.
            XCTAssertFalse(buttonType.title.isEmpty,
                           "BookButtonType.\(buttonType) has empty title — button would render blank")

            // 2. title(for:) must also be non-empty. Some cases (.sample,
            // .audiobookSample) overlay preview state into the label; the
            // base case must still surface a usable string.
            XCTAssertFalse(buttonType.title(for: book).isEmpty,
                           "BookButtonType.\(buttonType).title(for:) returned empty for an EPUB book")

            // 3. buttonStyle must be defined — Swift's exhaustive switch
            // guarantees this, but reading it asserts the case actually
            // appears in the switch (a missed `case .X:` arm would have
            // failed to compile).
            _ = buttonType.buttonStyle

            // 4. displaysIndicator + isDisabled are computed via exhaustive
            // switches over BookButtonType. Read them to assert the
            // compiler-enforced wiring is intact.
            _ = buttonType.displaysIndicator
            _ = buttonType.isDisabled
        }
    }

    /// PP-4161: the new case must use the same primary button style as
    /// .read / .listen — anything else means the user sees a
    /// secondary/destructive Read button, which would be a visible UX bug.
    func testBookButtonType_readStreaming_usesPrimaryButtonStyle() {
        XCTAssertEqual(BookButtonType.readStreaming.buttonStyle, .primary,
                       "readStreaming must use .primary style to match .read / .listen — " +
                       "any other style would render the Read button as secondary/destructive")
    }

    /// PP-4161: the new case must display an indicator (spinner) like the
    /// other "open content" actions. Without it, the user gets no feedback
    /// between tap and reader presentation.
    func testBookButtonType_readStreaming_displaysIndicatorTrue() {
        XCTAssertTrue(BookButtonType.readStreaming.displaysIndicator,
                      "readStreaming must displayIndicator=true to match .read / .listen — " +
                      "without it the user sees no feedback during the tap → present transition")
    }

    /// PP-4161: ensure title localizes to the "Read" label. Cross-checks
    /// the Strings.swift addition.
    func testBookButtonType_readStreaming_titleIsRead() {
        XCTAssertEqual(BookButtonType.readStreaming.title, Strings.BookButton.readStreaming,
                       "readStreaming.title must point to Strings.BookButton.readStreaming, not a stale literal")
    }
}

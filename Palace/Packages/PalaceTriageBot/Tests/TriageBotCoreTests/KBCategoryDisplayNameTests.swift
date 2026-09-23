import XCTest
@testable import TriageBotCore

/// PP-4847: the ticket-preview "Category" field must read like the chip the
/// patron tapped, not `rawValue.capitalized` (which produced "Signin" and
/// surfaced the internal `reader` case as "Reader" instead of "Reading").
final class KBCategoryDisplayNameTests: XCTestCase {

    func testDisplayName_matchesChipWording() {
        XCTAssertEqual(KBCategory.audiobook.displayName, "Audiobook")
        XCTAssertEqual(KBCategory.reader.displayName, "Reading")
        XCTAssertEqual(KBCategory.signin.displayName, "Sign in")
        XCTAssertEqual(KBCategory.download.displayName, "Download")
        XCTAssertEqual(KBCategory.library.displayName, "Library")
        XCTAssertEqual(KBCategory.other.displayName, "Other")
    }

    /// The two cases that were actually wrong under `rawValue.capitalized`. A
    /// regression back to that would make these equal again — so assert they differ.
    func testDisplayName_signinAndReader_differFromRawValueCapitalized() {
        XCTAssertNotEqual(KBCategory.signin.displayName, KBCategory.signin.rawValue.capitalized,
                          "'signin'.capitalized == 'Signin' (no space) — displayName must fix it")
        XCTAssertNotEqual(KBCategory.reader.displayName, KBCategory.reader.rawValue.capitalized,
                          "'reader'.capitalized == 'Reader' — the chip says 'Reading'")
    }

    func testDisplayName_everyCaseNonEmpty() {
        for category in KBCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty, "\(category) must have a display name")
        }
    }
}

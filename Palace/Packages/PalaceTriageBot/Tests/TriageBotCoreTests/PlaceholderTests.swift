import XCTest
@testable import TriageBotCore

/// Placeholder so the empty test target compiles. Real suites land alongside
/// each subsystem (LocalClassifierTests, ConversationReducerTests, etc.).
final class PlaceholderTests: XCTestCase {
    func testModuleCompiles() {
        XCTAssertEqual(KBCategory.audiobook.rawValue, "audiobook")
    }
}

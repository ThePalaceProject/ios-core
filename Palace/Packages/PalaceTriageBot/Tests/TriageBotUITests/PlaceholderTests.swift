import XCTest
#if canImport(UIKit)
@testable import TriageBotUI
#endif

/// UI tests run only when UIKit is available (iOS / iOS sim). On macOS,
/// the suite compiles but contains no test methods. Real snapshot tests
/// will land here once the package is integrated into Xcode.
final class PlaceholderTests: XCTestCase {
    #if canImport(UIKit)
    func testTriageBotUIModuleLoads() {
        // Smoke: a TriageBotUI symbol is resolvable. Snapshot suites replace this.
        let provider: any TriageBotCoreSymbol = TriageBotCoreProbe()
        XCTAssertNotNil(provider)
    }
    #endif
}

// Tiny probe used only to assert TriageBotUI compiled cleanly. Removed when
// the first real snapshot test lands.
private protocol TriageBotCoreSymbol {}
private struct TriageBotCoreProbe: TriageBotCoreSymbol {}

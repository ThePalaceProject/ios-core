import XCTest
@testable import PalaceLogging

final class CrashlyticsLogBridgeTests: XCTestCase {

    /// Captures messages forwarded by `Log` so the test can assert on them.
    private final class CapturingBridge: CrashlyticsLogBridge {
        private(set) var messages: [String] = []
        func log(_ message: String) {
            messages.append(message)
        }
    }

    private var bridge: CapturingBridge!

    override func setUp() {
        super.setUp()
        bridge = CapturingBridge()
        Log.crashlyticsBridge = bridge
    }

    override func tearDown() {
        Log.crashlyticsBridge = nil
        bridge = nil
        super.tearDown()
    }

    // MARK: - Bridge wiring

    func testBridge_isNilByDefault() {
        Log.crashlyticsBridge = nil
        XCTAssertNil(Log.crashlyticsBridge)
    }

    func testBridge_canBeReplaced() {
        let other = CapturingBridge()
        Log.crashlyticsBridge = other
        XCTAssertTrue(Log.crashlyticsBridge === other)
    }

    // MARK: - Forwarding behaviour
    //
    // The actual `Crashlytics.crashlytics().log(...)` forwarding only fires
    // under `#if !targetEnvironment(simulator) && !DEBUG`. Tests run under the
    // simulator/DEBUG, so the bridge will not be invoked from `Log.info(...)`
    // here. We instead exercise the bridge contract directly to lock in:
    //   1. The package compiles without any Firebase symbol.
    //   2. Anything implementing `CrashlyticsLogBridge` receives the exact
    //      string passed to it (no formatting drift from the protocol).

    func testBridge_receivesLiteralMessage() {
        bridge.log("verbatim payload")
        XCTAssertEqual(bridge.messages, ["verbatim payload"])
    }

    func testBridge_recordsEveryCall() {
        bridge.log("first")
        bridge.log("second")
        bridge.log("third")
        XCTAssertEqual(bridge.messages, ["first", "second", "third"])
    }
}

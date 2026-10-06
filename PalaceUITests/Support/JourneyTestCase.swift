//
//  JourneyTestCase.swift
//  PalaceUITests
//
//  Base class for patron journeys. Launches the app against a fixture scenario
//  served in-process by the DEBUG mock backend, waits on observable state with
//  bounded timeouts, and names the failing step with a screenshot and the
//  accessibility tree attached. See docs/Testing/UI_JOURNEYS.md.
//

import XCTest

@MainActor
class JourneyTestCase: XCTestCase {

    /// Generous enough for a cold launch on a loaded CI machine; every wait is
    /// for a condition, so a passing run does not spend it.
    static let defaultTimeout: TimeInterval = 30

    private(set) var app: XCUIApplication!
    private var currentStep = "launch"

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0, let app {
            attach(app: app, named: "Failure in step: \(currentStep)")
        }
        app?.terminate()
        app = nil
        try await super.tearDown()
    }

    // MARK: - Launch

    /// Launches the app with `scenario` active. `resetState` wipes defaults,
    /// app files and the keychain first; a relaunch passes `false` to keep them.
    func launch(scenario: String, resetState: Bool) {
        guard let fixtures = Self.fixturesDirectory else {
            XCTFail("the test bundle has no Fixtures folder")
            return
        }
        let app = XCUIApplication()
        app.launchEnvironment["PALACE_MOCK_BACKEND_SCENARIO"] = scenario
        app.launchEnvironment["PALACE_MOCK_BACKEND_FIXTURES"] = fixtures
        app.launchEnvironment["PALACE_MOCK_BACKEND_RESET"] = resetState ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        self.app = app
    }

    /// The fixtures are copied into this test bundle; the app reads them from
    /// there, which works because simulator apps can read host paths.
    static var fixturesDirectory: String? {
        Bundle(for: JourneyTestCase.self).url(forResource: "Fixtures", withExtension: nil)?.path
    }

    // MARK: - Steps

    /// Runs one named step. A failure inside it reports the step's name and
    /// keeps a screenshot and the accessibility tree.
    func step(_ name: String, _ body: () throws -> Void) rethrows {
        currentStep = name
        try XCTContext.runActivity(named: name) { _ in try body() }
    }

    func attach(app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) (accessibility tree)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    // MARK: - Waits

    /// Waits until `element` exists, failing with `message` after `timeout`.
    @discardableResult
    func waitFor(_ element: XCUIElement,
                 _ message: String,
                 timeout: TimeInterval = defaultTimeout,
                 file: StaticString = #filePath,
                 line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("\(message) (waited \(Int(timeout))s)", file: file, line: line)
        }
        return element
    }

    /// Waits until `predicate` holds for `object`, e.g. a label or a count.
    func waitUntil(_ predicate: NSPredicate,
                   on object: Any,
                   _ message: String,
                   timeout: TimeInterval = defaultTimeout,
                   file: StaticString = #filePath,
                   line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
            XCTFail("\(message) (waited \(Int(timeout))s)", file: file, line: line)
        }
    }

    /// The one element of `query` that is on screen, for identifiers a view
    /// further down the navigation stack also uses.
    func hittable(_ query: XCUIElementQuery,
                  _ message: String,
                  file: StaticString = #filePath,
                  line: UInt = #line) -> XCUIElement {
        let onScreen = query.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(onScreen.count, 1, message, file: file, line: line)
        return onScreen.first ?? query.firstMatch
    }

    // MARK: - Navigation

    func openTab(_ label: String) {
        let tab = app.tabBars.buttons[label]
        waitFor(tab, "the \(label) tab is not on screen")
        tab.tap()
    }
}

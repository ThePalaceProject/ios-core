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

    // No async setUp or tearDown override. With one, and continueAfterFailure
    // off, XCTest cannot stop the test at a failed assertion: it logs an
    // assertion failure and exits the test runner, so a failed wait restarts
    // the runner instead of failing just that test. The main-actor cleanup is
    // a teardown block that launch(scenario:resetState:) registers.
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private var cleanupRegistered = false

    private func registerCleanup() {
        guard !cleanupRegistered else { return }
        cleanupRegistered = true
        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            if let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0, let app {
                attach(app: app, named: "Failure in step: \(currentStep)")
            }
            app?.terminate()
            app = nil
        }
    }

    // MARK: - Launch

    /// Launches the app with `scenario` active. `resetState` wipes defaults,
    /// app files and the keychain first; a relaunch passes `false` to keep them.
    /// `arguments` are appended to the launch arguments, e.g. a defaults override.
    func launch(scenario: String, resetState: Bool, arguments: [String] = []) {
        guard let fixtures = Self.fixturesDirectory else {
            XCTFail("the test bundle has no Fixtures folder")
            return
        }
        Self.warmUpOnce(fixtures: fixtures)
        let app = XCUIApplication()
        app.launchEnvironment["PALACE_MOCK_BACKEND_SCENARIO"] = scenario
        app.launchEnvironment["PALACE_MOCK_BACKEND_FIXTURES"] = fixtures
        app.launchEnvironment["PALACE_MOCK_BACKEND_RESET"] = resetState ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        self.app = app
        registerCleanup()
    }

    private static var didWarmUp = false

    /// Launches the app once per test run, before the first journey, and walks
    /// it to the Libraries list. The first launch on a freshly booted CI
    /// simulator is much slower than later ones: about 60 s before the
    /// automation session starts, then about 40 s with a busy main thread while
    /// the registry swaps in. A journey that pays that cost fails its 30 s waits.
    /// Nothing here asserts; a slow or failed warm-up leaves the journey's own
    /// waits to report the problem.
    private static func warmUpOnce(fixtures: String) {
        guard !didWarmUp else { return }
        didWarmUp = true
        let warmUpTimeout: TimeInterval = 180
        let app = XCUIApplication()
        app.launchEnvironment["PALACE_MOCK_BACKEND_SCENARIO"] = FixtureLibrary.scenario
        app.launchEnvironment["PALACE_MOCK_BACKEND_FIXTURES"] = fixtures
        app.launchEnvironment["PALACE_MOCK_BACKEND_RESET"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settingsTab = app.tabBars.buttons[AccessibilityID.TabBar.settingsTab]
        if settingsTab.waitForExistence(timeout: warmUpTimeout), settingsTab.isHittable {
            settingsTab.tap()
            let libraries = app.descendants(matching: .any)[AccessibilityID.Settings.manageLibrariesButton]
            if libraries.waitForExistence(timeout: warmUpTimeout), libraries.isHittable {
                libraries.tap()
                _ = app.descendants(matching: .any)
                    .matching(identifier: "\(AccessibilityID.Libraries.row).\(FixtureLibrary.libraryID)")
                    .firstMatch
                    .waitForExistence(timeout: warmUpTimeout)
            }
        }
        app.terminate()
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
    /// further down the navigation stack also uses. Waits for it, because a
    /// pushed view or a covering system sheet can hold it off screen for a while.
    func hittable(_ query: XCUIElementQuery,
                  _ message: String,
                  timeout: TimeInterval = defaultTimeout,
                  file: StaticString = #filePath,
                  line: UInt = #line) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var onScreen = query.allElementsBoundByIndex.filter(\.isHittable)
        while onScreen.count != 1, Date() < deadline {
            dismissSavePasswordSheetIfPresent()
            pause()
            onScreen = query.allElementsBoundByIndex.filter(\.isHittable)
        }
        XCTAssertEqual(onScreen.count, 1, message, file: file, line: line)
        return onScreen.first ?? query.firstMatch
    }

    /// Taps `element` once it exists and takes taps, failing with `message`
    /// after `timeout`. A tap on an element that is still animating in, or
    /// that a system sheet covers, is dropped or fails as "not hittable".
    func tapWhenHittable(_ element: XCUIElement,
                         _ message: String,
                         timeout: TimeInterval = defaultTimeout,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable) {
            guard Date() < deadline else {
                XCTFail("\(message) (not hittable after \(Int(timeout))s)", file: file, line: line)
                return
            }
            dismissSavePasswordSheetIfPresent()
            pause()
        }
        element.tap()
    }

    /// Waits up to `timeout` for `predicate` on `object` without failing, for
    /// a value the app has set but accessibility reports a moment later. The
    /// caller asserts the exact value afterwards.
    func settle(_ object: Any, until predicate: NSPredicate, timeout: TimeInterval = 5) {
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: object)], timeout: timeout)
    }

    private func pause() {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "poll")], timeout: 0.5)
    }

    /// On a simulator that has never answered it, iOS 26 offers to save the
    /// password once the sign-in form goes away, in a sheet that covers the
    /// middle of the screen. Call it right after leaving the form. Earlier iOS
    /// versions do not show the sheet, so they skip the wait. On a loaded
    /// machine the sheet can arrive after this wait, so `tapWhenHittable` and
    /// `hittable` also dismiss it whenever it covers their element.
    func dismissSavePasswordPromptIfShown(timeout: TimeInterval = 5) {
        guard #available(iOS 26, *) else { return }
        guard savePasswordSheet.waitForExistence(timeout: timeout) else { return }
        dismissSavePasswordSheetIfPresent()
    }

    private var savePasswordSheet: XCUIElement { app.sheets["Save Password?"] }

    private func dismissSavePasswordSheetIfPresent() {
        guard #available(iOS 26, *) else { return }
        let sheet = savePasswordSheet
        guard sheet.exists else { return }
        let notNow = sheet.buttons["Not Now"]
        // A tap during the sheet's presentation animation is dropped, so wait
        // for the button to take taps and try again while the sheet stays.
        for _ in 0..<3 where sheet.exists {
            waitUntil(NSPredicate(format: "hittable == true"), on: notNow, "the Save Password sheet has no Not Now button")
            notNow.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                                 object: sheet)], timeout: 3)
        }
        XCTAssertFalse(sheet.exists, "the Save Password sheet did not close")
    }

    // MARK: - Navigation

    func openTab(_ label: String) {
        tapWhenHittable(app.tabBars.buttons[label], "the \(label) tab is not on screen")
    }
}

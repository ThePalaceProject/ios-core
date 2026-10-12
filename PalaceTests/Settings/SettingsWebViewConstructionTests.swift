import SwiftUI
import XCTest
import PalacePreferences
import PalaceUtilities
@testable import Palace

/// Settings must not build a web page controller until a patron opens a row:
/// each `RemoteHTMLViewController` owns a `WKWebView`, and each `WKWebView`
/// starts a WebContent process.
@MainActor
final class SettingsWebViewConstructionTests: XCTestCase {
    private var host: AccessibilityAuditHost?
    private var suiteName: String?

    override func tearDown() {
        host?.tearDown()
        host = nil
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    func testSettingsBody_WhenReRenderedTenTimes_BuildsNoWebPage() throws {
        let spy = WebPageFactorySpy()
        let (host, defaults) = try mountSettings(spy: spy)

        var observedToggleValues: [String?] = []
        for index in 0..<10 {
            defaults.set(index % 2 == 0, forKey: TPPSettings.downloadOnlyOnWiFiKey)
            host.settle(0.15)
            observedToggleValues.append(element(labeled: Strings.Settings.downloadOnlyOnWiFi, in: host)?
                .object.accessibilityValue)
        }

        // The toggle following each write proves every write re-ran `body`.
        XCTAssertEqual(observedToggleValues, (0..<10).map { $0 % 2 == 0 ? "1" : "0" })
        XCTAssertEqual(spy.calls, [], "rendering Settings must not build any web page")
    }

    func testAboutRow_WhenTapped_BuildsOnePageForTheAboutURL() throws {
        try assertTappingRow(
            title: Strings.Settings.aboutApp,
            identifier: AccessibilityID.Settings.aboutPalaceButton,
            opens: TPPSettings.TPPAboutPalaceURLString
        )
    }

    func testPrivacyRow_WhenTapped_BuildsOnePageForThePrivacyURL() throws {
        try assertTappingRow(
            title: Strings.Settings.privacyPolicy,
            identifier: AccessibilityID.Settings.privacyPolicyButton,
            opens: TPPSettings.TPPPrivacyPolicyURLString
        )
    }

    func testUserAgreementRow_WhenTapped_BuildsOnePageForTheAgreementURL() throws {
        try assertTappingRow(
            title: Strings.Settings.eula,
            identifier: AccessibilityID.Settings.userAgreementButton,
            opens: TPPSettings.TPPUserAgreementURLString
        )
    }

    func testSoftwareLicenseRow_WhenTapped_BuildsOnePageForTheLicensesURL() throws {
        try assertTappingRow(
            title: Strings.Settings.softwareLicenses,
            identifier: AccessibilityID.Settings.softwareLicensesButton,
            opens: TPPSettings.TPPSoftwareLicensesURLString
        )
    }

    /// Production never sets the factory, so the default is what patrons get.
    func testDefaultFactory_BuildsRemotePageWithTheGivenArguments() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/licenses"))

        let made = EnvironmentValues().remoteHTMLControllerFactory(url, "Licenses", "Could not load")

        let page = try XCTUnwrap(made as? RemoteHTMLViewController)
        XCTAssertEqual(page.fileURL, url)
        XCTAssertEqual(page.title, "Licenses")
        XCTAssertEqual(page.failureMessage, "Could not load")
    }

    // MARK: - Helpers

    private func assertTappingRow(
        title: String,
        identifier: String,
        opens urlString: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let spy = WebPageFactorySpy()
        let (host, _) = try mountSettings(spy: spy)
        let row = try XCTUnwrap(element(labeled: title, in: host), "\(title) row is not reachable", file: file, line: line)
        XCTAssertEqual(accessibilityIdentifier(of: row), identifier, file: file, line: line)

        let activation = AccessibilityTraversalAudit.activate(row, in: host.window)
        host.settle(0.8)

        XCTAssertTrue(activation.succeeded, "\(activation)", file: file, line: line)
        XCTAssertEqual(spy.calls, [WebPageFactorySpy.Call(
            url: try XCTUnwrap(URL(string: urlString)),
            title: title,
            failureMessage: Strings.Error.loadFailedError
        )], file: file, line: line)
        let pushed = try XCTUnwrap(spy.made.last, file: file, line: line)
        XCTAssertNotNil(pushed.viewIfLoaded?.window, "the built page must be on screen", file: file, line: line)
        XCTAssertEqual(topNavigationTitle(in: host), title, file: file, line: line)
    }

    /// Mounts Settings tall enough that every row is realised, with
    /// `@AppStorage` reading an isolated suite.
    private func mountSettings(spy: WebPageFactorySpy) throws -> (AccessibilityAuditHost, UserDefaults) {
        let suite = "settings-webview.\(UUID().uuidString)"
        suiteName = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = NavigationStack { TPPSettingsView() }
            .environment(\.appContainer, makeTestAppContainer())
            .environment(\.remoteHTMLControllerFactory, spy.factory)
            .defaultAppStorage(defaults)
        let host = AccessibilityAuditHost(UIHostingController(rootView: root), size: CGSize(width: 402, height: 2600))
        self.host = host
        host.settle(0.5)
        return (host, defaults)
    }

    private func element(labeled label: String, in host: AccessibilityAuditHost) -> AXAuditElement? {
        AccessibilityTraversalAudit.traverse(host.window).first { $0.label == label }
    }

    /// SwiftUI's accessibility nodes answer `accessibilityIdentifier` without
    /// conforming to `UIAccessibilityIdentification`, so ask by selector.
    private func accessibilityIdentifier(of element: AXAuditElement) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.object.responds(to: selector) else { return nil }
        return element.object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func topNavigationTitle(in host: AccessibilityAuditHost) -> String? {
        var pending: [UIViewController] = host.window.rootViewController.map { [$0] } ?? []
        while let controller = pending.popLast() {
            if let navigation = controller as? UINavigationController {
                return navigation.topViewController?.navigationItem.title
            }
            pending.append(contentsOf: controller.children)
        }
        return nil
    }
}

/// Records every page the view asks for and hands back a plain controller,
/// so no `WKWebView` is created during the test.
@MainActor
private final class WebPageFactorySpy {
    struct Call: Equatable {
        let url: URL
        let title: String
        let failureMessage: String
    }

    private(set) var calls: [Call] = []
    private(set) var made: [UIViewController] = []

    var factory: RemoteHTMLControllerFactory {
        { [self] url, title, failureMessage in
            calls.append(Call(url: url, title: title, failureMessage: failureMessage))
            let controller = UIViewController()
            controller.title = title
            made.append(controller)
            return controller
        }
    }
}

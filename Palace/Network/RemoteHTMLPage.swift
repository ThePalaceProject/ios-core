import SwiftUI
import UIKit

/// Builds the controller that shows a remote HTML page.
typealias RemoteHTMLControllerFactory = @MainActor @Sendable (
    _ url: URL, _ title: String, _ failureMessage: String
) -> UIViewController

private struct RemoteHTMLControllerFactoryKey: EnvironmentKey {
    static let defaultValue: RemoteHTMLControllerFactory = { url, title, failureMessage in
        RemoteHTMLViewController(URL: url, title: title, failureMessage: failureMessage)
    }
}

extension EnvironmentValues {
    /// Tests replace this to count or stub page controllers.
    var remoteHTMLControllerFactory: RemoteHTMLControllerFactory {
        get { self[RemoteHTMLControllerFactoryKey.self] }
        set { self[RemoteHTMLControllerFactoryKey.self] = newValue }
    }
}

/// A remote HTML page for use as a `NavigationLink` destination.
///
/// The controller is built in `makeUIViewController`, when the page is pushed,
/// not when the destination value is created. Every `RemoteHTMLViewController`
/// owns a `WKWebView`, and every `WKWebView` starts a WebContent process, so
/// building it while a list's `body` runs would start a process per row on
/// every re-render.
struct RemoteHTMLPage: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let failureMessage: String

    func makeUIViewController(context: Context) -> UIViewController {
        context.environment.remoteHTMLControllerFactory(url, title, failureMessage)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

import SwiftUI
import UIKit

/// A view that renders HTML content as styled text.
/// NSAttributedString HTML parsing uses WebKit internally and MUST run on the main thread
/// and only when the app is active — calling it from the background causes
/// NSInternalInconsistencyException "unexpected start state" crashes.
struct HTMLTextView: View {
    let htmlContent: String

    @State private var attributedString: AttributedString? = nil

    var body: some View {
        Group {
            if let attributedString {
                Text(attributedString)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(htmlContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { parseHTML() }
        .onChange(of: htmlContent) { _ in parseHTML() }
    }

    @MainActor
    private func parseHTML() {
        // Guard: WebKit's HTML parser must not be invoked while the app is
        // backgrounded. SwiftUI can trigger onAppear/onChange during state
        // restoration in the background, which causes the WebKit state machine
        // to crash with NSInternalInconsistencyException "unexpected start state".
        guard UIApplication.shared.applicationState != .background else { return }
        attributedString = Self.htmlToAttributedString(htmlContent)
    }

    @MainActor
    private static func htmlToAttributedString(_ html: String) -> AttributedString? {
        guard !html.isEmpty, html.contains("<") else { return nil }
        guard let data = html.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        // NSAttributedString HTML parsing uses WebKit internally and can throw
        // ObjC NSExceptions that Swift's try? cannot catch.
        var nsAttributedString: NSAttributedString?
        let exception = TPPObjCExceptionCatcher.catchException {
            nsAttributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        }

        if exception != nil { return nil }

        guard let nsAttributedString else { return nil }

        let mutableAttributedString = NSMutableAttributedString(attributedString: nsAttributedString)
        let fullRange = NSRange(location: 0, length: mutableAttributedString.length)
        mutableAttributedString.addAttribute(.font, value: UIFont.palaceFont(ofSize: 15), range: fullRange)
        return AttributedString(mutableAttributedString)
    }
}

import SwiftUI
import UIKit

struct HTMLTextView: View {
    let htmlContent: String

    var body: some View {
        if let attributedString = htmlToAttributedString(htmlContent) {
            Text(attributedString)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(htmlContent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func htmlToAttributedString(_ html: String) -> AttributedString? {
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

        if let nsAttributedString = nsAttributedString {
            let mutableAttributedString = NSMutableAttributedString(attributedString: nsAttributedString)
            mutableAttributedString.addAttribute(.font, value: UIFont.palaceFont(ofSize: 15), range: NSRange(location: 0, length: mutableAttributedString.length))
            return AttributedString(mutableAttributedString)
        }

        return nil
    }
}
